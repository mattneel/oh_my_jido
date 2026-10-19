defmodule OhMyJido.Tools.Goal do
  @moduledoc "Tracks a session goal and plan, and rejects completion without verified effect references."
  use Jido.Action,
    name: "goal",
    description:
      "Set or inspect the goal, track TODO tasks, and complete only with observed check effect IDs.",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["inspect", "set", "plan", "complete"]),
          goal: Zoi.string() |> Zoi.optional(),
          items: Zoi.list(Zoi.map()) |> Zoi.optional(),
          effect_ids: Zoi.list(Zoi.string()) |> Zoi.optional()
        },
        coerce: true
      )

  alias OhMyJido.{Context, Session, Tool}

  @doc false
  def capability, do: :planning

  @impl true
  def run(params, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, :planning, %{operation: params.operation}) do
      apply_operation(context, params)
    end
  end

  defp apply_operation(context, %{operation: "inspect"}) do
    with {:ok, snapshot} <- Session.call(context.coordinator, :inspect) do
      {:ok, Map.take(snapshot, [:goal, :plan, :retained, :effects])}
    end
  end

  defp apply_operation(context, %{operation: "set", goal: goal}) do
    with :ok <- Session.call(context.coordinator, {:retain, %{goal: goal}}),
         do: {:ok, %{goal: goal}}
  end

  defp apply_operation(context, %{operation: "plan", items: items}) do
    with :ok <- Session.call(context.coordinator, {:plan, items}), do: {:ok, %{status: :updated}}
  end

  defp apply_operation(context, %{operation: "complete", effect_ids: ids}) do
    with :ok <- Session.call(context.coordinator, {:goal_complete, %{effect_ids: ids}}),
         do: {:ok, %{status: :completed}}
  end

  defp apply_operation(_context, _params), do: {:error, :missing_goal_operation_parameters}
end

defmodule OhMyJido.Tools.Memory do
  @moduledoc "Retains explicit task-critical facts across compaction and worker restart."
  use Jido.Action,
    name: "memory",
    description:
      "Retain task constraints, relevant file facts, notes, and unresolved work durably.",
    schema: Zoi.object(%{facts: Zoi.map()}, coerce: true)

  alias OhMyJido.{Context, Session, Tool}
  @doc false
  def capability, do: :memory

  @impl true
  def run(%{facts: facts}, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, :memory, %{}),
         :ok <- Session.call(context.coordinator, {:retain, facts}) do
      {:ok, %{status: :retained}}
    end
  end
end
