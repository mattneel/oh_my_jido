defmodule OhMyJido.Context do
  @moduledoc """
  Gives tools a trusted workspace, permissions, and application service bindings.

  Build a context when you want to run individual Jido Actions without a
  managed coding session:

      context =
        OhMyJido.Context.new!(
          workspace: "/path/to/project",
          permissions: [:read],
          bundles: [:read_only]
        )

      Jido.Exec.run(OhMyJido.Tools.Read, %{path: "mix.exs"},
        %{oh_my_jido: context},
        max_retries: 0
      )

  Tool availability does not grant permission. Constructors default to no
  permissions and the read-only tool bundle. They validate bindings without
  starting a runtime, model, credentials resolver, or optional service.
  A standalone context does not create a durable effect journal or approval
  conversation; use managed sessions when you need those features.

  Context is trusted application configuration, never a model request schema.
  Repository text and tool parameters must not choose its workspace, permissions,
  host policy, or adapters. Permissions are library policy, not an OS sandbox.
  """

  alias OhMyJido.{Host, Tools, Workspace}

  @supported_options [
    :session_id,
    :run_id,
    :runtime,
    :coordinator,
    :account,
    :model,
    :workspace,
    :permissions,
    :role,
    :host,
    :tools,
    :bundles,
    :adapters,
    :limits,
    :metadata
  ]

  @enforce_keys [:session_id, :workspace, :permissions]
  defstruct [
    :session_id,
    :run_id,
    :runtime,
    :coordinator,
    :account,
    :model,
    :workspace,
    :permissions,
    role: :coding,
    host: {OhMyJido.Host.Local, []},
    tools: [],
    adapters: %{},
    limits: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          run_id: String.t() | nil,
          runtime: atom() | nil,
          coordinator: pid() | nil,
          account: term(),
          model: term(),
          workspace: String.t(),
          permissions: MapSet.t(atom()),
          role: atom(),
          host: {module(), keyword()},
          tools: [module()],
          adapters: map(),
          limits: map(),
          metadata: map()
        }

  @type configuration_error :: {:invalid_context, atom(), term()}

  @doc """
  Builds an explicit host-trusted context without starting a runtime or service.

  `:workspace` is required and must identify an existing directory; symlinks are
  canonicalized by `OhMyJido.Workspace.new/1`. `:session_id` defaults to a native
  Jido-generated ID. `:permissions` defaults to an empty set and accepts a list
  or `MapSet` of non-nil, non-boolean atoms, including application-defined capabilities.

  `:bundles` selects tool availability through `OhMyJido.Tools.select/1` and
  defaults to `[:read_only]`. Alternatively, `:tools` supplies an explicit list
  of native Jido Actions, including custom Actions; the two options conflict.
  Neither selection confers permissions or configures optional services.

  All existing struct fields are supported. `:host` accepts a Host module or
  `{module, keyword_options}` and is normalized to the latter. `:adapters` is a
  map of capability atoms to `{module, keyword_options}` bindings exporting
  `invoke/3`. Callbacks are checked, never invoked during construction.
  `:limits` is a map of atom names to non-negative integer budgets.
  `:metadata` is a map. Account and model values remain opaque host selections.
  No application configuration or ambient credentials are read.

  Unknown or duplicate options fail with
  `{:error, {:invalid_context, field, reason}}`. Host options, adapter options,
  metadata, and opaque selections are trusted configuration, not model input.
  Direct struct construction and `fetch/1` retain their existing semantics.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, configuration_error()}
  def new(opts) do
    with :ok <- validate_options(opts),
         {:ok, workspace} <- normalize_workspace(opts),
         {:ok, permissions} <- normalize_permissions(Keyword.get(opts, :permissions, [])),
         {:ok, tools} <- normalize_tools(opts),
         {:ok, host} <- normalize_host(Keyword.get(opts, :host, OhMyJido.Host.Local)),
         :ok <- validate_fields(opts) do
      attributes =
        opts
        |> Keyword.delete(:bundles)
        |> Keyword.put(:workspace, workspace)
        |> Keyword.put(:permissions, permissions)
        |> Keyword.put(:tools, tools)
        |> Keyword.put(:host, host)
        |> Keyword.put_new_lazy(:session_id, &Jido.Util.generate_id/0)

      {:ok, struct!(__MODULE__, attributes)}
    end
  end

  @doc "Builds a host context or raises an ArgumentError naming its invalid field."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid context configuration: #{inspect(reason)}"
    end
  end

  @doc "Extracts the trusted context from a Jido execution context."
  @spec fetch(map() | t()) :: {:ok, t()} | {:error, :missing_context}
  def fetch(%__MODULE__{} = context), do: {:ok, context}
  def fetch(%{oh_my_jido: %__MODULE__{} = context}), do: {:ok, context}
  def fetch(_context), do: {:error, :missing_context}

  @doc "Checks an existing permission atom; never converts model-facing strings to atoms."
  @spec permitted?(t(), atom()) :: boolean()
  def permitted?(%__MODULE__{permissions: permissions}, permission) do
    MapSet.member?(permissions, permission)
  end

  defp validate_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: validate_option_names(opts, %{}),
      else: invalid(:options, :expected_keyword_list)
  end

  defp validate_option_names([], _seen), do: :ok

  defp validate_option_names([{field, _value} | rest], seen) do
    cond do
      field not in @supported_options -> invalid(field, :unknown_option)
      Map.has_key?(seen, field) -> invalid(field, :duplicate_option)
      true -> validate_option_names(rest, Map.put(seen, field, true))
    end
  end

  defp normalize_workspace(opts) do
    case Keyword.fetch(opts, :workspace) do
      {:ok, path} ->
        case Workspace.new(path) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, reason} -> invalid(:workspace, reason)
        end

      :error ->
        invalid(:workspace, :required)
    end
  end

  defp normalize_permissions(%MapSet{} = permissions),
    do: normalize_permissions(MapSet.to_list(permissions))

  defp normalize_permissions(permissions) do
    if atom_list?(permissions),
      do: {:ok, MapSet.new(permissions)},
      else: invalid(:permissions, :expected_atom_list_or_map_set)
  end

  defp normalize_tools(opts) do
    cond do
      Keyword.has_key?(opts, :tools) and Keyword.has_key?(opts, :bundles) ->
        invalid(:tools, {:conflicts_with, :bundles})

      Keyword.has_key?(opts, :tools) ->
        tools = Keyword.fetch!(opts, :tools)

        with true <- atom_list?(tools),
             {:ok, actions} <- Jido.Util.validate_actions(tools) do
          {:ok, Enum.uniq(actions)}
        else
          _invalid -> invalid(:tools, :expected_jido_action_modules)
        end

      true ->
        case Tools.select(Keyword.get(opts, :bundles, [:read_only])) do
          {:ok, tools} -> {:ok, tools}
          {:error, reason} -> invalid(:bundles, reason)
        end
    end
  end

  defp normalize_host(module) when is_atom(module) and module not in [nil, true, false],
    do: normalize_host({module, []})

  defp normalize_host({module, opts}) do
    with :ok <- keyword_options(opts),
         :ok <- module_callbacks(module, Host.behaviour_info(:callbacks)) do
      {:ok, {module, opts}}
    else
      {:error, reason} -> invalid(:host, reason)
    end
  end

  defp normalize_host(_host), do: invalid(:host, :expected_module_or_module_options)

  defp validate_fields(opts) do
    Enum.reduce_while(opts, :ok, fn {field, value}, :ok ->
      case validate_field(field, value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, invalid(field, reason)}
      end
    end)
  end

  defp validate_field(field, value) when field in [:session_id, :run_id] do
    if (field == :run_id and is_nil(value)) or valid_id?(value),
      do: :ok,
      else: {:error, :expected_nonempty_string}
  end

  defp validate_field(field, value) when field in [:runtime, :role] do
    if (field == :runtime and is_nil(value)) or name_atom?(value),
      do: :ok,
      else: {:error, :expected_atom}
  end

  defp validate_field(:coordinator, value) do
    if is_nil(value) or is_pid(value), do: :ok, else: {:error, :expected_pid_or_nil}
  end

  defp validate_field(:adapters, adapters) when is_map(adapters) and not is_struct(adapters) do
    Enum.reduce_while(adapters, :ok, &validate_adapter_entry/2)
  end

  defp validate_field(:limits, limits) when is_map(limits) and not is_struct(limits) do
    Enum.reduce_while(limits, :ok, fn {key, value}, :ok ->
      cond do
        not name_atom?(key) ->
          {:halt, {:error, :expected_atom_limit_names}}

        not (is_integer(value) and value >= 0) ->
          {:halt, {:error, {:invalid_limit, key, :expected_non_negative_integer}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_field(:metadata, metadata) when is_map(metadata) and not is_struct(metadata),
    do: :ok

  defp validate_field(field, _value) when field in [:adapters, :limits, :metadata],
    do: {:error, :expected_map}

  defp validate_field(_field, _value), do: :ok

  defp validate_adapter_entry({capability, binding}, :ok) do
    if name_atom?(capability) do
      adapter_result(validate_adapter(binding), capability)
    else
      {:halt, {:error, :expected_atom_adapter_names}}
    end
  end

  defp adapter_result(:ok, _capability), do: {:cont, :ok}

  defp adapter_result({:error, reason}, capability),
    do: {:halt, {:error, {:invalid_adapter, capability, reason}}}

  defp validate_adapter({module, opts}) do
    with :ok <- keyword_options(opts), do: module_callbacks(module, invoke: 3)
  end

  defp validate_adapter(_binding), do: {:error, :expected_module_options_tuple}

  defp keyword_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: :ok,
      else: {:error, :expected_keyword_options}
  end

  defp module_callbacks(module, callbacks)
       when is_atom(module) and module not in [nil, true, false] do
    case Code.ensure_loaded(module) do
      {:module, _module} ->
        validate_callbacks(module, callbacks)

      {:error, reason} ->
        {:error, {:module_unavailable, module, reason}}
    end
  end

  defp module_callbacks(_module, _callbacks), do: {:error, :expected_module}

  defp validate_callbacks(module, callbacks) do
    case Enum.find(callbacks, fn {name, arity} -> not function_exported?(module, name, arity) end) do
      nil -> :ok
      {name, arity} -> {:error, {:missing_callback, module, name, arity}}
    end
  end

  defp valid_id?(value) when is_binary(value),
    do: value != "" and String.valid?(value) and not String.contains?(value, <<0>>)

  defp valid_id?(_value), do: false

  defp atom_list?([]), do: true
  defp atom_list?([value | rest]), do: name_atom?(value) and atom_list?(rest)
  defp atom_list?(_value), do: false

  defp name_atom?(value), do: is_atom(value) and value not in [nil, true, false]

  defp invalid(field, reason), do: {:error, {:invalid_context, field, reason}}
end
