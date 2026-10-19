defmodule OhMyJido.CodingAgent do
  @moduledoc """
  The coding profile of the installed Jido.AI ReAct agent.

  Jido owns reasoning, model streaming, tool scheduling, steering and cancellation.
  These hooks add durable effect ownership and host authorization; they do not
  replace the native loop. Tool retries are deliberately disabled.
  """

  use Jido.AI.Agent,
    name: "oh_my_jido_coding",
    model: :capable,
    tools: [],
    tool_max_retries: 0,
    max_iterations: 40,
    request_transformer: OhMyJido.Models.Transformer,
    observability: %{redact_tool_args?: true, emit_telemetry?: true},
    signal_routes: [
      {"oh_my_jido.stop_child", OhMyJido.Actions.StopChild}
    ]

  alias OhMyJido.{Context, Session, Tool}

  @doc false
  def private_diagnostics?, do: true

  @impl Jido.AI.ToolInterceptor
  def before_tool_call(call, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize_custom(context, call.action_module, call.arguments),
         :ok <- Session.effect_started(context.coordinator, context.run_id, call) do
      {:ok, call}
    end
  end

  @impl Jido.AI.ToolInterceptor
  def after_tool_call(call, result, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         {:ok, safe_result} <- Session.redact_result(context.coordinator, result),
         :ok <- Session.effect_finished(context.coordinator, context.run_id, call.id, safe_result) do
      {:ok, safe_result}
    end
  end
end
