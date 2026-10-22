defmodule OhMyJido.ToolCallLimitsTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.{Event, Runtime}

  @moduletag timeout: 60_000
  @moduletag capture_log: true

  defmodule Stall do
    use Jido.Action,
      name: "stall",
      description: "Never returns; only the enclosing call limit ends it.",
      schema: []

    def capability, do: :read

    @impl true
    def run(_params, execution_context) do
      {:ok, context} = OhMyJido.Context.fetch(execution_context)
      :ok = OhMyJido.Tool.authorize(context, :read, %{operation: :stall})
      Process.sleep(:infinity)
    end
  end

  defmodule ApprovingHost do
    @behaviour OhMyJido.Host

    alias OhMyJido.Host.Local

    @impl true
    def authorize(_context, :exec, effect, _options),
      do: {:approval, %{kind: :effect, capability: :exec, effect: effect}}

    def authorize(context, capability, effect, options),
      do: Local.authorize(context, capability, effect, options)

    @impl true
    def credentials(context, account, options), do: Local.credentials(context, account, options)

    @impl true
    def invoke(context, capability, request, options),
      do: Local.invoke(context, capability, request, options)

    @impl true
    def question(context, question, options), do: Local.question(context, question, options)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-call-limits-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "an agent-started call ends at the runtime's tool and question limits", %{root: root} do
    start_runtime(tool_timeout_ms: 300, question_timeout_ms: 300, tools: [Stall])

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, permissions: [:read])

    script =
      expect_react do
        user("Stall")
        call("stall", %{}, id: "stall-call")
        answer("The stalled call ended.")
      end

    started = System.monotonic_time(:millisecond)
    {:ok, run} = OhMyJido.prompt(session, "Stall", react_opts(script))

    # The SDK either reports the stopped call as a tool error or, when its own
    # stream deadline wins a 50 ms race, fails the run. Both end at the limit.
    assert {_, %{status: status}} = OhMyJido.await(session, run, timeout: 30_000)
    assert status in [:completed, :failed]
    assert System.monotonic_time(:millisecond) - started < 10_000
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert %{status: :uncertain} = effects["stall-call"]
  end

  test "an agent-started question may wait longer than the tool budget", %{root: root} do
    start_runtime(
      tool_timeout_ms: 300,
      question_timeout_ms: 10_000,
      tools: [OhMyJido.Tools.Question]
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, permissions: [:ask])

    :ok = OhMyJido.subscribe(session, self())

    script =
      expect_react do
        user("Ask before continuing")
        call("question", %{question: "May I continue?"}, id: "question-call")
        answer("The operator answered.")
      end

    {:ok, run} = OhMyJido.prompt(session, "Ask before continuing", react_opts(script))
    question = approval(session)
    Process.sleep(1_000)

    assert :ok = OhMyJido.answer(session, question, "yes")
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run, timeout: 30_000)
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)

    assert %{status: :completed, result: {:ok, %{answer: "yes"}, _directives}} =
             effects["question-call"]
  end

  test "a direct call may wait for approval longer than the tool budget", %{root: root} do
    start_runtime(
      tool_timeout_ms: 1_000,
      question_timeout_ms: 10_000,
      host: {ApprovingHost, []},
      tools: [OhMyJido.Tools.Shell]
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, permissions: [:exec])

    :ok = OhMyJido.subscribe(session, self())

    call =
      Task.async(fn ->
        OhMyJido.execute_tool(session, "shell", %{
          executable: "sh",
          args: ["-c", "printf approved"]
        })
      end)

    question = approval(session)
    Process.sleep(2_000)

    assert :ok = OhMyJido.answer(session, question, :approve)
    assert {:ok, %{exit_status: 0, stdout: "approved"}} = Task.await(call, 30_000)
  end

  test "a question is withdrawn when its waiting call ends", %{root: root} do
    start_runtime(
      tool_timeout_ms: 1_000,
      question_timeout_ms: 10_000,
      host: {ApprovingHost, []},
      tools: [OhMyJido.Tools.Shell]
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, permissions: [:exec])

    :ok = OhMyJido.subscribe(session, self())

    call =
      Task.async(fn ->
        OhMyJido.execute_tool(
          session,
          "shell",
          %{executable: "sh", args: ["-c", "printf late > late.txt"]},
          timeout: 300
        )
      end)

    question = approval(session)
    assert {:error, _timed_out} = Task.await(call, 10_000)

    assert_receive {:oh_my_jido,
                    %Event{
                      kind: :approval_answered,
                      payload: %{id: ^question, answer: {:error, :withdrawn}}
                    }},
                   5_000

    assert {:error, :unknown_question} = OhMyJido.answer(session, question, :approve)
    refute File.exists?(Path.join(root, "late.txt"))
  end

  defp start_runtime(options) do
    start_supervised!(
      {Runtime, Keyword.merge([name: __MODULE__.Host, allow_test_scripts: true], options)}
    )
  end

  defp approval(session) do
    receive do
      {:oh_my_jido, %Event{session_id: id, kind: :approval_requested, payload: %{id: question}}}
      when id == session.id ->
        question

      {:oh_my_jido, _event} ->
        approval(session)
    after
      5_000 -> flunk("no approval was requested")
    end
  end
end
