defmodule ElixosHost.HostServicesTest do
  use Jido.AI.TestCase, async: false

  alias ElixosHost.{Fixtures, SessionOwner}

  @moduletag :tmp_dir
  @runtime ElixosHost.TestCoding

  setup %{tmp_dir: root} do
    priv = Path.join(root, "priv")
    previous = Application.fetch_env(:elixos, :priv_dir)
    Application.put_env(:elixos, :priv_dir, priv)
    on_exit(fn -> Fixtures.restore_env(:priv_dir, previous) end)
    {:ok, image} = Elixos.Image.open(priv)
    Process.register(image, Elixos.Image)
    on_exit(fn -> if Process.alive?(image), do: Elixos.Image.close(image) end)

    start_supervised!(
      {ElixosHost.Supervisor,
       runtime: @runtime, storage_path: Path.join(priv, "coding"), allow_test_scripts: true}
    )

    start_supervised!(
      Supervisor.child_spec(
        {DynamicSupervisor, name: Elixos.Agents.Supervisor, strategy: :one_for_one},
        id: Elixos.Agents.Supervisor
      )
    )

    start_supervised!({Elixos.Agents, {image, :normal}})
    start_supervised!({Elixos.Ask, []})

    {:ok, []} = Elixos.Ask.subscribe()
    %{root: root, priv: priv, image: image}
  end

  test "requester group leaders retain distinct roots through real Agents and library restore",
       context do
    cwd = File.cwd!()
    env = System.get_env()

    opened =
      Enum.map([{"first", "first repository"}, {"second", "second repository"}], fn {id, text} ->
        root = Path.join(context.root, id)
        File.mkdir_p!(root)
        File.write!(Path.join(root, "facts.txt"), text)
        {:ok, io} = StringIO.open("")

        task =
          Task.async(fn ->
            Process.group_leader(self(), io)
            {:ok, ^root} = Elixos.Session.cd(root)
            ElixosHost.open(runtime: @runtime, id: id, permissions: [:read])
          end)

        assert {:ok, owner} = Task.await(task)
        {id, text, root, io, owner}
      end)

    assert length(OhMyJido.list_sessions(@runtime)) == 2

    for {id, text, root, io, owner} <- opened do
      assert Elixos.Agents.whereis(id) == owner
      session = SessionOwner.session(owner)
      assert {:ok, %{workspace: ^root}} = OhMyJido.inspect_session(session)

      assert {:ok, %{content: ^text}} =
               OhMyJido.execute_tool(session, "read", %{path: "facts.txt"})

      script =
        expect_react do
          user("Read #{id} facts")
          call("read", %{path: "facts.txt"})
          answer(text)
        end

      {:ok, run} = OhMyJido.prompt(session, "Read #{id} facts", react_opts(script))
      assert {:ok, %{answer: ^text}} = OhMyJido.await(session, run)
      assert :ok = ElixosHost.snapshot(id)
      bytes = File.read!(Path.join(context.priv, "agents/#{id}.term"))

      assert %{version: 1, session: %{runtime: @runtime, id: ^id}} =
               :erlang.binary_to_term(bytes, [:safe])

      refute Fixtures.contains_handle?(:erlang.binary_to_term(bytes, [:safe]))
      assert Elixos.Image.agents(context.image)[id].opts[:workspace] == root
      assert :ok = ElixosHost.stop(id)
      refute Enum.any?(OhMyJido.list_sessions(@runtime), &(&1.id == id))

      restore =
        Task.async(fn ->
          Process.group_leader(self(), io)
          ElixosHost.open(runtime: @runtime, id: id, permissions: [:read])
        end)

      assert {:ok, restored_owner} = Task.await(restore)
      assert SessionOwner.session(restored_owner) == session

      assert {:ok, %{conversation: conversation, workspace: ^root}} =
               OhMyJido.inspect_session(session)

      assert Enum.any?(conversation, &(Map.get(&1, :content) == text))
      assert :ok = ElixosHost.stop(id)
      StringIO.close(io)
    end

    assert OhMyJido.list_sessions(@runtime) == []
    assert File.cwd!() == cwd
    assert System.get_env() == env
  end

  test "actual Image journal and Agents restore recover identity-only snapshots", context do
    {:ok, io} = StringIO.open("")

    create =
      Task.async(fn ->
        Process.group_leader(self(), io)
        {:ok, _root} = Elixos.Session.cd(context.root)
        ElixosHost.open(runtime: @runtime, id: "journal-restore", permissions: [:read])
      end)

    {:ok, owner} = Task.await(create)
    session = SessionOwner.session(owner)
    session_pid = GenServer.whereis(OhMyJido.Runtime.via(session))
    owner_monitor = Process.monitor(owner)
    session_monitor = Process.monitor(session_pid)

    script =
      expect_react do
        user("Keep this constraint durably")
        answer("Preserve the public increment API.")
      end

    {:ok, run} = OhMyJido.prompt(session, "Keep this constraint durably", react_opts(script))
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)
    assert :ok = ElixosHost.snapshot("journal-restore")
    :ok = stop_supervised(Elixos.Agents)
    assert Process.alive?(owner)
    assert Process.alive?(session_pid)
    :ok = stop_supervised(Elixos.Agents.Supervisor)
    assert OhMyJido.list_sessions(@runtime) == []
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}, 1_000
    assert_receive {:DOWN, ^session_monitor, :process, ^session_pid, :shutdown}, 1_000
    :ok = Elixos.Image.close(context.image)
    {:ok, reopened_image} = Elixos.Image.open(context.priv)
    Process.register(reopened_image, Elixos.Image)
    on_exit(fn -> if Process.alive?(reopened_image), do: Elixos.Image.close(reopened_image) end)
    assert Elixos.Image.agents(reopened_image)["journal-restore"].opts[:workspace] == context.root
    refute Fixtures.contains_handle?(Elixos.Image.agents(reopened_image))

    start_supervised!(
      Supervisor.child_spec(
        {DynamicSupervisor, name: Elixos.Agents.Supervisor, strategy: :one_for_one},
        id: Elixos.Agents.Supervisor
      )
    )

    start_supervised!({Elixos.Agents, {reopened_image, :normal}})
    restored_owner = Elixos.Agents.whereis("journal-restore")
    assert is_pid(restored_owner) and restored_owner != owner
    assert SessionOwner.session(restored_owner) == session
    refute GenServer.whereis(OhMyJido.Runtime.via(session)) == session_pid
    assert {:ok, %{conversation: conversation}} = OhMyJido.inspect_session(session)

    assert Enum.any?(
             conversation,
             &(Map.get(&1, :content) == "Preserve the public increment API.")
           )

    assert :ok = ElixosHost.stop("journal-restore")
    StringIO.close(io)
  end

  test "authorization waits on the actual Ask queue and defaults never authorize", context do
    context = Fixtures.context(context.root, host_opts: [approval_timeout_ms: 1_000])

    authorization =
      Task.async(fn ->
        OhMyJido.Tool.authorize(context, :exec, %{
          operation: :run,
          executable: "mix",
          args: ["test"],
          default: true
        })
      end)

    assert_receive {:elixos_ask, [%Elixos.Ask.Question{kind: :confirm, id: id, default: false}]}
    assert Task.yield(authorization, 0) == nil
    assert Elixos.Ask.answer(id, "yes") == {:error, :invalid_answer}
    assert Elixos.Ask.dismiss(id) == :ok
    assert Task.await(authorization) == {:error, :dismissed}
    assert Elixos.Ask.pending() == []

    authorization =
      Task.async(fn -> OhMyJido.Tool.authorize(context, :exec, %{operation: :run}) end)

    id = Fixtures.question_id()
    assert :ok = Elixos.Ask.answer(id, false)
    assert Task.await(authorization) == {:error, :approval_denied}

    authorization =
      Task.async(fn -> OhMyJido.Tool.authorize(context, :exec, %{operation: :run}) end)

    id = Fixtures.question_id()
    assert :ok = Elixos.Ask.answer(id, true)
    assert Task.await(authorization) == :ok

    deadline_context = Fixtures.context(context.workspace, host_opts: [approval_timeout_ms: 30])

    authorization =
      Task.async(fn -> OhMyJido.Tool.authorize(deadline_context, :exec, %{operation: :run}) end)

    id = Fixtures.question_id()
    assert Task.await(authorization) == {:error, :timeout}
    assert Elixos.Ask.answer(id, true) == {:error, :unknown_question}
    assert Elixos.Ask.pending() == []
  end

  test "unanswered host questions leave the real queue when the coding session owner dies",
       context do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    scoped = Fixtures.context(context.root, coordinator: owner)

    question =
      Task.async(fn -> ElixosHost.Host.question(scoped, %{question: "What constraint?"}, []) end)

    _id = Fixtures.question_id()
    monitor = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert Task.await(question) == {:error, :session_closed}
    assert_receive {:elixos_ask, []}
    assert Elixos.Ask.pending() == []
  end

  test "native run cancellation dismisses its actual queued host question", context do
    {:ok, io} = StringIO.open("")

    create =
      Task.async(fn ->
        Process.group_leader(self(), io)
        {:ok, _root} = Elixos.Session.cd(context.root)
        ElixosHost.open(runtime: @runtime, id: "waiting", permissions: [:ask])
      end)

    {:ok, owner} = Task.await(create)
    session = SessionOwner.session(owner)

    script =
      expect_react do
        user("Wait for a human constraint")
        call("question", %{question: "What should remain unchanged?"})
        answer("Constraint accepted.")
      end

    {:ok, run} = OhMyJido.prompt(session, "Wait for a human constraint", react_opts(script))
    _id = Fixtures.question_id()
    assert :ok = OhMyJido.cancel(session, run)
    assert {:error, %{status: :cancelled}} = OhMyJido.await(session, run)
    assert_receive {:elixos_ask, []}, 2_000
    assert Elixos.Ask.pending() == []
    assert :ok = ElixosHost.stop("waiting")
    StringIO.close(io)
  end

  test "helper requests cannot turn into commands or UID grants", context do
    scoped = Fixtures.context(context.root, host_opts: [helpers: ["postgres"]])

    assert ElixosHost.Privileges.invoke(
             scoped,
             %{name: "sh", command: "id", uid: 0},
             scoped.host |> elem(1)
           ) ==
             {:error, :invalid_helper_request}

    assert ElixosHost.Privileges.invoke(scoped, %{name: "sh"}, scoped.host |> elem(1)) ==
             {:error, :helper_not_allowed}

    assert Elixos.Ask.pending() == []
  end

  test "a human-approved helper delegates the real fixed-name wire and validated reply",
       context do
    control =
      start_supervised!(
        {Elixos.Shim.Control,
         name: nil, sink: {ElixosHost.HelperSinkFixture, self()}, heartbeat_ms: 60_000}
      )

    assert_receive {:helper_wire, "HB\n"}

    start_supervised!(
      {Elixos.Privileges,
       control: control, source: {ElixosHost.HelperReplyFixture, self()}, timeout_ms: 1_000}
    )

    assert_receive {:helper_reader, reader}
    options = [helpers: ["postgres"]]
    scoped = Fixtures.context(context.root, host_opts: options)

    helper =
      Task.async(fn -> ElixosHost.Privileges.invoke(scoped, %{name: "postgres"}, options) end)

    id = Fixtures.question_id()
    refute_receive {:helper_wire, "HELPER postgres\n"}, 20
    assert :ok = Elixos.Ask.answer(id, true)
    assert_receive {:helper_wire, "HELPER postgres\n"}
    send(reader, {:bytes, "HELPER postgres OK 42\n"})
    assert Task.await(helper) == {:ok, 42}
    refute_receive {:helper_wire, "NEXT " <> _}, 20
    refute_receive {:helper_wire, "COMMIT " <> _}, 20
  end

  test "deployment is opt in even for a granted session", context do
    scoped = Fixtures.context(context.root)

    assert ElixosHost.Candidate.invoke(
             scoped,
             %{operation: :propose, candidate_id: String.duplicate("a", 32)},
             []
           ) ==
             {:error, :deployment_disabled}

    assert Elixos.Ask.pending() == []
    assert Elixos.Image.generations(context.image) == []
  end

  test "native session owners shut down cleanly after their runtime has already stopped",
       context do
    create =
      Task.async(fn ->
        Elixos.Agents.start(SessionOwner,
          runtime: @runtime,
          id: "runtime-first",
          workspace: context.root,
          permissions: [:read]
        )
      end)

    {:ok, owner} = Task.await(create)
    session = SessionOwner.session(owner)
    session_pid = GenServer.whereis(OhMyJido.Runtime.via(session))
    assert {:ok, %{agent_pid: agent}} = OhMyJido.inspect_session(session)
    assert :ok = ElixosHost.snapshot("runtime-first")
    assert :ok = stop_supervised(ElixosHost.Supervisor)
    refute Process.alive?(session_pid)
    refute Process.alive?(agent)
    assert OhMyJido.Runtime.config(@runtime) == {:error, :runtime_unavailable}
    assert SessionOwner.session(owner) == session

    monitor = Process.monitor(owner)
    assert :ok = ElixosHost.stop("runtime-first")
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}, 1_000
    assert Elixos.Agents.list() == %{}
    assert Elixos.Image.agents(context.image) == %{}

    snapshot =
      context.priv
      |> Path.join("agents/runtime-first.term")
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    assert snapshot == %{version: 1, session: %{runtime: @runtime, id: "runtime-first"}}
    refute Fixtures.contains_handle?(snapshot)
  end
end
