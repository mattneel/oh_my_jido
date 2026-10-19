defmodule OhMyJido.RuntimeTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.{Event, Runtime}

  setup do
    workspace = Path.join(System.tmp_dir!(), "omj-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    %{workspace: workspace}
  end

  test "a host supervises real Jido agents, observes ordered events and restarts a durable identity",
       %{workspace: root} do
    start_supervised!(
      {Runtime,
       name: __MODULE__.Host,
       allow_test_scripts: true,
       storage: {Jido.Storage.File, path: Path.join(root, ".store")}}
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, permissions: [:read])

    :ok = OhMyJido.subscribe(session, self())

    script =
      expect_react do
        user("Explain the repository")
        answer("No edits were needed.")
      end

    {:ok, run} = OhMyJido.prompt(session, "Explain the repository", react_opts(script))

    assert {:ok, %{answer: "No edits were needed.", status: :completed}} =
             OhMyJido.await(session, run)

    events = OhMyJido.events(session)
    assert Enum.any?(events, &(&1.kind == :run_completed))
    assert Enum.map(events, & &1.seq) == Enum.sort(Enum.uniq(Enum.map(events, & &1.seq)))
    assert_receive {:oh_my_jido, %Event{session_id: id}}
    assert id == session.id
    assert {:ok, %{agent_pid: agent}} = OhMyJido.inspect_session(session)
    assert {:ok, _status} = Jido.AgentServer.status(agent)
    :ok = OhMyJido.checkpoint(session)
    :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, %{conversation: conversation}} = OhMyJido.inspect_session(session)
    assert Enum.any?(conversation, &(Map.get(&1, :content) == "No edits were needed."))
  end

  test "a multi-turn native run reports total usage and actual tool outcomes", %{workspace: root} do
    File.write!(Path.join(root, "input.txt"), "observed input")
    start_supervised!({Runtime, name: __MODULE__.Usage, allow_test_scripts: true})

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Usage, workspace: root, permissions: [:read])

    script =
      expect_react do
        user("Inspect input")

        call("read", %{path: "input.txt"},
          usage: %{input_tokens: 11, output_tokens: 3, total_cost: 0.02}
        )

        answer("Input was inspected.",
          usage: %{input_tokens: 17, output_tokens: 5, total_cost: 0.04}
        )
      end

    {:ok, run} = OhMyJido.prompt(session, "Inspect input", react_opts(script))
    assert {:ok, result} = OhMyJido.await(session, run)
    assert result.usage.input_tokens == 28
    assert result.usage.output_tokens == 8
    assert_in_delta result.usage.total_cost, 0.06, 0.000001
    assert [%{name: "read", status: :completed}] = result.tools
    assert File.read!(Path.join(root, "input.txt")) == "observed input"
  end

  test "session listing excludes dead registrations before native Registry cleanup",
       %{workspace: root} do
    runtime = __MODULE__.RegistryCleanup
    start_supervised!({Runtime, name: runtime})

    {:ok, live} =
      OhMyJido.start_session(runtime, workspace: root, permissions: [:read], id: "live")

    {:ok, stopped} =
      OhMyJido.start_session(runtime, workspace: root, permissions: [:read], id: "stopped")

    stopped_pid = GenServer.whereis(Runtime.via(stopped))
    stopped_monitor = Process.monitor(stopped_pid)
    registry = Runtime.registry(runtime)
    [{_id, partition, :worker, _modules}] = Supervisor.which_children(registry)
    :ok = :sys.suspend(partition, 1_000)

    try do
      assert :ok = OhMyJido.stop_session(stopped)
      assert_receive {:DOWN, ^stopped_monitor, :process, ^stopped_pid, :shutdown}, 1_000
      refute Process.alive?(stopped_pid)
      assert [{^stopped_pid, _value}] = Registry.lookup(registry, stopped.id)
      assert GenServer.whereis(Runtime.via(stopped)) == nil
      assert OhMyJido.list_sessions(runtime) == [live]
    after
      :ok = :sys.resume(partition, 1_000)
    end
  end

  test "independent instances keep sessions and grants separate", %{workspace: root} do
    for name <- [__MODULE__.One, __MODULE__.Two] do
      start_supervised!(
        {Runtime,
         name: name,
         allow_test_scripts: true,
         storage: {Jido.Storage.File, path: Path.join(root, Atom.to_string(name))}}
      )
    end

    {:ok, first} =
      OhMyJido.start_session(__MODULE__.One, workspace: root, permissions: [:read], id: "same")

    {:ok, second} =
      OhMyJido.start_session(__MODULE__.Two, workspace: root, permissions: [:edit], id: "same")

    assert {:ok, %{permissions: [:read]}} = OhMyJido.inspect_session(first)
    assert {:ok, %{permissions: [:edit]}} = OhMyJido.inspect_session(second)
    :ok = OhMyJido.stop_session(first)
    assert {:ok, %{status: :idle}} = OhMyJido.inspect_session(second)
  end
end
