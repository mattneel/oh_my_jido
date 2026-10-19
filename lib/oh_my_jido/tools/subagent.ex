defmodule OhMyJido.Tools.Subagent do
  @moduledoc "Bounded, privilege-narrowed delegation through the native Jido hierarchy."
  use Jido.Action,
    name: "subagent",
    description:
      "Start distinct read-only tasks or isolated mutating work; monitor, wait, steer, or cancel a tracked child.",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["start", "wait", "steer", "cancel"]),
          task: Zoi.string() |> Zoi.optional(),
          tag: Zoi.string() |> Zoi.optional(),
          role:
            Zoi.enum(["coding", "planning", "exploration", "review", "advisor"])
            |> Zoi.default("exploration"),
          writable: Zoi.boolean() |> Zoi.default(false),
          text: Zoi.string() |> Zoi.optional(),
          timeout: Zoi.integer() |> Zoi.min(1) |> Zoi.default(30_000)
        },
        coerce: true
      )

  alias OhMyJido.{Context, SessionRef, Tool}
  @doc false
  def capability, do: :delegate

  @impl true
  def run(params, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context) do
      parent = %SessionRef{runtime: context.runtime, id: context.session_id}
      operate(parent, context, params)
    end
  end

  defp operate(parent, _context, %{operation: "start", task: task} = params) do
    opts = [role: role(params.role), writable: params.writable]
    opts = if params[:tag], do: Keyword.put(opts, :tag, params.tag), else: opts

    with {:ok, child} <- OhMyJido.delegate(parent, task, opts) do
      {:ok,
       %{
         tag: child.tag,
         session_id: child.session.id,
         run_id: child.run,
         workspace: child.workspace,
         role: child.role
       }}
    end
  end

  defp operate(parent, context, %{operation: "wait", tag: tag, timeout: timeout}) do
    with :ok <- Tool.authorize(context, :delegate, %{operation: :wait, tag: tag}) do
      OhMyJido.await_child(parent, tag, timeout: timeout)
    end
  end

  defp operate(parent, context, %{operation: "steer", tag: tag, text: text}) do
    with :ok <- Tool.authorize(context, :delegate, %{operation: :steer, tag: tag}),
         :ok <- OhMyJido.steer_child(parent, tag, text),
         do: {:ok, %{status: :queued}}
  end

  defp operate(parent, context, %{operation: "cancel", tag: tag}) do
    with :ok <- Tool.authorize(context, :delegate, %{operation: :cancel, tag: tag}),
         :ok <- OhMyJido.cancel_child(parent, tag),
         do: {:ok, %{status: :cancellation_requested}}
  end

  defp operate(_parent, _context, _params), do: {:error, :missing_subagent_parameters}

  defp role("coding"), do: :coding
  defp role("planning"), do: :planning
  defp role("exploration"), do: :exploration
  defp role("review"), do: :review
  defp role("advisor"), do: :advisor
end
