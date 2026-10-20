defmodule PlainMixHost.EmbeddedHostTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.Event

  @moduletag :tmp_dir
  @moduletag timeout: 60_000
  @runtime PlainMixHost.TestCoding

  setup %{tmp_dir: root} do
    options = [
      runtime: @runtime,
      storage_path: Path.join(root, "store"),
      allow_test_scripts: true
    ]

    start_supervised!({PlainMixHost.Supervisor, options})
    workspace = Path.join(root, "project")
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(Path.join(workspace, "test"))

    File.write!(Path.join(workspace, "mix.exs"), """
    defmodule RepairFixture.MixProject do
      use Mix.Project
      def project, do: [app: :repair_fixture, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(workspace, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(workspace, "test/counter_test.exs"), """
    defmodule RepairFixture.CounterTest do
      use ExUnit.Case
      test "increments without changing other behavior" do
        assert RepairFixture.Counter.increment(4) == 5
        assert RepairFixture.Counter.label() == "counter"
      end
    end
    """)

    source = """
    defmodule RepairFixture.Counter do
      def increment(value), do: value - 1
      def label, do: "counter"
    end
    """

    File.write!(Path.join(workspace, "lib/counter.ex"), source)
    %{workspace: workspace, source: source, options: options}
  end

  test "embedded native ReAct repairs code, runs the real suite and restores across a host restart",
       context do
    cwd = File.cwd!()
    env = System.get_env()
    {:ok, session} = PlainMixHost.open(context.workspace, runtime: @runtime)
    :ok = OhMyJido.subscribe(session, self())
    snapshot = :crypto.hash(:sha256, context.source) |> Base.encode16(case: :lower)

    script =
      expect_react do
        user("Repair increment and verify the project without changing label")
        call("read", %{path: "lib/counter.ex"})

        call("edit", %{
          path: "lib/counter.ex",
          snapshot: snapshot,
          edits: [%{old: "value - 1", new: "value + 1"}]
        })

        call("shell", %{
          executable: System.find_executable("mix"),
          args: ["test"],
          env: %{"MIX_ENV" => "test", "ELIXIR_ERL_OPTIONS" => "+S 2:2 +A 2"},
          timeout_ms: 30_000
        })

        answer("The increment is repaired and the project test passed.")
      end

    {:ok, run} =
      PlainMixHost.submit(
        session,
        "Repair increment and verify the project without changing label",
        react_opts(script)
      )

    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run, timeout: 45_000)

    assert File.read!(Path.join(context.workspace, "lib/counter.ex")) ==
             String.replace(context.source, "value - 1", "value + 1")

    events = OhMyJido.events(session)
    assert Enum.any?(events, &(&1.kind == :tool_completed && &1.payload.tool_name == "edit"))

    assert {:ok, %{effects: effects, conversation: before}} = OhMyJido.inspect_session(session)

    assert Enum.any?(Map.values(effects), fn
             %{
               name: "shell",
               status: :completed,
               result:
                 {:ok,
                  %{exit_status: 0, status: :exited, cleanup: :confirmed, effect: :completed},
                  _effects}
             } ->
               true

             _effect ->
               false
           end)

    assert Enum.any?(events, &(&1.kind == :run_completed))
    assert Enum.map(events, & &1.seq) == Enum.sort(Enum.uniq(Enum.map(events, & &1.seq)))
    assert_receive {:oh_my_jido, %Event{session_id: id}}
    assert id == session.id
    :ok = OhMyJido.checkpoint(session)
    :ok = OhMyJido.stop_session(session)
    :ok = stop_supervised(PlainMixHost.Supervisor)
    start_supervised!({PlainMixHost.Supervisor, context.options})
    assert {:ok, ^session} = PlainMixHost.restore(session.id, runtime: @runtime)
    assert {:ok, %{conversation: conversation}} = OhMyJido.inspect_session(session)

    assert conversation == before

    assert [_terminal] =
             Enum.filter(conversation, fn message ->
               message.role == :assistant and
                 Jido.AI.Model.Response.extract_from_content(message.content) ==
                   "The increment is repaired and the project test passed."
             end)

    calls =
      for message <- conversation,
          call <- List.wrap(Map.get(message, :tool_calls)),
          do: ReqLLM.ToolCall.to_map(call)

    assert Enum.map(calls, & &1.name) == ["read", "edit", "shell"]
    call_ids = Enum.map(calls, & &1.id)
    assert call_ids == Enum.uniq(call_ids)
    assert Enum.map(Enum.filter(conversation, &(&1.role == :tool)), & &1.tool_call_id) == call_ids

    assert File.cwd!() == cwd
    assert System.get_env() == env
  end

  test "public answers, steering, suspension and cancellation control an actual waiting run",
       context do
    {:ok, session} = PlainMixHost.open(context.workspace, runtime: @runtime)
    :ok = OhMyJido.subscribe(session, self())
    script = waiting_script("Ask before deciding")
    {:ok, run} = PlainMixHost.submit(session, "Ask before deciding", react_opts(script))
    question = approval(session)
    assert :ok = OhMyJido.answer(session, question, "Keep the API")
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)

    for {operation, previous_turns} <- Enum.with_index([:suspend, :cancel], 1) do
      task = "Wait for #{operation}"

      {:ok, run} =
        PlainMixHost.submit(session, task, react_opts(waiting_script(task, previous_turns)))

      question = approval(session)
      assert :ok = OhMyJido.steer(session, run, "Do not edit files")
      assert :ok = apply(OhMyJido, operation, [session, run])
      status = if operation == :suspend, do: :suspended, else: :cancelled
      assert {:error, %{status: ^status}} = OhMyJido.await(session, run)
      assert {:error, :unknown_question} = OhMyJido.answer(session, question, true)
      if operation == :suspend, do: assert(:ok = OhMyJido.resume(session))
    end

    assert File.read!(Path.join(context.workspace, "lib/counter.ex")) == context.source
  end

  defp waiting_script(task, previous_turns \\ 0) do
    expect_react do
      user(task)
      # Native fixture indexing counts tool turns in the retained transcript.
      for index <- 0..previous_turns,
          do:
            call("question", %{question: "Which public API must remain?"}, id: "#{task}-#{index}")

      answer("The operator constraint is retained.")
    end
  end

  defp approval(session) do
    receive do
      {:oh_my_jido, %Event{session_id: id, kind: :approval_requested, payload: %{id: question}}}
      when id == session.id ->
        question

      {:oh_my_jido, _event} ->
        approval(session)
    after
      5_000 ->
        assert {:ok, snapshot} = OhMyJido.inspect_session(session)

        flunk(
          "no public approval event: #{inspect(Map.take(snapshot, [:runs, :pending_questions]), limit: :infinity)}"
        )
    end
  end
end
