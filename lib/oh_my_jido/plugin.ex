defmodule OhMyJido.Plugin do
  @moduledoc """
  Host-bound coding tools for the caller's native Jido V3 Agent.

  Attach this Plugin in the native `agent do` block and declare each input route
  explicitly in `routes do`, for example:

      plugin OhMyJido.Plugin,
        config: %{bundles: [:read_only], context_provider: MyApp.CodingContexts}

      # In routes do:
      route "oh_my_jido.read", OhMyJido.Plugin.Tools.Read

  The Agent must export `private_diagnostics?/0` returning `true`. The
  `OhMyJido.Plugin.ContextProvider` receives only the native Agent module and ID.
  Private bindings are resolved at the tool effect boundary, never from Signal
  data, model arguments, Agent state, or a checkpoint.

  `cmd/3` sends a native Signal through the original Agent. A direct coding
  command stores its public result in `agent.state.oh_my_jido_tools`; the Plugin
  reducer owns that field and preserves every domain field. Errors use the
  native `{:error, reason}` result. Coding effects are never retried.

  AI Agents can add `OhMyJido.Plugin.AgentExtension` to their native
  `extensions:` list. This authoring extension adds the selected bound Actions
  to each static AI profile without replacing domain tools or model policy.
  For programmatic profiles, `tool_catalog/1` returns the same validated native
  catalog. Coding entries use zero retries, `:unsafe_once`, and an identity-only
  context projection. Request selections may narrow this catalog, never broaden
  its targets or execution policy. The caller's own native model, transport,
  request transformer, interceptors, coordinator, and request lifecycle remain
  the sole owners of AI execution.

  Native admission rejects invalid requests before a model starts. In V3,
  `ask/3` and `ask_stream/3` therefore return an error for a rejected admission;
  no synthetic request handle, rejected model turn, or second loop is created.
  Reused request IDs are rejected without terminating the original stream.

  This attachment starts no OhMyJido Runtime, session, model, service, recovery
  worker, or subagent. Managed Goal/Memory/Subagent tools and Eval are unavailable.
  Host approval without a managed session returns `:approval_required`.
  Cancellation cannot roll back an effect; uncertain effects require host
  reconciliation rather than replay.
  """

  use Jido.Plugin

  alias Jido.Agent
  alias Jido.Agent.Plugin.Preparation
  alias Jido.AgentServer.Plugin.Admission
  alias Jido.AI.{Configuration, ToolCatalog}
  alias Jido.AI.Reasoning.ReAct.ToolSelection
  alias Jido.Plugin.Input
  alias Jido.Signal
  alias OhMyJido.{Context, Tools}
  alias OhMyJido.Plugin.Result
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
    :agent_state,
    :agent_topology,
    :plugin_inputs,
    :jido_ai_tool_identity,
    :state
  ]
  @credential_keys [
    :api_key,
    :access_token,
    :refresh_token,
    :credentials,
    :authorization,
    :auth,
    :password,
    :secret
  ]
  @transport_keys [:req_http_options, :base_url, :url, :headers, :proxy, :connect_options]
  @retry_keys [
    :max_retries,
    :tool_max_retries,
    :max_attempts,
    :retry_backoff,
    :retry_backoff_ms,
    :retry,
    :retryable?,
    :attempt,
    :attempts,
    :idempotency
  ]
  @identity_context [:plugin_inputs, :agent_id, :agent_module, :jido_ai_tool_identity]
  @private_context_keys [
    :oh_my_jido,
    :workspace,
    :permissions,
    :adapters,
    :host,
    :context_provider
  ]
  @request_data_keys [:query, :prompt, :request_id, :extra_refs]

  @doc false
  def normalize(config) do
    with {:ok, _actions} <- selection(config),
         :ok <- require_provider(config),
         :ok <- Jido.Action.validate_static_data(config),
         do: {:ok, config}
  end

  @impl Jido.Plugin
  def validate_options(opts) do
    with {:ok, _config} <- normalize(Map.new(opts)), do: :ok
  end

  @impl Jido.Plugin
  def state_spec(_opts), do: {:oh_my_jido_tools, Zoi.map() |> Zoi.default(%{})}

  @impl Jido.Plugin
  def directives(_opts), do: [Result]

  @impl Jido.Plugin
  def prepare(%Preparation{} = preparation, opts) do
    config = Map.new(opts)

    with {:ok, selected} <- selection(config),
         :ok <- require_provider(config),
         :ok <- require_private_diagnostics(preparation.agent_module),
         {:ok, identity} <- identity(preparation.agent_module, preparation.agent_id),
         {:ok, request} <- prepare_request(preparation, selected),
         :ok <- validate_coding_signal(preparation.signal, selected) do
      {:ok, %{identity: identity, request: request}}
    end
  end

  @impl Jido.Plugin
  def admit(_runtime, %Admission{} = admission, _opts) do
    with :ok <-
           reject_keys(
             admission.caller_context,
             @private_context_keys ++ [:agent, :agent_module, :jido_ai_tool_identity]
           ),
         :ok <- validate_tool_context(Map.get(admission.caller_context, :tool_context, %{})),
         :ok <- validate_native_route(admission),
         :ok <- validate_admitted_request(admission.prepared_input, admission.caller_context) do
      {:ok, nil}
    end
  end

  @impl Jido.Plugin
  def reduce(reduction, _opts) do
    result =
      Enum.reduce(reduction.directives, reduction.plugin_state, fn
        %Result{value: value}, _previous -> value
        _directive, previous -> previous
      end)

    {:ok, result}
  end

  @doc """
  Returns the selected bound Actions as a validated native AI tool catalog.

  Use the entries as a profile's static `:tools` value, alongside the caller's
  own domain entries. This does not construct an Agent or start runtime work.
  """
  @spec tool_catalog(map()) :: {:ok, [map()]} | {:error, term()}
  def tool_catalog(config \\ %{}) do
    with {:ok, actions} <- selection(config) do
      actions
      |> Enum.map(fn action ->
        %{
          name: action.name(),
          description: action.description(),
          target: action,
          forward_context: @identity_context,
          max_retries: 0,
          retry_backoff: 0,
          idempotency: :unsafe_once
        }
      end)
      |> ToolCatalog.new()
    end
  end

  @doc false
  def bind_profile(%Jido.AI.Profile{} = profile, config) do
    with {:ok, selected} <- selection(config),
         {:ok, catalog} <- tool_catalog(config),
         additions =
           Enum.reject(catalog, fn addition ->
             Enum.any?(
               profile.tools,
               &(&1.name == addition.name and &1.target == addition.target)
             )
           end),
         {:ok, tools} <- ToolCatalog.new(profile.tools ++ additions),
         {:ok, profile} <- Jido.AI.Profile.new(%{profile | tools: tools}),
         :ok <- validate_profile(profile, selected) do
      {:ok, profile}
    end
  end

  @doc """
  Executes one selected coding tool through the original Agent's native Signal route.

  Accepts an original coding Action, a bound Action, or its exact tool name.
  The Agent must explicitly route `oh_my_jido.<name>` to that bound Action.
  No Agent, authority binding, runtime, or model is created here.
  """
  @spec cmd(Agent.instance(), module() | String.t(), map()) ::
          {:ok, Agent.instance(), [struct()]} | {:error, term()}
  def cmd(%Agent{module: module} = agent, tool, params) when is_atom(module) do
    with {:ok, config} <- agent_config(agent),
         {:ok, actions} <- selection(config),
         {:ok, action} <- selected_action(actions, tool),
         :ok <- validate_arguments(params),
         {:ok, signal} <-
           Signal.new("oh_my_jido." <> action.name(), params, source: "/oh_my_jido/plugin"),
         {:ok, router} <- Signal.Router.new(agent.routes),
         {:ok, [target | _rest]} <- Signal.Router.route(router, signal),
         {^action, _defaults} <- Agent.Authoring.split_target(target) do
      Agent.cmd(agent, signal)
    else
      {:error, _reason} = error -> error
      _other_route -> error(:explicit_coding_route_required)
    end
  end

  @doc false
  @spec validate_arguments(term()) :: :ok | {:error, term()}
  def validate_arguments(params) do
    with :ok <- reject_keys(params, @authority_keys),
         :ok <- reject_nested_keys(params, @credential_keys, :untrusted_credentials),
         do: reject_nested_keys(params, @retry_keys, :unsafe_retry_metadata)
  end

  @doc false
  @spec execute(module(), map(), map()) :: term()
  def execute(action, params, execution_context) do
    with :ok <- validate_arguments(params),
         :ok <- reject_keys(execution_context, @private_context_keys),
         :ok <- validate_tool_context(Map.get(execution_context, :tool_context, %{})),
         {:ok, identity} <- execution_identity(execution_context),
         {:ok, config} <- agent_config(identity.agent_module.definition()),
         :ok <- require_private_diagnostics(identity.agent_module),
         {:ok, selected} <- selection(config),
         {:ok, bound} <- BoundTools.wrap(action),
         true <- bound in selected,
         {:ok, context} <- fetch_context(config, identity),
         :ok <- context_allows_tool(context, action) do
      action.run(params, %{oh_my_jido: context})
      |> validate_tool_result(action)
      |> native_result(execution_context)
    else
      false -> error(:tool_not_available)
      {:error, _reason} = error -> error
    end
  rescue
    _error -> uncertain_failure()
  catch
    _kind, _reason -> uncertain_failure()
  end

  defp validate_tool_result({:ok, value}, action), do: action.validate_output(value)

  defp validate_tool_result({:ok, value, effects}, action) do
    with {:ok, value} <- action.validate_output(value), do: {:ok, value, effects}
  end

  defp validate_tool_result(result, _action), do: result

  defp native_result({:ok, value}, %{agent_state: state}),
    do: {:ok, state, [%Result{value: value}]}

  defp native_result({:ok, value, effects}, %{agent_state: state}),
    do: {:ok, state, [%Result{value: value} | effects]}

  defp native_result({:error, reason}, _context), do: {:error, without_retry(reason)}

  defp native_result({:error, reason, effects}, _context),
    do: {:error, without_retry(reason), effects}

  defp native_result(result, _context), do: result

  defp without_retry(%Jido.Action.Error.ExecutionFailureError{} = reason),
    do: %{reason | details: Map.put(reason.details, :retry, false)}

  defp without_retry(%Jido.Action.Error.TimeoutError{} = reason),
    do: %{reason | details: Map.put(reason.details, :retry, false)}

  defp without_retry(%{reason: reason} = envelope) when not is_struct(envelope) do
    Jido.Action.Error.execution_error("Coding tool operation rejected", %{
      reason: reason,
      retry: false
    })
    |> Jido.AgentServer.PrivateDiagnostics.error()
  end

  defp without_retry(reason), do: reason

  defp uncertain_failure do
    {:error,
     Jido.Action.Error.execution_error("Coding tool effect requires host reconciliation", %{
       reason: {:coding_tool_failed, :effect_uncertain},
       retry: false
     })}
  end

  defp selection(config) when is_map(config) and not is_struct(config) do
    with true <- Enum.all?(Map.keys(config), &(&1 in @config_keys)),
         {:ok, actions} <- Tools.select(Map.get(config, :bundles, [:read_only])) do
      Agent.Authoring.traverse(actions, &BoundTools.wrap/1)
    else
      false -> error(:unknown_plugin_option)
      {:error, reason} -> error({:invalid_bundles, reason})
    end
  end

  defp selection(_config), do: error(:expected_plugin_config_map)

  defp require_provider(%{context_provider: module})
       when is_atom(module) and module not in [nil, true, false],
       do: :ok

  defp require_provider(_config), do: error(:context_provider_required)

  defp require_private_diagnostics(module) do
    cond do
      not (is_atom(module) and Code.ensure_loaded?(module) and
             function_exported?(module, :private_diagnostics?, 0) and
               module.private_diagnostics?() == true) ->
        error(:private_diagnostics_required)

      not (Code.ensure_loaded?(Jido.AgentServer) and
             function_exported?(Jido.AgentServer, :private_diagnostics_version, 0) and
               Jido.AgentServer.private_diagnostics_version() == 1) ->
        error(:native_private_diagnostics_required)

      true ->
        :ok
    end
  end

  defp prepare_request(preparation, selected) do
    definition = preparation.agent_module.definition()
    current = %{definition | id: preparation.agent_id, state: preparation.agent_state}

    case Jido.AI.Orchestration.Binding.request(current, preparation.signal) do
      %{id: id} ->
        with :ok <- unique_request(preparation.signal.data, preparation.agent_state),
             :ok <- validate_request_data(preparation.signal.data),
             {:ok, profile} <- Configuration.profile(current, id),
             :ok <- validate_profile(profile, selected) do
          {:ok,
           %{
             profile_id: id,
             tools: profile.tools,
             request_transformer: profile.reasoning[:request_transformer]
           }}
        end

      nil ->
        with :ok <- validate_configuration_signal(preparation.signal, current, selected),
             do: {:ok, nil}
    end
  end

  defp validate_coding_signal(%Signal{type: "oh_my_jido." <> name, data: params}, selected) do
    with {:ok, _action} <- find_action(selected, name), do: validate_arguments(params)
  end

  defp validate_coding_signal(_signal, _selected), do: :ok

  defp validate_request_data(data) do
    with true <- Enum.all?(Map.keys(data), &known_key?(&1, @request_data_keys)),
         :ok <- reject_nested_keys(data, @credential_keys, :untrusted_credentials),
         :ok <- reject_nested_keys(data, @retry_keys, :unsafe_retry_metadata) do
      :ok
    else
      false -> error(:untrusted_authority)
      {:error, _reason} = error -> error
    end
  end

  defp validate_configuration_signal(
         %Signal{type: "jido.ai.configure", data: data},
         agent,
         selected
       ) do
    with {:ok, profile} <- Configuration.profile(agent, value(data, :profile_id)) do
      case {value(data, :operation), value(data, :value)} do
        {:tool_context, context} -> validate_tool_context(context)
        {:tools, tools} -> validate_catalog_subset(tools, profile.tools, selected)
        {:register, tool} -> validate_tool_subset([tool], profile.tools)
        _other -> :ok
      end
    end
  end

  defp validate_configuration_signal(_signal, _agent, _selected), do: :ok

  defp validate_native_route(admission) do
    binding = Jido.AI.Configuration.Plugin.native_binding(admission)

    case {binding, admission.prepared_input} do
      {nil, %{request: nil}} -> :ok
      {%{id: id}, %{request: %{profile_id: id}}} -> :ok
      _mismatch -> error(:declared_native_ai_route_required)
    end
  end

  defp validate_admitted_request(%{request: nil}, _context), do: :ok

  defp validate_admitted_request(%{request: request}, context) do
    resources = Map.get(context, :jido_ai_request, %{})

    with :ok <- reject_keys(resources, @authority_keys -- [:tools]),
         :ok <- validate_tool_context(value(resources, :tool_context, %{})),
         :ok <- validate_transformer(resources, request.request_transformer),
         :ok <- validate_request_credentials(resources),
         :ok <- reject_nested_keys(resources, @retry_keys, :unsafe_retry_metadata),
         :ok <- validate_tool_subset(value(resources, :tools), request.tools),
         {:ok, _tools} <-
           ToolSelection.filter_allowed(
             Map.new(request.tools, &{&1.name, &1}),
             value(resources, :allowed_tools)
           ) do
      :ok
    end
  end

  defp validate_admitted_request(_input, _context), do: error(:native_agent_context_required)

  defp validate_request_credentials(resources) do
    with :ok <- reject_nested_keys(resources, @credential_keys, :untrusted_credentials),
         do: reject_nested_keys(resources, @transport_keys, :untrusted_transport)
  end

  defp validate_profile(profile, selected) do
    with :ok <- validate_tool_context(profile.tool_context),
         do: validate_catalog(profile.tools, selected)
  end

  defp validate_catalog(catalog, selected) do
    Enum.reduce_while(catalog, :ok, fn tool, :ok ->
      case validate_entry(tool, selected) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_entry(%{target: action} = tool, selected) do
    cond do
      action in Tools.default() ->
        error(:unbound_or_conflicting_coding_tool)

      BoundTools.bound?(action) ->
        validate_bound_entry(tool, selected)

      Enum.any?(selected, &(&1.name() == tool.name)) ->
        error(:unbound_or_conflicting_coding_tool)

      true ->
        :ok
    end
  end

  defp validate_bound_entry(%{target: action} = tool, selected) do
    policy = %{
      max_retries: Map.get(tool, :max_retries, 0),
      retry_backoff: Map.get(tool, :retry_backoff, 0),
      idempotency: tool.idempotency
    }

    cond do
      action not in selected ->
        error(:tool_not_available)

      tool.name != action.name() or tool.forward_context != @identity_context ->
        error(:native_identity_projection_required)

      policy != %{max_retries: 0, retry_backoff: 0, idempotency: :unsafe_once} ->
        error(:unsafe_retry_metadata)

      true ->
        metadata = Map.get(tool, :metadata, %{})

        with :ok <- reject_nested_keys(metadata, @credential_keys, :untrusted_credentials),
             do: reject_nested_keys(metadata, @retry_keys, :unsafe_retry_metadata)
    end
  end

  defp validate_catalog_subset(tools, available, selected) do
    with {:ok, catalog} <- ToolCatalog.new(tools),
         :ok <- validate_catalog(catalog, selected),
         true <- Enum.all?(catalog, &(&1 in available)) do
      :ok
    else
      false -> error(:untrusted_tool_selection)
      {:error, _reason} = error -> error
    end
  end

  defp validate_tool_subset(nil, _available), do: :ok

  defp validate_tool_subset(requested, available) do
    with {:ok, requested} <- ToolSelection.normalize_input(requested),
         index = Map.new(available, &{&1.name, &1.target}),
         true <- Enum.all?(requested, fn {name, action} -> Map.get(index, name) == action end) do
      :ok
    else
      _invalid -> error(:untrusted_tool_selection)
    end
  end

  defp validate_transformer(data, configured) do
    if (Map.has_key?(data, :request_transformer) or Map.has_key?(data, "request_transformer")) and
         value(data, :request_transformer) != configured,
       do: error(:untrusted_request_transformer),
       else: :ok
  end

  defp validate_tool_context(context) do
    with :ok <- reject_keys(context, @authority_keys),
         :ok <- reject_nested_keys(context, @credential_keys, :untrusted_credentials),
         do: reject_nested_keys(context, @retry_keys, :unsafe_retry_metadata)
  end

  defp reject_keys(data, keys, reason \\ :untrusted_authority)

  defp reject_keys(data, keys, reason) when is_map(data) and not is_struct(data) do
    if Enum.any?(Map.keys(data), &known_key?(&1, keys)), do: error(reason), else: :ok
  end

  defp reject_keys(_data, _keys, _reason), do: error(:expected_context_or_arguments_map)

  defp reject_nested_keys(data, keys, reason) when is_map(data) do
    if Enum.any?(Map.keys(data), &known_key?(&1, keys)) do
      error(reason)
    else
      reject_nested_keys(Map.values(data), keys, reason)
    end
  end

  defp reject_nested_keys(data, keys, reason) when is_list(data) do
    Enum.reduce_while(data, :ok, fn value, :ok ->
      case reject_nested_keys(value, keys, reason) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_nested_keys({key, value}, keys, reason) do
    if known_key?(key, keys), do: error(reason), else: reject_nested_keys(value, keys, reason)
  end

  defp reject_nested_keys(_data, _keys, _reason), do: :ok

  defp known_key?(key, keys), do: Enum.any?(keys, &(key == &1 or key == Atom.to_string(&1)))

  defp execution_identity(%{plugin_inputs: inputs, agent_id: id} = context) do
    case inputs[__MODULE__] do
      %Input{prepared: %{identity: %{agent_id: ^id, agent_module: module} = identity}} ->
        if Map.get(context, :agent_module, module) == module,
          do: {:ok, identity},
          else: error(:native_agent_context_required)

      _missing ->
        error(:native_agent_context_required)
    end
  end

  defp execution_identity(%{
         jido_ai_tool_identity: %Jido.AI.Execution.ToolIdentity{
           agent_id: id,
           agent_module: module
         },
         agent_id: id,
         agent_module: module
       }),
       do: identity(module, id)

  defp execution_identity(_context), do: error(:native_agent_context_required)

  defp identity(module, id)
       when is_atom(module) and module not in [nil, true, false] and is_binary(id) and
              byte_size(id) > 0,
       do: {:ok, %{agent_module: module, agent_id: id}}

  defp identity(_module, _id), do: error(:native_agent_context_required)

  defp agent_config(%Agent{} = agent) do
    case Enum.find(agent.plugins, &(elem(&1, 0) == __MODULE__)) do
      {__MODULE__, opts} -> {:ok, Map.new(opts)}
      nil -> error(:plugin_not_attached)
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
    if Enum.any?(context.tools, &(&1 == action or BoundTools.original(&1) == action)),
      do: :ok,
      else: error(:tool_not_available_in_host_context)
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

  defp unique_request(data, state) do
    case value(data, :request_id) do
      nil ->
        :ok

      id when is_binary(id) and byte_size(id) > 0 ->
        if Map.has_key?(Map.get(state, :requests, %{}), id),
          do: {:error, :duplicate_request},
          else: :ok

      _invalid ->
        error(:invalid_request_id)
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default

  defp error(reason), do: {:error, {:oh_my_jido_plugin, reason}}
end
