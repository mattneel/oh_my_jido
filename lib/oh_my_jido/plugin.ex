defmodule OhMyJido.Plugin do
  @moduledoc """
  Adds coding tools to a Jido agent you already own.

  Use this instead of a managed session when your agent should keep its own
  model loop and lifecycle. Declare the plugin on `Jido.Agent` or `Jido.AI.Agent`:

      plugins: [
        {OhMyJido.Plugin,
         %{bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts}}
      ]

  Before starting the agent, export `def private_diagnostics?, do: true`.
  AI agents must also configure `tool_max_retries: 0`. The provider implements
  `OhMyJido.Plugin.ContextProvider` and looks up a trusted context using the
  native agent's identity, never signal data or model arguments.

  Plain agents receive `oh_my_jido.read`, `oh_my_jido.edit`, and corresponding
  routes for the selected bundles. These use native instructions with retries
  disabled. For explicit, process-free native commands use `cmd/3` rather than
  constructing a retryable instruction yourself. Native Direct strategy merges
  successful tool output into agent state in the usual Jido way.

  AI agents retain their own model, request transformer, domain tools, and native
  `ask`/`await`/steering/cancellation behavior. At the native query hook the plugin
  adds bound coding actions to the actual ReAct request tool registry. Request
  tool overrides may narrow that registry, not introduce new actions or authority.
  Private context is fetched again inside each coding action and is never placed
  in agent state, model context, worker payloads, or checkpoints.

  Let the native API generate request IDs. Explicit IDs must be unique; a reused
  ID is rejected without changing an existing request or emitting a failure for
  it. Native cast-based `ask` cannot create a distinct handle for a reused ID.

  This attachment starts no `OhMyJido.Runtime`, session, model, service,
  approval UI, durable effect journal, recovery worker, or subagent.
  Managed Goal/Memory/Subagent tools and Eval are unavailable here.
  Host approval without a managed session returns `:approval_required`.
  Cancellation cannot roll back an effect; reconcile uncertain effects in your
  application rather than replaying the request. See the Jido agents guide.
  """

  use Jido.Plugin,
    name: "oh_my_jido",
    state_key: :oh_my_jido_tools,
    description: "Host-bound lightweight coding tools for native Jido agents",
    actions: [],
    singleton: true

  alias Jido.{Agent, Instruction, Signal}
  alias Jido.Agent.Strategy.State, as: StrategyState
  alias Jido.AI.Reasoning.ReAct.{Strategy, ToolSelection}
  alias OhMyJido.{Context, Tools}
  alias OhMyJido.Plugin.Tools, as: BoundTools

  @config_keys [:bundles, :context_provider]
  @authority_keys [
    :oh_my_jido,
    :workspace,
    :permissions,
    :adapters,
    :host,
    :context_provider,
    :coordinator,
    :runtime,
    :account,
    :model,
    :tools,
    :bundles,
    :agent,
    :agent_module,
    :agent_id,
    :state
  ]
  @private_context_keys [
    :oh_my_jido,
    :workspace,
    :permissions,
    :adapters,
    :host,
    :context_provider
  ]
  @exec_opts [max_retries: 0, telemetry: :silent, log_level: :error]

  defoverridable plugin_spec: 1

  @impl Jido.Plugin
  def plugin_spec(config) do
    case selection(config) do
      {:ok, actions} -> %{super(config) | actions: actions}
      {:error, reason} -> raise ArgumentError, "Invalid OhMyJido.Plugin setup: #{inspect(reason)}"
    end
  end

  def actions, do: selected_actions!(%{})

  @impl Jido.Plugin
  def mount(%Agent{} = agent, config) do
    case mount_requirements(agent, config) do
      :ok -> {:ok, %{}}
      {:error, reason} -> raise ArgumentError, "Invalid OhMyJido.Plugin setup: #{inspect(reason)}"
    end
  end

  defp mount_requirements(agent, config) do
    with {:ok, _actions} <- selection(config),
         :ok <- require_provider(config),
         :ok <- require_private_diagnostics(agent.agent_module) do
      validate_agent_options(agent.agent_module)
    end
  end

  @impl Jido.Plugin
  def signal_routes(config) do
    Enum.map(selected_actions!(config), &{"oh_my_jido." <> &1.name(), &1})
  end

  @impl Jido.Plugin
  def handle_signal(%Signal{type: "oh_my_jido." <> name, data: params}, %{config: config}) do
    with {:ok, actions} <- selection(config),
         {:ok, action} <- find_action(actions, name),
         :ok <- validate_arguments(params) do
      {:ok,
       {:override, %Instruction{action: action, params: params, context: %{}, opts: @exec_opts}}}
    end
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  @impl Jido.Plugin
  def prepare_signal(%Signal{type: "ai.react.query", data: data} = signal, context) do
    with true <- native_ai?(context.agent_module),
         true <- is_map(data),
         :ok <- unique_request(data, context.agent),
         :ok <- reject_keys(data, @authority_keys -- [:tools]),
         {:ok, actions} <- selection(context.config),
         config <- native_config(context.agent),
         :ok <- validate_ai_config(config),
         :ok <- validate_tool_context(value(data, :tool_context, %{})),
         :ok <- validate_transformer(data, config),
         {:ok, available} <- available_tools(config, actions),
         {:ok, tools} <- request_tools(data, available) do
      prepared_data = data |> Map.delete("tools") |> Map.put(:tools, tools)
      {:ok, %{signal | data: prepared_data}, %{}}
    else
      false -> reject_query(signal, :native_react_query_required, context.agent)
      {:error, reason} -> reject_query(signal, reason, context.agent)
    end
  end

  def prepare_signal(%Signal{type: "ai.react.set_tool_context", data: data} = signal, _context) do
    with :ok <- validate_tool_context(value(data, :tool_context, %{})) do
      {:ok, signal, %{}}
    end
  end

  def prepare_signal(%Signal{type: "ai.react.register_tool", data: data} = signal, context) do
    module = value(data, :tool_module)
    configured = context.agent_module.strategy_opts() |> Keyword.get(:tools, [])

    if module in configured and module not in Tools.default() and not BoundTools.bound?(module) do
      {:ok, signal, %{}}
    else
      error(:untrusted_tool_selection)
    end
  end

  def prepare_signal(signal, _context), do: {:ok, signal, %{}}

  @impl Jido.Plugin
  def prepare_action(signal, action_arg, context) do
    with {:ok, selected} <- selection(context.config),
         :ok <- validate_routed_actions(List.wrap(action_arg), selected, signal) do
      {:ok, %{}}
    end
  end

  @doc """
  Executes one selected tool through the original agent's native `cmd/3`.

  Accepts an original coding action, a bound action, or its exact tool name.
  Execution uses native Direct/ReAct action handling and zero effect retries.
  No agent, runtime, supervisor, model, or authority binding is created here.
  """
  @spec cmd(Agent.t(), module() | String.t(), map()) :: Agent.cmd_result() | {:error, term()}
  def cmd(%Agent{agent_module: module} = agent, tool, params) when is_atom(module) do
    with {:ok, config} <- agent_config(module),
         {:ok, actions} <- selection(config),
         {:ok, action} <- selected_action(actions, tool),
         :ok <- validate_arguments(params),
         :ok <- require_private_diagnostics(module),
         :ok <- validate_agent_options(module) do
      module.cmd(agent, %Instruction{
        action: action,
        params: params,
        context: %{},
        opts: @exec_opts
      })
    end
  end

  @doc false
  @spec validate_arguments(term()) :: :ok | {:error, term()}
  def validate_arguments(params), do: reject_keys(params, @authority_keys)

  @doc false
  @spec execute(module(), map(), map()) :: term()
  def execute(action, params, execution_context) do
    with :ok <- validate_arguments(params),
         :ok <- reject_keys(execution_context, @private_context_keys),
         :ok <- validate_tool_context(Map.get(execution_context, :tool_context, %{})),
         {:ok, identity} <- execution_identity(execution_context),
         {:ok, config} <- agent_config(identity.agent_module),
         :ok <- require_private_diagnostics(identity.agent_module),
         :ok <- validate_agent_options(identity.agent_module),
         {:ok, selected} <- selection(config),
         {:ok, bound} <- BoundTools.wrap(action),
         true <- bound in selected,
         {:ok, context} <- fetch_context(config, identity),
         :ok <- context_allows_tool(context, action) do
      action.run(params, %{oh_my_jido: context})
    else
      false -> error(:tool_not_available)
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, %{reason: :coding_tool_failed, effect: :uncertain, retryable?: false}}
  catch
    _kind, _reason ->
      {:error, %{reason: :coding_tool_failed, effect: :uncertain, retryable?: false}}
  end

  defp selection(config) when is_map(config) do
    with true <- Enum.all?(Map.keys(config), &(&1 in @config_keys)),
         {:ok, actions} <- Tools.select(Map.get(config, :bundles, [:read_only])) do
      Enum.reduce_while(actions, {:ok, []}, &select_bound_action/2)
      |> case do
        {:ok, selected} -> {:ok, Enum.reverse(selected)}
        {:error, _reason} = error -> error
      end
    else
      false -> error(:unknown_plugin_option)
      {:error, reason} -> error({:invalid_bundles, reason})
    end
  end

  defp selection(_config), do: error(:expected_plugin_config_map)

  defp select_bound_action(action, {:ok, selected}) do
    case BoundTools.wrap(action) do
      {:ok, bound} -> {:cont, {:ok, [bound | selected]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp selected_actions!(config) do
    case selection(config) do
      {:ok, actions} -> actions
      {:error, reason} -> raise ArgumentError, "Invalid OhMyJido.Plugin setup: #{inspect(reason)}"
    end
  end

  defp require_provider(%{context_provider: module})
       when is_atom(module) and module not in [nil, true, false],
       do: :ok

  defp require_provider(_config), do: error(:context_provider_required)

  defp require_private_diagnostics(module) do
    if function_exported?(module, :private_diagnostics?, 0) and
         module.private_diagnostics?() == true do
      require_native_private_diagnostics()
    else
      error(:private_diagnostics_required)
    end
  end

  defp require_native_private_diagnostics do
    if Code.ensure_loaded?(Jido.AgentServer) and
         function_exported?(Jido.AgentServer, :private_diagnostics_version, 0) and
         Jido.AgentServer.private_diagnostics_version() == 1 do
      :ok
    else
      error(:patched_jido_private_diagnostics_required)
    end
  end

  defp validate_agent_options(module) do
    if native_ai?(module) do
      opts = module.strategy_opts()

      with true <- Keyword.get(opts, :tool_max_retries, 1) == 0,
           :ok <- validate_tool_context(Keyword.get(opts, :tool_context, %{})) do
        :ok
      else
        false -> error(:tool_max_retries_must_be_zero)
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp native_ai?(module), do: module.strategy() == Strategy

  defp native_config(agent), do: agent |> StrategyState.get(%{}) |> Map.get(:config, %{})

  defp validate_ai_config(config) do
    with true <- config[:tool_max_retries] == 0,
         :ok <- validate_tool_context(config[:base_tool_context] || %{}) do
      :ok
    else
      false -> error(:tool_max_retries_must_be_zero)
      {:error, _reason} = error -> error
    end
  end

  defp available_tools(config, selected) do
    with {:ok, domain_tools} <- ToolSelection.normalize_input(config[:tools] || []) do
      coding_tools = Map.new(selected, &{&1.name(), &1})

      unsafe? =
        Enum.any?(domain_tools, fn {name, action} ->
          action in Tools.default() or
            (BoundTools.bound?(action) and action not in selected) or
            (Map.has_key?(coding_tools, name) and coding_tools[name] != action)
        end)

      if unsafe?,
        do: error(:unbound_or_conflicting_coding_tool),
        else: {:ok, Map.merge(domain_tools, coding_tools)}
    end
  end

  defp request_tools(data, available) do
    requested = value(data, :tools)

    if trusted_selection?(requested, available) do
      ToolSelection.resolve(available, requested, value(data, :allowed_tools))
    else
      error(:untrusted_tool_selection)
    end
  end

  defp trusted_selection?(nil, _available), do: true

  defp trusted_selection?(requested, available) when is_map(requested) do
    Enum.all?(requested, fn {name, action} ->
      is_binary(name) and Map.get(available, name) == action
    end)
  end

  defp trusted_selection?(requested, available) when is_list(requested) do
    modules = Map.values(available)
    Enum.all?(requested, &(&1 in modules))
  end

  defp trusted_selection?(requested, available) when is_atom(requested),
    do: requested in Map.values(available)

  defp trusted_selection?(_requested, _available), do: false

  defp validate_transformer(data, config) do
    requested = value(data, :request_transformer)

    present? =
      Map.has_key?(data, :request_transformer) or Map.has_key?(data, "request_transformer")

    if not present? or requested == config[:request_transformer] do
      :ok
    else
      error(:untrusted_request_transformer)
    end
  end

  defp validate_tool_context(nil), do: :ok
  defp validate_tool_context(context), do: reject_keys(context, @authority_keys)

  defp reject_keys(data, keys) when is_map(data) do
    if Enum.any?(keys, &(Map.has_key?(data, &1) or Map.has_key?(data, Atom.to_string(&1)))) do
      error(:untrusted_authority)
    else
      :ok
    end
  end

  defp reject_keys(_data, _keys), do: error(:expected_context_or_arguments_map)

  defp validate_routed_actions([], _selected, _signal), do: :ok

  defp validate_routed_actions([instruction | rest], selected, signal) do
    {action, opts} = routed_action(instruction)

    result =
      cond do
        action == :ai_react_start and signal.type != "ai.react.query" ->
          error(:native_react_query_required)

        action in Tools.default() ->
          error(:unbound_coding_action)

        BoundTools.bound?(action) and action not in selected ->
          error(:tool_not_available)

        BoundTools.bound?(action) and Keyword.get(opts, :max_retries) != 0 ->
          error(:use_plugin_route_or_cmd_for_zero_retries)

        true ->
          :ok
      end

    with :ok <- result, do: validate_routed_actions(rest, selected, signal)
  end

  defp routed_action(%Instruction{action: action, opts: opts}), do: {action, opts}
  defp routed_action({action, _params}), do: {action, []}
  defp routed_action({action, _params, _context}), do: {action, []}
  defp routed_action({action, _params, _context, opts}), do: {action, opts}
  defp routed_action(action), do: {action, []}

  defp execution_identity(%{agent: %Agent{agent_module: module, id: id}}),
    do: identity(module, id)

  defp execution_identity(%{agent_module: module, agent_id: id}), do: identity(module, id)
  defp execution_identity(_context), do: error(:native_agent_context_required)

  defp identity(module, id) when is_atom(module) and is_binary(id) and byte_size(id) > 0 do
    {:ok, %{agent_module: module, agent_id: id}}
  end

  defp identity(_module, _id), do: error(:native_agent_context_required)

  defp agent_config(module) do
    if function_exported?(module, :plugin_config, 1) do
      case module.plugin_config(__MODULE__) do
        config when is_map(config) -> {:ok, config}
        _missing -> error(:plugin_not_attached)
      end
    else
      error(:plugin_not_attached)
    end
  end

  defp fetch_context(config, identity) do
    with :ok <- require_provider(config),
         provider = config.context_provider,
         true <- Code.ensure_loaded?(provider) and function_exported?(provider, :fetch_context, 1) do
      case provider.fetch_context(identity) do
        {:ok, %Context{} = context} -> validate_host_context(context)
        {:error, _reason} -> error(:context_not_bound)
        _invalid -> error(:invalid_host_context)
      end
    else
      false -> error(:context_provider_callback_required)
      {:error, _reason} = error -> error
    end
  rescue
    _error -> error(:context_provider_failed)
  catch
    _kind, _reason -> error(:context_provider_failed)
  end

  defp validate_host_context(%Context{runtime: nil, coordinator: nil} = context) do
    case Context.new(Map.to_list(Map.from_struct(context))) do
      {:ok, validated} -> {:ok, validated}
      {:error, {:invalid_context, field, _reason}} -> error({:invalid_host_context, field})
    end
  end

  defp validate_host_context(_context), do: error(:managed_context_requires_runtime)

  defp context_allows_tool(context, action) do
    if Enum.any?(context.tools, &(&1 == action or BoundTools.original(&1) == action)) do
      :ok
    else
      error(:tool_not_available_in_host_context)
    end
  end

  defp selected_action(actions, name) when is_binary(name), do: find_action(actions, name)

  defp selected_action(actions, tool) do
    with {:ok, action} <- BoundTools.wrap(tool),
         true <- action in actions do
      {:ok, action}
    else
      false -> error(:tool_not_available)
      {:error, _reason} = error -> error
    end
  end

  defp find_action(actions, name) do
    case Enum.find(actions, &(&1.name() == name)) do
      nil -> error(:tool_not_available)
      action -> {:ok, action}
    end
  end

  defp reject_query(%Signal{data: data} = signal, reason, agent) do
    with :ok <- unique_request(data, agent),
         id when is_binary(id) and byte_size(id) > 0 <- value(data, :request_id) do
      message = "OhMyJido.Plugin rejected request: " <> rejection_code(reason)
      rejection = {:rejected, :coding_tool_policy, message}

      # Keep native start_request/4, retention, stream ownership and terminal
      # delivery. The native transformer rejects before any provider/tool call;
      # synthesizing ai.request.error would skip native bounded insertion.
      rejected_signal = %{
        signal
        | data: %{
            request_id: id,
            query: "OhMyJido.Plugin policy rejection",
            tools: [],
            request_transformer: OhMyJido.Plugin.RejectRequest,
            tool_context: %{oh_my_jido_rejection: rejection},
            stream_to: value(data, :stream_to)
          }
      }

      {:ok, rejected_signal, %{}}
    else
      {:error, _reason} = error -> error
      _missing -> error(:invalid_request_id)
    end
  end

  defp unique_request(data, agent) do
    case value(data, :request_id) do
      nil ->
        :ok

      id when is_binary(id) and byte_size(id) > 0 ->
        if Map.has_key?(Map.get(agent.state, :requests, %{}), id),
          do: error(:request_id_conflict),
          else: :ok

      _invalid ->
        error(:invalid_request_id)
    end
  end

  defp rejection_code({:oh_my_jido_plugin, reason}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp rejection_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp rejection_code(_reason), do: "invalid_tool_selection"

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default

  defp error(reason), do: {:error, {:oh_my_jido_plugin, reason}}
end
