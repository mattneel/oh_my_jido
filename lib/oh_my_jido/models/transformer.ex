defmodule OhMyJido.Models.Transformer do
  @moduledoc """
  Per-turn host policy at the installed Jido ReAct request boundary.

  The native runner owns the model loop, transport, and regenerated tool
  definitions. This transformer returns an action registry, not independent
  function definitions, so model exposure and Jido execution remain consistent.
  Credentials are fetched freshly from the selected host account and registered
  for transient redaction before context projection or provider execution.
  Every credentialled provider turn explicitly forces ReqLLM telemetry payloads
  to `:none`, overriding raw request/host options and global telemetry defaults.
  Native debug logging must be disabled before credentials are obtained, and
  production stream failures use a model-bound safe error normalizer. Base
  configuration cannot import credentials; host inference options cannot carry
  refresh/identity tokens or lifecycle credential files.

  A valid explicit Jido test script bypasses credentials only when the trusted
  runtime configuration explicitly sets `:allow_test_scripts` to `true`.
  The default is false; task options, ambient scripts, and Mix environment do
  not authorize that bypass. Exhausted scripts retain the native failure path.
  """

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  alias Jido.AI.Reasoning.ReAct.Config
  alias Jido.AI.Test.ReActScript
  alias OhMyJido.{Context, ContextPolicy, Host, Models, Prompt, Redact, Session}
  alias OhMyJido.Models.Subscription

  @impl true
  def transform_request(
        %{messages: messages, llm_opts: opts, tools: requested},
        state,
        %Config{} = config,
        runtime_context
      )
      when is_list(messages) and is_list(opts) do
    with {:ok, context} <- Context.fetch(runtime_context),
         {:ok, model} <- Models.resolve(context.model),
         {:ok, metadata} <- Models.describe(model),
         :ok <- keyword_options(opts),
         :ok <- reject_request_credentials(opts),
         {:ok, scripted?} <- explicit_script(opts),
         :ok <- admit_script(context, scripted?),
         :ok <- safe_debug_configuration(scripted?),
         :ok <- supported_model_boundary(scripted?, metadata),
         {:ok, tools} <- Models.granted_tools(context, requested),
         tools = if(tools_enabled?(metadata), do: tools, else: %{}),
         {:ok, credentials} <- credentials(context, scripted?),
         :ok <- register_secrets(context, credentials, scripted?),
         {:ok, merged} <- merge_credentials(opts, credentials),
         merged = discard_generated_continuation(merged, state),
         merged = production_diagnostics(merged, scripted?),
         {:ok, model, merged} <- subscription_profile(model, merged, config, scripted?),
         {:ok, runtime_config, task} <- prompt_inputs(context, config, state),
         prompt_context = %{context | model: model, tools: Map.values(tools)},
         {:ok, prompt} <- Prompt.compose(prompt_context, task, runtime_config),
         {:ok, projected} <- project_context(context, compose_messages(messages, prompt)),
         :ok <- subscription_context(merged, projected, scripted?) do
      {:ok, %{model: model, tools: tools, llm_opts: merged, messages: projected}}
    end
  end

  def transform_request(_request, _state, _config, _runtime_context),
    do: {:error, :invalid_model_request}

  defp credentials(_context, true), do: {:ok, []}

  defp credentials(%Context{account: account, coordinator: coordinator} = context, false) do
    cond do
      not Models.account_reference?(account) ->
        {:error, :account_required}

      not is_pid(coordinator) ->
        {:error, :missing_secret_registry}

      true ->
        case Host.call(context, :credentials, [account]) do
          {:ok, opts} ->
            validate_credentials(opts)

          {:error, reason} when is_atom(reason) ->
            {:error, reason}

          {:error, %{__struct__: OhMyJido.Auth.Error} = reason} ->
            {:error, OhMyJido.Auth.Error.safe(reason)}

          _other ->
            {:error, :credential_service_failed}
        end
    end
  rescue
    _error -> {:error, :credential_service_failed}
  catch
    _kind, _reason -> {:error, :credential_service_failed}
  end

  defp validate_credentials(opts) when is_list(opts) do
    with :ok <- keyword_options(opts),
         :ok <- reject_lifecycle_options(opts),
         {:ok, provider} <- provider_options(Keyword.get(opts, :provider_options, [])) do
      mode = Keyword.get(opts, :auth_mode, Keyword.get(provider, :auth_mode, :api_key))
      key = Keyword.get(opts, :api_key)
      token = Keyword.get(opts, :access_token, Keyword.get(provider, :access_token))

      cond do
        mode == :oauth and nonempty?(token) and not nonempty?(key) ->
          opts = opts |> Keyword.put(:auth_mode, :oauth) |> Keyword.put(:access_token, token)
          {:ok, opts}

        mode == :api_key and nonempty?(key) and not nonempty?(token) ->
          {:ok, Keyword.put(opts, :auth_mode, :api_key)}

        true ->
          {:error, :explicit_credentials_required}
      end
    end
  end

  defp validate_credentials(_opts), do: {:error, :explicit_credentials_required}

  defp merge_credentials(base, []), do: {:ok, base}

  defp merge_credentials(base, fresh) do
    with {:ok, base_provider} <- provider_options(Keyword.get(base, :provider_options, [])),
         {:ok, fresh_provider} <- provider_options(Keyword.get(fresh, :provider_options, [])) do
      provider = Keyword.merge(base_provider, fresh_provider)

      provider =
        if fresh[:auth_mode] == :oauth,
          do:
            provider
            |> Keyword.put(:auth_mode, :oauth)
            |> Keyword.put(:access_token, fresh[:access_token]),
          else: provider

      merged = base |> Keyword.merge(fresh) |> Keyword.put(:provider_options, provider)
      {:ok, merged}
    end
  end

  # The harness supplies its complete, approved transcript on every turn.
  # Native ReAct adds the last response ID even for stateless chat providers.
  # Do not carry that derived server-side context across model/account choices.
  defp discard_generated_continuation(opts, %{llm_response_id: id}) when is_binary(id) do
    case provider_options(Keyword.get(opts, :provider_options, [])) do
      {:ok, provider} ->
        if Keyword.get(provider, :previous_response_id) == id,
          do:
            Keyword.put(opts, :provider_options, Keyword.delete(provider, :previous_response_id)),
          else: opts

      {:error, _reason} ->
        opts
    end
  end

  defp discard_generated_continuation(opts, _state), do: opts

  defp reject_request_credentials(opts) do
    if Models.credential_options?(opts), do: {:error, :credentials_must_come_from_host}, else: :ok
  end

  defp reject_lifecycle_options(opts) do
    if Models.lifecycle_options?(opts),
      do: {:error, :credential_lifecycle_options_not_allowed},
      else: :ok
  end

  defp safe_debug_configuration(true), do: :ok

  defp safe_debug_configuration(false) do
    if ReqLLM.Debug.enabled?() == false,
      do: :ok,
      else: {:error, :unsafe_model_debug_configuration}
  rescue
    _error -> {:error, :unsafe_model_debug_configuration}
  catch
    _kind, _reason -> {:error, :unsafe_model_debug_configuration}
  end

  defp supported_model_boundary(true, _model), do: :ok

  defp supported_model_boundary(false, model) do
    case Subscription.check_boundary() do
      :ok -> :ok
      {:error, reason} -> {:error, Subscription.normalize_stream_error(reason, model)}
    end
  end

  defp production_diagnostics(opts, true), do: opts

  defp production_diagnostics(opts, false) do
    opts
    |> Keyword.put(:telemetry, payloads: :none)
    |> Keyword.put(:stream_error_normalizer, &Subscription.normalize_stream_error/2)
  end

  defp subscription_profile(model, opts, _config, true), do: {:ok, model, opts}

  defp subscription_profile(model, opts, config, false) do
    if Subscription.subscription?(opts) do
      generated =
        [max_tokens: config.llm.max_tokens, temperature: config.llm.temperature] ++
          Keyword.take(opts, [:previous_response_id]) ++
          Keyword.take(Keyword.get(opts, :provider_options, []), [:previous_response_id])

      with :ok <- subscription_streaming(config),
           :ok <- Subscription.validate_options(config.llm.llm_opts),
           {:ok, {configured_model, configured_opts}} <-
             Subscription.configure(model, opts, generated_options: generated) do
        {:ok, configured_model, configured_opts}
      end
    else
      {:ok, model, opts}
    end
  end

  defp subscription_streaming(%Config{streaming: true}), do: :ok
  defp subscription_streaming(_config), do: {:error, :subscription_streaming_required}

  defp subscription_context(_opts, _messages, true), do: :ok

  defp subscription_context(opts, messages, false) do
    if Subscription.subscription?(opts), do: Subscription.validate_context(messages), else: :ok
  end

  defp register_secrets(_context, _credentials, true), do: :ok

  defp register_secrets(context, credentials, false) do
    case Session.register_secrets(context.coordinator, Redact.secrets(credentials)) do
      :ok -> :ok
      _failure -> {:error, :secret_registration_failed}
    end
  rescue
    _error -> {:error, :secret_registration_failed}
  catch
    _kind, _reason -> {:error, :secret_registration_failed}
  end

  defp project_context(%Context{coordinator: coordinator}, messages) when is_pid(coordinator) do
    case Session.compact_context(coordinator, messages) do
      {:ok, %{messages: projected}} when is_list(projected) -> {:ok, projected}
      {:error, _reason} = error -> error
      _other -> {:error, :context_projection_failed}
    end
  end

  defp project_context(%Context{metadata: metadata}, messages) do
    case get(metadata, :context_policy, nil) do
      %ContextPolicy{} = policy ->
        case ContextPolicy.compact(policy, messages) do
          {:ok, %{messages: projected}} -> {:ok, projected}
          {:error, _reason} = error -> error
        end

      _other ->
        {:ok, messages}
    end
  end

  defp prompt_inputs(context, config, state) do
    with {:ok, runtime} <- options_map(get(context.metadata, :runtime_config, %{})),
         {:ok, task} <- options_map(get(context.metadata, :task_metadata, %{})) do
      native_prompt =
        config.system_prompt ||
          get(get(get(state, :context, %{}), :metadata, %{}), :system_prompt, nil)

      runtime =
        runtime
        |> Map.put(
          :system_prompt,
          Enum.uniq(List.wrap(get(runtime, :system_prompt, nil)) ++ List.wrap(native_prompt))
        )
        |> Map.put(:skills, get(runtime, :skills, get(context.metadata, :skills, [])))

      {:ok, runtime, task}
    end
  end

  defp compose_messages(messages, prompt) do
    remaining = Enum.reject(messages, &(get(&1, :role, nil) in [:system, "system"]))
    [%{role: :system, content: prompt} | remaining]
  end

  defp explicit_script(opts) do
    case Keyword.fetch(opts, :jido_ai_react_script) do
      :error ->
        {:ok, false}

      {:ok, %ReActScript{} = script} ->
        if valid_script?(script), do: {:ok, true}, else: {:error, :invalid_react_script}

      {:ok, _other} ->
        {:error, :invalid_react_script}
    end
  end

  defp admit_script(_context, false), do: :ok

  defp admit_script(context, true) do
    with {:ok, runtime} <- options_map(get(context.metadata, :runtime_config, %{})),
         true <- get(runtime, :allow_test_scripts, false) == true do
      :ok
    else
      false -> {:error, :test_scripts_not_enabled}
      {:error, _reason} = error -> error
    end
  end

  defp valid_script?(%ReActScript{id: id, user: user, turns: turns}) do
    nonempty?(id) and nonempty?(user) and is_list(turns) and turns != [] and
      terminal_turn?(List.last(turns)) and
      Enum.all?(Enum.drop(turns, -1), &tool_turn?/1)
  end

  defp terminal_turn?(%{type: :answer, text: text}), do: is_binary(text)
  defp terminal_turn?(%{type: :fail, reason: _reason}), do: true
  defp terminal_turn?(_turn), do: false

  defp tool_turn?(%{type: :tool_call, tool_calls: calls}) when is_list(calls) and calls != [] do
    Enum.all?(calls, fn
      %{id: id, name: name, arguments: arguments} ->
        nonempty?(id) and nonempty?(name) and is_map(arguments)

      _other ->
        false
    end)
  end

  defp tool_turn?(_turn), do: false

  defp tools_enabled?(model),
    do: get(get(model.capabilities || %{}, :tools, %{}), :enabled, false) == true

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp keyword_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_llm_options}
  end

  defp provider_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, :invalid_provider_options}
  end

  defp provider_options(opts) when is_map(opts) and not is_struct(opts) do
    if Enum.all?(Map.keys(opts), &is_atom/1),
      do: {:ok, Map.to_list(opts)},
      else: {:error, :invalid_provider_options}
  end

  defp provider_options(_opts), do: {:error, :invalid_provider_options}

  defp options_map(opts) when is_map(opts) and not is_struct(opts), do: {:ok, opts}

  defp options_map(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, Map.new(opts)}, else: {:error, :invalid_prompt_config}
  end

  defp options_map(_opts), do: {:error, :invalid_prompt_config}

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
