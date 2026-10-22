defmodule OhMyJido.CodingAgent do
  @moduledoc """
  The coding profile of the native V3 Jido.AI Agent.

  Jido's request Coordinator and Flow own reasoning, provider streaming, tool
  scheduling, steering and cancellation. Host hooks add durable effect ownership
  and authorization. Every coding tool is declared unsafe-once with zero retries
  and limited by the session's `OhMyJido.Tool.call_timeout/1`.
  Private host authority is caller context, never portable Agent or Signal data.
  """

  use Jido.AI.Agent, name: "oh_my_jido_coding"

  agent do
    schema(
      Zoi.object(%{
        result: Zoi.any() |> Zoi.default(nil),
        conversation: Jido.AI.Thread.Projection.schema()
      })
    )

    ai :assistant do
      model(:capable)
      reasoning(:react, request_transformer: OhMyJido.Models.Transformer)

      controls do
        max_iterations(40)
        max_model_calls(40)
        max_tool_calls(1_024)
        timeout(300_000)
        steering(true)
      end

      observability do
        redact_tool_args(true)
        stream_content(true)
        store_content(true)
        stream_reasoning(true)
        store_reasoning(true)
      end

      memory(history: :conversation)
      result(into: :result)
    end
  end

  routes do
    signal_source("/oh-my-jido")

    route("oh_my_jido.query", ai: :assistant, as: :query)
    route("oh_my_jido.stop_child", OhMyJido.Actions.StopChild)
  end

  alias OhMyJido.{Context, Session, Tool}

  @behaviour Jido.AI.ToolInterceptor

  @tool_defaults %{forward_context: :all, max_retries: 0, idempotency: :unsafe_once}

  @doc false
  def private_diagnostics?, do: true

  @doc false
  def configure(%Jido.Agent{} = agent, %Context{} = context, config) do
    defaults = Map.put(@tool_defaults, :timeout, Tool.call_timeout(context))
    profile = Jido.AI.Agent.profile(__MODULE__, :assistant)

    # Native Prepare resolves this model before the request transformer runs.
    # Bind the selected session input, not a module-default application alias
    # that an independent host has no obligation to configure.
    models =
      Map.update!(profile.models, profile.reasoning.model, &Map.put(&1, :model, context.model))

    with {:ok, tools} <- Jido.AI.ToolCatalog.from_input(context.tools, defaults),
         {:ok, profile} <-
           Jido.AI.Profile.new(%{
             profile
             | models: models,
               tools: tools,
               controls: %{
                 max_iterations: Keyword.fetch!(config, :max_iterations),
                 max_model_calls: Keyword.fetch!(config, :max_iterations),
                 max_tool_calls: Keyword.fetch!(config, :max_effects),
                 timeout: Keyword.fetch!(config, :run_timeout_ms),
                 steering: true
               },
               reasoning: %{
                 method: :react,
                 request_transformer:
                   Keyword.get(config, :request_transformer, OhMyJido.Models.Transformer)
               }
           }),
         {:ok, definition} <- configured_definition(agent, profile, defaults),
         {:ok, configured} <-
           Jido.Agent.instantiate(definition, id: agent.id, state: agent.state) do
      Jido.AI.Configuration.direct(configured, :tools, tools)
    end
  end

  defp configured_definition(agent, profile, defaults) do
    definition = Jido.Agent.definition(agent)
    plugins = Enum.map(definition.plugins, &configure_plugin(&1, profile, defaults))

    # Runtime-selected profiles are native embedded definitions, not an instance
    # of the generated module's immutable versioned definition. Core checkpoints
    # retain this validated definition and verify its module on restore.
    Jido.Agent.new(%{definition | plugins: plugins, vsn: nil})
  end

  defp configure_plugin({Jido.AI.Configuration.Plugin, opts}, profile, defaults) do
    {Jido.AI.Configuration.Plugin,
     opts
     |> Keyword.put(:profiles, %{assistant: profile})
     |> Keyword.put(:tool_defaults, defaults)}
  end

  defp configure_plugin({Jido.AI.Orchestration.Plugin, opts}, profile, _defaults),
    do: {Jido.AI.Orchestration.Plugin, Keyword.put(opts, :profiles, %{assistant: profile})}

  defp configure_plugin(declaration, _profile, _defaults), do: declaration

  @impl Jido.AI.ToolInterceptor
  def before_tool_call(call, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         {:ok, %Jido.AI.Orchestration.ExecutionBinding{} = binding} <-
           Jido.AI.Orchestration.ExecutionBinding.fetch(execution_context),
         :ok <- Tool.authorize_custom(context, call.action_module, call.arguments),
         :ok <- Session.native_effect_started(context.coordinator, context.run_id, call, binding) do
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

  @impl Jido.AI.ToolInterceptor
  def tool_execution_started(call, proof, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         {:ok, %Jido.AI.Orchestration.ExecutionBinding{} = binding} <-
           Jido.AI.Orchestration.ExecutionBinding.fetch(execution_context) do
      Session.native_execution_started(
        context.coordinator,
        context.run_id,
        call.id,
        binding,
        proof
      )
    end
  end

  @impl Jido.AI.ToolInterceptor
  def tool_execution_stopped(call, token, proof, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context) do
      Session.native_execution_stopped(context.coordinator, call.id, token, proof)
    end
  end
end
