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
       storage: {Jido.Persistence.File, path: Path.join(root, ".store")}}
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
    assert %{agent_id: ^id} = Jido.AgentServer.status(agent)
    :ok = OhMyJido.checkpoint(session)
    :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, %{conversation: conversation}} = OhMyJido.inspect_session(session)

    assert Enum.any?(
             conversation,
             &(Jido.AI.Model.Response.extract_from_content(Map.get(&1, :content)) ==
                 "No edits were needed.")
           )
  end

  test "native usage and tool identities survive summary projection and a host restart",
       %{workspace: root} do
    File.write!(Path.join(root, "input.txt"), "observed input")

    options = [
      name: __MODULE__.Usage,
      allow_test_scripts: true,
      storage: {Jido.Persistence.File, path: Path.join(root, ".store")}
    ]

    start_supervised!({Runtime, options})

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Usage, workspace: root, permissions: [:read])

    script =
      expect_react do
        user("Inspect input")

        call("read", %{path: "input.txt"}, usage: %{input_tokens: 11, output_tokens: 3})

        answer("Input was inspected.",
          usage: %{input_tokens: 17, output_tokens: 5}
        )
      end

    {:ok, run} = OhMyJido.prompt(session, "Inspect input", react_opts(script))
    assert {:ok, result} = OhMyJido.await(session, run)
    assert result.usage.input_tokens == 28
    assert result.usage.output_tokens == 8
    assert result.usage.total_tokens == 36

    turns =
      for %Event{kind: :llm_completed, payload: %{usage: usage}} <- OhMyJido.events(session),
          do: usage

    assert Enum.map(turns, &{&1.input_tokens, &1.output_tokens}) == [{11, 3}, {17, 5}]

    # ReActScript sends token counters over real HTTP/SSE. ReqLLM derives cost
    # from its mock model's billing metadata; scripts cannot set provider cost.
    costs = Enum.map(turns, & &1.total_cost)
    assert Enum.all?(costs, &(is_number(&1) and &1 >= 0))
    assert_in_delta result.usage.total_cost, Enum.sum(costs), 1.0e-12
    assert [%{name: "read", status: :completed}] = result.tools
    assert File.read!(Path.join(root, "input.txt")) == "observed input"

    assert {:ok, %{conversation: before, agent_pid: agent}} = OhMyJido.inspect_session(session)
    assert Enum.any?(before, &match?(%{metadata: %{oh_my_jido_context_summary: _}}, &1))

    assert [%{role: :assistant, refs: refs} = terminal] =
             Enum.filter(before, fn message ->
               Jido.AI.Model.Response.extract_from_content(message.content) ==
                 "Input was inspected."
             end)

    assert is_binary(refs.request_id)
    assert is_binary(refs.run_id)
    refute Map.has_key?(refs, :context)
    assert [call] = Enum.flat_map(before, &List.wrap(Map.get(&1, :tool_calls)))
    call_data = ReqLLM.ToolCall.to_map(call)
    assert %{name: "read", id: call_id} = call_data
    assert [%{tool_call_id: ^call_id}] = Enum.filter(before, &(&1.role == :tool))

    native = Jido.AgentServer.agent(agent).state.conversation
    assert {:ok, native_messages} = Jido.AI.Thread.Projection.project(native)
    assert List.last(native_messages).refs == terminal.refs

    assert Enum.map(
             Enum.flat_map(native_messages, &List.wrap(Map.get(&1, :tool_calls))),
             &ReqLLM.ToolCall.to_map/1
           ) == [call_data]

    assert List.last(native_messages).content == terminal.content

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert :ok = stop_supervised(__MODULE__.Usage)
    start_supervised!({Runtime, options})
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Usage, session.id)

    assert {:ok, %{agent_pid: restored}} = OhMyJido.inspect_session(session)

    assert {:ok, restored_messages} =
             Jido.AI.Thread.Projection.project(
               Jido.AgentServer.agent(restored).state.conversation
             )

    assert List.last(restored_messages).refs == terminal.refs
    assert List.last(restored_messages).content == terminal.content

    assert Enum.map(
             Enum.flat_map(restored_messages, &List.wrap(Map.get(&1, :tool_calls))),
             &ReqLLM.ToolCall.to_map/1
           ) == [call_data]

    assert [%{tool_call_id: ^call_id}] = Enum.filter(restored_messages, &(&1.role == :tool))
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

  test "an explicit host model bootstraps natively without depending on the module's default alias",
       %{workspace: root} do
    previous = Application.fetch_env(:jido_ai, :model_aliases)

    on_exit(fn ->
      case previous do
        {:ok, aliases} -> Application.put_env(:jido_ai, :model_aliases, aliases)
        :error -> Application.delete_env(:jido_ai, :model_aliases)
      end
    end)

    Application.put_env(:jido_ai, :model_aliases, %{capable: "unconfigured-provider:missing"})
    File.write!(Path.join(root, "selected-model.txt"), "real native read\n")

    start_supervised!(
      {Runtime,
       name: __MODULE__.ExplicitModel,
       allow_test_scripts: true,
       model_roles: %{coding: "anthropic:claude-haiku-4-5"}}
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.ExplicitModel,
        workspace: root,
        tools: [OhMyJido.Tools.Read],
        permissions: [:read]
      )

    script =
      expect_react do
        user("Inspect the file through the explicitly selected host model")
        call("read", %{path: "selected-model.txt"})
        answer("The host-selected model completed its native turn.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, script.user, react_opts(script))

    assert {:ok, %{status: :completed, tools: [%{name: "read", status: :completed}]}} =
             OhMyJido.await(session, run, timeout: 5_000)

    assert {:ok, %{effects: effects, model: "anthropic:claude-haiku-4-5"}} =
             OhMyJido.inspect_session(session)

    assert [%{result: {:ok, %{content: "real native read\n"}, _directives}}] = Map.values(effects)
    assert :ok = OhMyJido.stop_session(session)
  end

  test "independent instances keep sessions and grants separate", %{workspace: root} do
    for name <- [__MODULE__.One, __MODULE__.Two] do
      start_supervised!(
        {Runtime,
         name: name,
         allow_test_scripts: true,
         storage: {Jido.Persistence.File, path: Path.join(root, Atom.to_string(name))}}
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
