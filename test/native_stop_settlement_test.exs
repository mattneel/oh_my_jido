defmodule OhMyJido.NativeStopSettlementTest do
  use Jido.AI.TestCase, async: false

  @moduletag timeout: 60_000

  alias OhMyJido.{Event, Runtime, Session, Tool}
  alias OhMyJido.Process, as: Runner

  defmodule SettlementHost do
    @behaviour OhMyJido.Host

    @impl true
    def authorize(_context, :edit, %{operation: :write, path: "paused.txt"}, opts) do
      gate = make_ref()
      send(opts[:observer], {:file_action_paused, self(), gate})

      receive do
        {:approve_file, ^gate} -> :ok
      after
        20_000 -> {:error, :approval_timeout}
      end
    end

    def authorize(_context, :exec, effect, opts) do
      send(opts[:observer], {:process_authorized, self(), effect})

      cond do
        opts[:pause_process] ->
          gate = make_ref()
          send(opts[:observer], {:process_authorization_paused, self(), gate})

          receive do
            {:approve_process, ^gate} -> :ok
          after
            20_000 -> {:error, :approval_timeout}
          end

        opts[:operator_approval] ->
          {:approval, %{kind: :effect, effect: effect}}

        true ->
          :ok
      end
    end

    def authorize(context, capability, effect, opts),
      do: OhMyJido.Host.Local.authorize(context, capability, effect, opts)

    @impl true
    defdelegate credentials(context, account, opts), to: OhMyJido.Host.Local

    @impl true
    defdelegate invoke(context, capability, request, opts), to: OhMyJido.Host.Local

    @impl true
    def question(_context, _question, _opts), do: :pending
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "omj-stop-settlement-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "stop waits for a real paused file Action without killing its host caller", %{root: root} do
    session = session(root)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)

    {owner, owner_monitor} =
      effect_owner(
        session,
        "write",
        %{path: "paused.txt", content: "written once", snapshot: "missing"},
        effect_id: "paused-file"
      )

    assert_receive {:file_action_paused, action, gate}, 5_000
    action_monitor = Process.monitor(action)
    refute action == owner

    try do
      assert {:ok, %{name: "write", status: :running}} =
               Session.effect_receipt(session, "paused-file")

      refute File.exists?(Path.join(root, "paused.txt"))
      stop = Task.async(fn -> OhMyJido.stop_session(session) end)
      stop_ref = stop.ref
      wait_until(fn -> Session.call(session, :context) == {:error, :session_stopped} end)

      refute_receive {^stop_ref, _result}, 100
      refute_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 0
      refute_receive {:DOWN, ^action_monitor, :process, ^action, _reason}, 0
      refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
      assert Process.alive?(owner)
      assert Process.alive?(action)
      refute File.exists?(Path.join(root, "paused.txt"))

      send(action, {:approve_file, gate})
      assert_receive {:effect_returned, ^owner, {:ok, _written}}, 5_000
      assert_receive {:DOWN, ^action_monitor, :process, ^action, :normal}, 5_000
      assert :ok = Task.await(stop, 8_000)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
      assert File.read!(Path.join(root, "paused.txt")) == "written once"
      assert_owner_alive(owner, owner_monitor)
    after
      send(action, {:approve_file, gate})
      send(owner, :finish)
    end
  end

  test "native file cancellation records stopped execution uncertainty without a post-stop write",
       %{
         root: root
       } do
    session = session(root)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)

    script =
      expect_react do
        user("Pause a native file write before stopping")

        call(
          "write",
          %{path: "paused.txt", content: "native write completed once", snapshot: "missing"},
          id: "native-paused-file"
        )

        answer("The native write finished.")
      end

    assert {:ok, run} =
             OhMyJido.prompt(
               session,
               "Pause a native file write before stopping",
               react_opts(script)
             )

    assert_receive {:file_action_paused, action, gate}, 5_000
    action_monitor = Process.monitor(action)

    assert {:ok, %{status: :running}} = Session.effect_receipt(session, "native-paused-file")
    stop = Task.async(fn -> OhMyJido.stop_session(session) end)
    assert :ok = Task.await(stop, 8_000)
    assert_receive {:DOWN, ^action_monitor, :process, ^action, _reason}, 5_000
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
    refute Process.alive?(action)
    refute File.exists?(Path.join(root, "paused.txt"))

    send(action, {:approve_file, gate})
    refute File.exists?(Path.join(root, "paused.txt"))
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)

    assert {:ok,
            %{
              id: "native-paused-file",
              name: "write",
              run: ^run,
              status: :uncertain,
              completed_at: _completed_at
            } = receipt} = Session.effect_receipt(session, "native-paused-file")

    refute Map.has_key?(receipt, :result)

    assert {:error, :effect_already_recorded} =
             OhMyJido.execute_tool(
               session,
               "write",
               %{path: "paused.txt", content: "must not replay", snapshot: "missing"},
               effect_id: "native-paused-file"
             )

    refute_receive {:file_action_paused, _action, _gate}, 0
    refute File.exists?(Path.join(root, "paused.txt"))
    assert {:ok, ^receipt} = Session.effect_receipt(session, "native-paused-file")
    assert :ok = OhMyJido.stop_session(session)
  end

  test "an approved native Shell is fully settled before stop returns and its actor goes DOWN", %{
    root: root
  } do
    session = session(root, operator_approval: true)
    assert :ok = OhMyJido.subscribe(session, self())
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)

    script =
      expect_react do
        user("Stop this approved native shell")
        call("shell", shell_params(), id: "native-stop-shell")
        answer("The approved shell exited.")
      end

    assert {:ok, run} =
             OhMyJido.prompt(session, "Stop this approved native shell", react_opts(script))

    assert_receive {:process_authorized, action, %{executable: _executable}}, 5_000
    action_monitor = Process.monitor(action)

    assert_receive {:oh_my_jido,
                    %Event{
                      kind: :approval_requested,
                      run_id: ^run,
                      payload: %{id: question_id}
                    }},
                   5_000

    refute File.exists?(Path.join(root, "effect"))
    assert :ok = OhMyJido.answer(session, question_id, :approve)
    pids = ready_group(root)
    assert Enum.all?(pids, &alive?/1)

    stop = Task.async(fn -> OhMyJido.stop_session(session) end)

    assert_receive {:oh_my_jido,
                    %Event{
                      kind: :resource_cleanup,
                      run_id: ^run,
                      payload: %{
                        kind: :process,
                        confirmed: true,
                        outcome:
                          {:ok,
                           %{
                             cleanup: :confirmed,
                             cancellation: :confirmed,
                             effect: :uncertain
                           }}
                      }
                    }},
                   8_000

    assert :ok = Task.await(stop, 8_000)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
    assert_receive {:DOWN, ^action_monitor, :process, ^action, _reason}, 5_000
    assert_group_stopped(pids)
    assert File.read!(Path.join(root, "effect")) == "written-once\n"
  end

  test "a confirmed Shell cleanup cannot settle an effect whose real host caller is paused", %{
    root: root
  } do
    session = session(root)
    assert :ok = OhMyJido.subscribe(session, self())
    assert {:ok, context} = Session.call(session, :context)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)
    effect_id = "paused-shell-receipt"
    {owner, owner_monitor} = effect_owner(session, "shell", shell_params(), effect_id: effect_id)
    assert_receive {:process_authorized, action, _effect}, 5_000
    action_monitor = Process.monitor(action)
    pids = ready_group(root)
    assert Enum.all?(pids, &alive?/1)
    assert true = :erlang.suspend_process(owner)

    try do
      stop = Task.async(fn -> OhMyJido.stop_session(session) end)

      assert_receive {:oh_my_jido,
                      %Event{
                        kind: :resource_cleanup,
                        payload: %{
                          kind: :process,
                          confirmed: true,
                          outcome: {:ok, %{cleanup: :confirmed, cancellation: :confirmed}}
                        }
                      }},
                     5_000

      assert_receive {:DOWN, ^action_monitor, :process, ^action, :normal}, 5_000
      assert_group_stopped(pids)

      assert {:error,
              %{
                reason: :cleanup_uncertain,
                cleanup: :uncertain,
                pending_effects: [^effect_id],
                pending_resources: [],
                native: :confirmed
              }} = Task.await(stop, 8_000)

      assert Process.alive?(owner)
      refute_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 0
      refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
      assert {:ok, %{status: :cleanup_uncertain}} = OhMyJido.inspect_session(session)
      assert_sealed(session, context, root)
      assert File.read!(Path.join(root, "effect")) == "written-once\n"

      resume_process(owner)

      assert_receive {:effect_returned, ^owner,
                      {:ok, %{cleanup: :confirmed, cancellation: :confirmed, effect: :uncertain}}},
                     5_000

      wait_until(fn ->
        match?({:ok, %{status: :stopped}}, OhMyJido.inspect_session(session))
      end)

      assert :ok = OhMyJido.stop_session(session)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
      assert_owner_alive(owner, owner_monitor)
      assert_group_stopped(pids)
    after
      resume_process(owner)
      send(owner, :finish)
    end
  end

  test "unconfirmed real process cleanup returns a bounded error and keeps all admission sealed",
       %{
         root: root
       } do
    session = session(root)
    assert :ok = OhMyJido.subscribe(session, self())
    assert {:ok, context} = Session.call(session, :context)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)

    assert {:ok, handle} =
             Runner.start(context, "sh", shell_params().args, timeout: 20_000)

    assert_receive {:process_authorized, caller, _effect}, 5_000
    assert caller == self()
    pids = ready_group(root)
    assert Enum.all?(pids, &alive?/1)
    assert true = :erlang.suspend_process(handle.pid)

    try do
      stop = Task.async(fn -> OhMyJido.stop_session(session) end)

      assert {:error,
              %{
                reason: :cleanup_uncertain,
                cleanup: :uncertain,
                pending_effects: [],
                pending_resources: [:process],
                native: :confirmed
              }} = Task.await(stop, 8_000)

      assert Process.alive?(handle.pid)
      assert Enum.all?(pids, &alive?/1)
      refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
      assert GenServer.whereis(Runtime.via(session)) == coordinator
      assert {:ok, %{status: :cleanup_uncertain}} = OhMyJido.inspect_session(session)
      assert_sealed(session, context, root)

      resume_process(handle.pid)

      assert {:ok, %{cleanup: :confirmed, cancellation: :confirmed, effect: :uncertain}} =
               Runner.await(handle, 5_000)

      assert_receive {:oh_my_jido,
                      %Event{
                        kind: :resource_cleanup,
                        payload: %{
                          kind: :process,
                          confirmed: true,
                          outcome: {:ok, %{cleanup: :confirmed}}
                        }
                      }},
                     5_000

      assert_group_stopped(pids)

      wait_until(fn ->
        match?({:ok, %{status: :stopped}}, OhMyJido.inspect_session(session))
      end)

      assert :ok = OhMyJido.stop_session(session)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
      assert File.read!(Path.join(root, "effect")) == "written-once\n"
    after
      resume_process(handle.pid)
      if Process.alive?(handle.pid), do: Runner.cancel(handle)
    end
  end

  test "a pre-seal Shell effect cannot register or launch a process after stop seals admission",
       %{
         root: root
       } do
    session = session(root, pause_process: true)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)
    params = %{executable: "sh", args: ["-c", "printf forbidden > late-process.txt"]}

    {owner, owner_monitor} =
      effect_owner(session, "shell", params, effect_id: "late-process-registration")

    assert_receive {:process_authorization_paused, action, gate}, 5_000
    action_monitor = Process.monitor(action)

    try do
      assert {:ok, %{name: "shell", status: :running}} =
               Session.effect_receipt(session, "late-process-registration")

      stop = Task.async(fn -> OhMyJido.stop_session(session) end)
      stop_ref = stop.ref
      wait_until(fn -> Session.call(session, :context) == {:error, :session_stopped} end)
      refute_receive {^stop_ref, _result}, 100
      refute_receive {:DOWN, ^action_monitor, :process, ^action, _reason}, 0
      refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
      refute File.exists?(Path.join(root, "late-process.txt"))

      send(action, {:approve_process, gate})

      assert_receive {:effect_returned, ^owner,
                      {:error, %{details: %{reason: :session_stopped}}}},
                     5_000

      assert_receive {:DOWN, ^action_monitor, :process, ^action, :normal}, 5_000
      assert :ok = Task.await(stop, 8_000)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
      refute File.exists?(Path.join(root, "late-process.txt"))
      assert_owner_alive(owner, owner_monitor)
    after
      send(action, {:approve_process, gate})
      send(owner, :finish)
    end
  end

  test "a real failed Process precondition unregister is not cleanup proof after its owner exits",
       %{
         root: root
       } do
    session = session(root)
    assert :ok = OhMyJido.subscribe(session, self())
    assert {:ok, context} = Session.call(session, :context)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)
    approval = Path.join(root, "process-approval")
    File.write!(approval, "approved")
    observer = self()
    gate = make_ref()

    starter =
      Task.async(fn ->
        Runner.start(context, "sh", ["-c", "printf forbidden > revoked-process.txt"],
          timeout: 20_000,
          before_effect: fn ->
            send(observer, {:process_precondition, self()})

            receive do
              {:recheck_approval, ^gate} ->
                if File.regular?(approval), do: :ok, else: {:error, :approval_revoked}
            after
              10_000 -> {:error, :approval_timeout}
            end
          end
        )
      end)

    assert_receive {:process_precondition, resource_owner}, 5_000
    resource_monitor = Process.monitor(resource_owner)

    try do
      File.rm!(approval)
      send(resource_owner, {:recheck_approval, gate})
      assert {:error, :approval_revoked} = Task.await(starter, 5_000)
      assert_receive {:DOWN, ^resource_monitor, :process, ^resource_owner, :normal}, 5_000

      assert_receive {:oh_my_jido,
                      %Event{
                        kind: :resource_cleanup,
                        payload: %{
                          kind: :process,
                          confirmed: false,
                          outcome: {:error, :approval_revoked}
                        }
                      }},
                     5_000

      refute File.exists?(Path.join(root, "revoked-process.txt"))

      stop = Task.async(fn -> OhMyJido.stop_session(session) end)

      assert {:error,
              %{
                reason: :cleanup_uncertain,
                cleanup: :uncertain,
                pending_effects: [],
                pending_resources: [:process],
                native: :confirmed
              }} = Task.await(stop, 8_000)

      refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
      assert GenServer.whereis(Runtime.via(session)) == coordinator
      assert {:ok, %{status: :cleanup_uncertain}} = OhMyJido.inspect_session(session)
      assert_sealed(session, context, root)
      refute File.exists?(Path.join(root, "revoked-process.txt"))
    after
      send(resource_owner, {:recheck_approval, gate})
    end
  end

  defp session(root, host_opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         name: __MODULE__.Host,
         allow_test_scripts: true,
         tools: [OhMyJido.Tools.Write, OhMyJido.Tools.Shell],
         tool_timeout_ms: 30_000,
         run_timeout_ms: 30_000,
         max_processes: 2},
        shutdown: 10_000
      )
    )

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: root,
               permissions: [:edit, :exec],
               host: {SettlementHost, Keyword.put(host_opts, :observer, self())}
             )

    session
  end

  defp effect_owner(session, name, params, opts) do
    observer = self()

    spawn_monitor(fn ->
      result = OhMyJido.execute_tool(session, name, params, opts)
      send(observer, {:effect_returned, self(), result})
      owner_loop()
    end)
  end

  defp owner_loop do
    receive do
      {:ping, observer} ->
        send(observer, {:host_caller_alive, self()})
        owner_loop()

      :finish ->
        :ok
    after
      30_000 -> :ok
    end
  end

  defp assert_owner_alive(owner, monitor) do
    refute_receive {:DOWN, ^monitor, :process, ^owner, _reason}, 0
    send(owner, {:ping, self()})
    assert_receive {:host_caller_alive, ^owner}, 1_000
  end

  defp assert_sealed(session, context, root) do
    params = %{path: "forbidden-write.txt", content: "must not be written", snapshot: "missing"}

    script =
      expect_react do
        user("Attempt a new effect after uncertain stop")
        call("write", params)
        answer("A sealed session must never execute this script.")
      end

    assert {:error, :session_stopped} =
             OhMyJido.prompt(
               session,
               "Attempt a new effect after uncertain stop",
               react_opts(script)
             )

    assert {:error, :session_stopped} = OhMyJido.execute_tool(session, "write", params)
    assert {:error, :session_stopped} = Tool.execute(context, "write", params)

    assert {:error, :session_stopped} =
             Runner.start(context, "sh", ["-c", "printf forbidden > forbidden-process.txt"])

    refute File.exists?(Path.join(root, "forbidden-write.txt"))
    refute File.exists?(Path.join(root, "forbidden-process.txt"))
  end

  defp shell_params do
    %{
      executable: "sh",
      args: [
        "-c",
        "printf 'written-once\\n' >> effect; printf '%s\\n' \"$$\" > leader; sh -c 'sleep 30 & echo $! > grandchild; wait' & echo $! > child; wait"
      ],
      timeout_ms: 20_000
    }
  end

  defp ready_group(root) do
    pids = Enum.map(["leader", "child", "grandchild"], &ready_pid(Path.join(root, &1)))
    [leader | _children] = pids
    assert {:ok, identity} = Runner.capture_identity(leader)
    assert identity.group == Integer.to_string(leader)
    assert identity.session == identity.group
    pids
  end

  defp ready_pid(path) do
    wait_until(fn -> match?({:ok, content} when content != "", File.read(path)) end)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp assert_group_stopped(pids) do
    for pid <- pids do
      refute alive?(pid), "process #{pid} remained live after confirmed settlement"
    end
  end

  defp alive?(pid) do
    case Runner.capture_identity(pid) do
      {:ok, %{state: state}} -> state not in ["Z", "X"]
      {:error, reason} when reason in [:enoent, :esrch] -> false
      {:error, reason} -> flunk("cannot observe process settlement: #{inspect(reason)}")
    end
  end

  defp resume_process(pid) do
    case Process.info(pid, :status) do
      {:status, :suspended} -> :erlang.resume_process(pid)
      _status -> :ok
    end
  end

  defp wait_until(predicate, attempts \\ 500)

  defp wait_until(_predicate, 0),
    do: flunk("the real native operation did not reach its required settlement boundary")

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      receive do
      after
        10 -> wait_until(predicate, attempts - 1)
      end
    end
  end
end
