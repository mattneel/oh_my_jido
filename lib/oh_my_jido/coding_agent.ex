defmodule OhMyJido.CodingAgent do
  @moduledoc """
  The coding profile of the installed Jido.AI ReAct agent.

  Jido owns reasoning, model streaming, tool scheduling, steering and cancellation.
  These hooks add durable effect ownership and host authorization; they do not
  replace the native loop. Tool retries are deliberately disabled. Each request
  limits its tool calls with the session's `OhMyJido.Tool.call_timeout/1`.
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

  @impl true
  def on_before_cmd(agent, {:ai_react_start, params} = action),
    do: super(limit_tool_calls(agent, params), action)

  def on_before_cmd(agent, action), do: super(agent, action)

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

  # Jido.AI 2.4 reads one per-tool deadline from its strategy config, and every
  # AgentServer start rebuilds that config from this module's compile-time
  # options. Apply the session's call limit to the request that is starting.
  defp limit_tool_calls(agent, params) do
    case Context.fetch(Map.get(params, :tool_context, %{})) do
      {:ok, context} ->
        timeout = Tool.call_timeout(context)

        Jido.Agent.Strategy.State.update(agent, fn state ->
          Map.update(
            state,
            :config,
            %{tool_timeout_ms: timeout},
            &Map.put(&1, :tool_timeout_ms, timeout)
          )
        end)

      {:error, _reason} ->
        agent
    end
  end
end
