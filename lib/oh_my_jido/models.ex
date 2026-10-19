defmodule OhMyJido.Models do
  @moduledoc """
  Six coding-harness roles over the installed Jido model aliases.

  `select/2` resolves each selection from explicit session options, a retained
  `:session_selection`, an approved declarative `:project_config`, `:user_config`,
  and application defaults, in that order. Each configuration layer can supply
  `:model_roles` whose values are model inputs or `%{model: input, account: ref}`.
  A retained selection can also contain `:role`, `:model`, and `:account` directly.
  Models remain ReqLLM inputs; account references are nonempty strings, atoms,
  integers, or tuples of those opaque values, never credential maps or handles.

  Project overrides require the host's `:project_approved` boolean, or an
  `:project_config` envelope of `%{approved: true, config: declarative_map}`.
  This module never reads or evaluates repository configuration files.
  """

  alias Jido.AI.ModelAliases
  alias Jido.AI.Reasoning.ReAct.ToolSelection
  alias OhMyJido.Context
  import OhMyJido.Config, only: [fetch: 2, get: 3]

  @roles [:coding, :planning, :exploration, :review, :advisor, :compaction]
  @default_roles %{
    coding: :capable,
    planning: :planning,
    exploration: :fast,
    review: :capable,
    advisor: :thinking,
    compaction: :fast
  }

  @lifecycle_keys ~w(refresh_token refresh id_token idtoken oauth_file auth_file oauth_path auth_path credentials_file client_secret token_secret client_id issuer subject expires_at expires expiry expires_in scopes generation account_ref access_mode host_id access token authorization auth password cookie cookies set-cookie)
  @credential_keys ~w(api_key access_token auth_mode) ++ @lifecycle_keys
  @option_containers ~w(llm_opts provider_options req_http_options)

  @doc "Detects credential fields in request configuration before native Jido retains it."
  @spec credential_options?(term()) :: boolean()
  def credential_options?(opts), do: option_fields?(opts, @credential_keys)

  @doc "Detects lifecycle records that must remain in the credential broker, not inference options."
  @spec lifecycle_options?(term()) :: boolean()
  def lifecycle_options?(opts), do: option_fields?(opts, @lifecycle_keys)

  defp option_fields?(opts, forbidden) do
    Enum.any?(option_pairs(opts), fn
      {key, value} ->
        field?(key, forbidden) or
          (field?(key, @option_containers) and deep_fields?(value, forbidden))

      _other ->
        false
    end)
  end

  defp option_pairs(opts) when is_map(opts), do: Map.to_list(opts)
  defp option_pairs(opts) when is_list(opts), do: opts
  defp option_pairs(_opts), do: []

  defp deep_fields?(value, forbidden) when is_map(value) do
    value |> Map.to_list() |> Enum.any?(&deep_fields?(&1, forbidden))
  end

  defp deep_fields?(value, forbidden) when is_list(value),
    do: Enum.any?(value, &deep_fields?(&1, forbidden))

  defp deep_fields?({key, value}, forbidden) when is_atom(key) or is_binary(key),
    do: field?(key, forbidden) or deep_fields?(value, forbidden)

  defp deep_fields?(value, forbidden) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&deep_fields?(&1, forbidden))

  defp deep_fields?(_value, _forbidden), do: false

  defp field?(key, fields) when is_atom(key), do: Atom.to_string(key) in fields

  defp field?(key, fields) when is_binary(key),
    do: String.valid?(key) and String.downcase(key) in fields

  defp field?(_key, _fields), do: false

  @doc "Returns the supported role names without creating atoms from input."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc "Selects a role, resolved model and opaque account using explicit trust precedence."
  @spec select(keyword() | map(), keyword() | map()) :: {:ok, map()} | {:error, atom()}
  def select(session_opts, runtime_config) do
    with {:ok, explicit} <- options(session_opts),
         {:ok, defaults} <- options(runtime_config),
         {:ok, session} <-
           layer(get(explicit, :session_selection, get(defaults, :session_selection, %{}))),
         {:ok, project} <- approved_project(explicit, defaults),
         {:ok, user} <- layer(get(defaults, :user_config, %{})),
         layers = [
           explicit: explicit,
           session: session,
           project: project,
           user: user,
           default: defaults
         ],
         {:ok, role} <- select_role(layers),
         {:ok, model_input, source} <- select_model(layers, role),
         {:ok, model} <- resolve(model_input),
         {account, account_source} = select_account(layers, role),
         :ok <- selection_account(account) do
      {:ok,
       %{
         role: role,
         model: model,
         account: account,
         source: source,
         account_source: account_source
       }}
    end
  end

  @doc "Checks a durable opaque account reference, never a credential record or process handle."
  @spec account_reference?(term()) :: boolean()
  def account_reference?(account) when is_binary(account),
    do: String.valid?(account) and String.trim(account) != ""

  def account_reference?(account) when is_atom(account), do: account not in [nil, true, false]
  def account_reference?(account) when is_integer(account), do: true

  def account_reference?(account) when is_tuple(account) and tuple_size(account) > 0 do
    account |> Tuple.to_list() |> Enum.all?(&account_reference?/1)
  end

  def account_reference?(_account), do: false

  defp selection_account(nil), do: :ok

  defp selection_account(account) do
    if account_reference?(account), do: :ok, else: {:error, :invalid_account_reference}
  end

  @doc "Resolves and locally validates a model through the installed Jido/ReqLLM APIs."
  @spec resolve(term()) :: {:ok, ReqLLM.model_input()} | {:error, atom()}
  def resolve(model_input) do
    resolved =
      if is_atom(model_input),
        do: ModelAliases.resolve_model(model_input),
        else: Jido.AI.resolve_model(model_input)

    if deep_fields?(resolved, @credential_keys) do
      {:error, :credentials_must_come_from_host}
    else
      case ReqLLM.model(resolved) do
        {:ok, _metadata} -> {:ok, resolved}
        {:error, _reason} -> {:error, :invalid_model}
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_model}
  end

  @doc "Reads local model capability metadata; this never discovers models over the network."
  @spec describe(term()) :: {:ok, LLMDB.Model.t()} | {:error, :invalid_model}
  def describe(model_input) do
    with {:ok, resolved} <- resolve(model_input),
         {:ok, metadata} <- ReqLLM.model(resolved) do
      {:ok, metadata}
    else
      {:error, _reason} -> {:error, :invalid_model}
    end
  end

  @doc "Intersects a request action registry with host-registered actions and capability grants."
  @spec granted_tools(Context.t(), ToolSelection.tools_input()) :: {:ok, map()} | {:error, term()}
  def granted_tools(%Context{} = context, tools) do
    with {:ok, requested} <- ToolSelection.normalize_input(tools),
         {:ok, registered} <- ToolSelection.normalize_input(context.tools),
         :ok <- consistent_names(requested),
         :ok <- consistent_names(registered) do
      selected =
        Map.filter(requested, fn {name, module} ->
          Map.get(registered, name) == module and granted_action?(context, module)
        end)

      {:ok, selected}
    end
  end

  defp granted_action?(context, module) do
    if function_exported?(module, :capability, 0) do
      case module.capability() do
        capability when is_atom(capability) and not is_nil(capability) ->
          Context.permitted?(context, capability)

        _other ->
          false
      end
    else
      Context.permitted?(context, :custom)
    end
  end

  defp consistent_names(registry) do
    if Enum.all?(registry, fn {name, module} -> name == module.name() end),
      do: :ok,
      else: {:error, :tool_registry_name_mismatch}
  end

  defp select_role(layers) do
    layers
    |> Enum.find_value(&selected_role/1)
    |> normalize_role()
  end

  defp selected_role({_source, config}) do
    selection =
      case fetch(config, :role) do
        :error -> fetch(config, :default_role)
        found -> found
      end

    case selection do
      {:ok, role} -> {:selected, role}
      :error -> nil
    end
  end

  defp normalize_role(nil), do: {:ok, :coding}
  defp normalize_role({:selected, role}) when role in @roles, do: {:ok, role}

  defp normalize_role({:selected, role}) when is_binary(role) do
    case Enum.find(@roles, &(Atom.to_string(&1) == role)) do
      nil -> {:error, :invalid_role}
      existing -> {:ok, existing}
    end
  end

  defp normalize_role(_other), do: {:error, :invalid_role}

  defp select_model(layers, role) do
    Enum.reduce_while(layers, :missing, fn {source, config}, _acc ->
      case model_in_layer(config, role) do
        :missing -> {:cont, :missing}
        {:ok, input} -> {:halt, {:ok, input, source}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :missing -> {:ok, Map.fetch!(@default_roles, role), :default}
      selection -> selection
    end
  end

  defp model_in_layer(config, role) do
    retained_role = get(config, :role, role)
    same_role? = retained_role == role or retained_role == Atom.to_string(role)
    direct = if same_role?, do: fetch(config, :model), else: :error

    case direct do
      {:ok, input} -> {:ok, input}
      :error -> model_role_entry(role_entry(config, role))
    end
  end

  defp model_role_entry(:missing), do: :missing
  defp model_role_entry({:error, _reason} = error), do: error

  defp model_role_entry({:ok, entry}) when is_map(entry) do
    if has?(entry, :id) or has?(entry, :provider) do
      {:ok, entry}
    else
      case fetch(entry, :model) do
        {:ok, input} -> {:ok, input}
        :error -> :missing
      end
    end
  end

  defp model_role_entry({:ok, input}), do: {:ok, input}

  defp select_account(layers, role) do
    Enum.find_value(layers, {nil, nil}, fn {source, config} ->
      case account_in_layer(config, role) do
        {:ok, account} -> {account, source}
        :error -> nil
      end
    end)
  end

  defp account_in_layer(config, role) do
    case fetch(config, :account) do
      :error ->
        case role_entry(config, role) do
          {:ok, entry} when is_map(entry) -> fetch(entry, :account)
          _other -> :error
        end

      found ->
        found
    end
  end

  defp role_entry(config, role) do
    case get(config, :model_roles, %{}) do
      roles when is_map(roles) ->
        case fetch(roles, role) do
          {:ok, entry} -> {:ok, entry}
          :error -> :missing
        end

      roles when is_list(roles) ->
        if Keyword.keyword?(roles),
          do: role_entry(%{model_roles: Map.new(roles)}, role),
          else: {:error, :invalid_model_roles}

      _other ->
        {:error, :invalid_model_roles}
    end
  end

  defp approved_project(explicit, defaults) do
    project = get(explicit, :project_config, get(defaults, :project_config, %{}))
    approved? = get(explicit, :project_approved, get(defaults, :project_approved, false)) == true

    cond do
      is_map(project) and has?(project, :approved) ->
        approved_project_envelope(project)

      approved? ->
        project_layer(project)

      true ->
        {:ok, %{}}
    end
  end

  defp approved_project_envelope(envelope) do
    if get(envelope, :approved, false) == true,
      do: project_layer(get(envelope, :config, %{})),
      else: {:ok, %{}}
  end

  defp project_layer(project) do
    with {:ok, config} <- options(project),
         true <- declarative?(config) do
      {:ok, config}
    else
      _other -> {:error, :project_config_must_be_declarative}
    end
  end

  defp declarative?(value) when is_binary(value) or is_atom(value) or is_number(value), do: true
  defp declarative?(value) when is_list(value), do: Enum.all?(value, &declarative?/1)

  defp declarative?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.all?(&declarative?/1)

  defp declarative?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> declarative?(key) and declarative?(item) end)

  defp declarative?(_value), do: false

  defp layer(nil), do: {:ok, %{}}
  defp layer(value), do: options(value)

  defp options(value) when is_map(value) and not is_struct(value), do: {:ok, value}

  defp options(value) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, Map.new(value)}, else: {:error, :invalid_model_config}
  end

  defp options(_value), do: {:error, :invalid_model_config}

  defp has?(map, key), do: match?({:ok, _value}, fetch(map, key))
end
