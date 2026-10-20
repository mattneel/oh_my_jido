defmodule OhMyJido.NativeStopOriginTest do
  use Jido.AI.TestCase, async: false

  @moduletag timeout: 60_000

  alias OhMyJido.{Runtime, Session, Tool}

  defmodule OriginHost do
    @behaviour OhMyJido.Host

    @impl true
    def authorize(context, :edit, %{operation: :write, path: path}, opts)
        when path in ["native-owned.txt", "direct-host.txt"] do
      observer = opts[:observer]
      monitor = Process.monitor(observer)
      gate = make_ref()
      send(observer, {:write_paused, path, self(), gate, context.run_id})

      try do
        receive do
          {:approve_write, ^gate} -> :ok
          {:abort_write, ^gate} -> {:error, :test_cleanup}
          {:DOWN, ^monitor, :process, ^observer, _reason} -> {:error, :test_cleanup}
        after
          20_000 -> {:error, :approval_timeout}
        end
      after
        Process.demonitor(monitor, [:flush])
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
    root = Path.join(System.tmp_dir!(), "omj-stop-origin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "native teardown cannot settle a direct host Write borrowing the active run ID", %{
    root: root
  } do
    session = session(root)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)
    native_id = "native-owned-write"
    host_id = "direct-host-write"
    native_path = Path.join(root, "native-owned.txt")
    host_path = Path.join(root, "direct-host.txt")
    host_content = "the direct host write completed exactly once\n"
    host_bytes = byte_size(host_content)
    host_snapshot = OhMyJido.Files.snapshot(host_content)

    script =
      expect_react do
        user("Keep the native write paused while its host also writes")

        call(
          "write",
          %{path: "native-owned.txt", content: "must never be published", snapshot: "missing"},
          id: "native-owned-write"
        )

        answer("The native write must not finish after stop.")
      end

    assert {:ok, run} =
             OhMyJido.prompt(
               session,
               "Keep the native write paused while its host also writes",
               react_opts(script)
             )

    assert_receive {:write_paused, "native-owned.txt", native_action, native_gate, ^run}, 5_000
    native_monitor = watch_gate(native_action, native_gate)

    assert {:ok, %{run_id: ^run} = context} = Session.call(session, :context)
    assert {:ok, %{active_run: ^run}} = OhMyJido.inspect_session(session)

    {host_caller, host_caller_monitor} =
      host_writer(
        context,
        %{path: "direct-host.txt", content: host_content, snapshot: "missing"},
        host_id
      )

    assert_receive {:write_paused, "direct-host.txt", host_action, host_gate, ^run}, 5_000
    host_monitor = watch_gate(host_action, host_gate)
    refute host_action == host_caller
    refute host_action == native_action

    assert {:ok, %{id: ^native_id, name: "write", run: ^run, status: :running}} =
             Session.effect_receipt(session, native_id)

    assert {:ok, %{id: ^host_id, name: "write", run: ^run, status: :running}} =
             Session.effect_receipt(session, host_id)

    refute File.exists?(native_path)
    refute File.exists?(host_path)
    stop = Task.async(fn -> OhMyJido.stop_session(session) end)

    assert {:error,
            %{
              reason: :cleanup_uncertain,
              cleanup: :uncertain,
              pending_effects: [^host_id],
              pending_resources: [],
              native: :confirmed
            }} = Task.await(stop, 8_000)

    assert_receive {:DOWN, ^native_monitor, :process, ^native_action, _reason}, 5_000
    refute Process.alive?(native_action)
    assert Process.alive?(host_action)
    assert Process.alive?(host_caller)
    refute_receive {:DOWN, ^host_monitor, :process, ^host_action, _reason}, 0
    refute_receive {:DOWN, ^host_caller_monitor, :process, ^host_caller, _reason}, 0
    refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
    assert GenServer.whereis(Runtime.via(session)) == coordinator
    assert session in OhMyJido.list_sessions(session.runtime)
    assert {:ok, %{status: :cleanup_uncertain}} = OhMyJido.inspect_session(session)
    assert {:error, :session_stopped} = Session.call(session, :context)

    assert {:ok, %{status: :uncertain, completed_at: _completed_at} = native_receipt} =
             Session.effect_receipt(session, native_id)

    assert {:ok, pending_host_receipt} = Session.effect_receipt(session, host_id)
    assert pending_host_receipt.status in [:running, :uncertain]
    refute Map.has_key?(pending_host_receipt, :completed_at)
    refute_receive {:host_write_returned, ^host_caller, _result}, 0
    refute File.exists?(native_path)
    refute File.exists?(host_path)

    # A late approval cannot revive the native Action after correlated teardown.
    send(native_action, {:approve_write, native_gate})
    send(host_action, {:approve_write, host_gate})

    assert_receive {:host_write_returned, ^host_caller,
                    {:ok,
                     %{
                       path: "direct-host.txt",
                       snapshot: ^host_snapshot,
                       previous_snapshot: "missing",
                       bytes_written: ^host_bytes,
                       created: true,
                       changed: true
                     }}},
                   5_000

    assert_receive {:DOWN, ^host_monitor, :process, ^host_action, :normal}, 5_000
    assert File.read!(host_path) == host_content
    refute File.exists?(native_path)

    assert {:ok, %{id: ^host_id, run: ^run, status: :completed, completed_at: _completed_at}} =
             Session.effect_receipt(session, host_id)

    assert {:ok, ^native_receipt} = Session.effect_receipt(session, native_id)

    wait_until(fn ->
      match?({:ok, %{status: :stopped}}, OhMyJido.inspect_session(session))
    end)

    assert {:ok, snapshot} = OhMyJido.inspect_session(session)
    assert snapshot.effects |> Map.keys() |> Enum.sort() == Enum.sort([native_id, host_id])
    assert_host_caller_alive(host_caller, host_caller_monitor)
    assert :ok = OhMyJido.stop_session(session)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
    assert_host_caller_alive(host_caller, host_caller_monitor)
    refute_receive {:host_write_returned, ^host_caller, _result}, 0
    refute_receive {:write_paused, "direct-host.txt", _action, _gate, _run}, 0
    refute_receive {:write_paused, "native-owned.txt", _action, _gate, _run}, 0
    assert File.read!(host_path) == host_content
    refute File.exists?(native_path)
  end

  defp session(root) do
    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         name: __MODULE__.Host,
         allow_test_scripts: true,
         tools: [OhMyJido.Tools.Write],
         tool_timeout_ms: 30_000,
         run_timeout_ms: 30_000},
        shutdown: 10_000
      )
    )

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: root,
               permissions: [:edit],
               host: {OriginHost, observer: self()}
             )

    session
  end

  defp watch_gate(action, gate) do
    on_exit(fn -> send(action, {:abort_write, gate}) end)
    Process.monitor(action)
  end

  defp host_writer(context, params, effect_id) do
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        observer_monitor = Process.monitor(observer)
        result = Tool.execute(context, "write", params, effect_id: effect_id)
        send(observer, {:host_write_returned, self(), result})
        host_caller_loop(observer, observer_monitor)
      end)

    on_exit(fn -> send(caller, :finish) end)
    {caller, monitor}
  end

  defp host_caller_loop(observer, monitor) do
    receive do
      {:ping, ^observer} ->
        send(observer, {:host_caller_alive, self()})
        host_caller_loop(observer, monitor)

      :finish ->
        :ok

      {:DOWN, ^monitor, :process, ^observer, _reason} ->
        :ok
    after
      30_000 -> :ok
    end
  end

  defp assert_host_caller_alive(caller, monitor) do
    refute_receive {:DOWN, ^monitor, :process, ^caller, _reason}, 0
    send(caller, {:ping, self()})
    assert_receive {:host_caller_alive, ^caller}, 1_000
  end

  defp wait_until(predicate, attempts \\ 500)

  defp wait_until(_predicate, 0),
    do: flunk("the native stop did not settle after the real host write receipt")

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
