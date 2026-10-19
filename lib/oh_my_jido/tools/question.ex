defmodule OhMyJido.Tools.Question do
  @moduledoc "Pauses a tool for host-owned structured human clarification."
  use Jido.Action,
    name: "question",
    description: "Ask a structured question through the host and wait for an explicit answer.",
    schema:
      Zoi.object(
        %{
          question: Zoi.string(),
          options: Zoi.list(Zoi.map()) |> Zoi.default([]),
          multi: Zoi.boolean() |> Zoi.default(false)
        },
        coerce: true
      )

  alias OhMyJido.{Context, Session, Tool}
  @doc false
  def capability, do: :ask

  @impl true
  def run(question, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, :ask, %{question: question.question}),
         {:ok, answer} <- Session.question(context.coordinator, question) do
      {:ok, %{answer: answer}}
    end
  end
end

defmodule OhMyJido.Tools.Experiment do
  @moduledoc "Runs explicitly bounded tool trials and retains measured results."
  use Jido.Action,
    name: "experiment",
    description:
      "Run a bounded list of approved registered-tool trials once and record timings, results and artifacts.",
    schema:
      Zoi.object(
        %{
          trials: Zoi.list(Zoi.object(%{tool: Zoi.string(), params: Zoi.map()}, coerce: true)),
          timeout: Zoi.integer() |> Zoi.min(1) |> Zoi.default(30_000)
        },
        coerce: true
      )

  alias OhMyJido.{Context, Experiment}
  @doc false
  def capability, do: :experiments

  @impl true
  def run(%{trials: trials, timeout: timeout}, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context) do
      Experiment.execute(context, trials, timeout: timeout)
    end
  end
end
