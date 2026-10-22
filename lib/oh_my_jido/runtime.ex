defmodule OhMyJido.Runtime do
  @moduledoc """
  Supervises sessions and resource limits for one named Oh-My-Jido runtime.

  Add the runtime through the public facade in your application's supervision tree:

      {OhMyJido, name: MyApp.Coding, max_sessions: 100, max_active: 4}

  Each runtime owns a Jido supervisor, a session registry, bounded session
  and task supervisors, and optional Eval kernels. Starting it makes no
  session or model request. Choose a stable atom for `:name`; session and run
  IDs remain strings.

  Storage implements `Jido.Storage`. The default ETS adapter survives worker
  restart only while its table remains available. Use
  `storage: {Jido.Storage.File, path: "/private/coding-sessions"}` or another
  durable adapter to restore sessions after your application restarts.
  See the Sessions and recovery guide and Configuration reference.
  """

  use Supervisor

  alias OhMyJido.{Session, SessionRef}

  @defaults [
    host: {OhMyJido.Host.Local, []},
    default_role: :coding,
    max_sessions: 500,
    max_active: 8,
    max_processes: 8,
    max_subagents: 16,
    max_resources: 64,
    max_runs: 128,
    max_effects: 1_024,
    max_secrets: 256,
    allow_test_scripts: false,
    event_limit: 256,
    subscriber_limit: 128,
    max_pending_questions: 8,
    question_timeout_ms: 300_000,
    tool_timeout_ms: 30_000,
    run_timeout_ms: 300_000,
    max_iterations: 40,
    context_policy: [],
    eval: [backends: %{}, max_kernels: 8]
  ]

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: runtime_name!(opts),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts an independent runtime under the caller's supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = runtime_name!(opts)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    config =
      @defaults
      |> Keyword.merge(runtime_options!(Application.get_all_env(:oh_my_jido)))
      |> Keyword.merge(runtime_options!(opts))
      |> credential_host!()

    config =
      Keyword.put_new(config, :storage, {Jido.Storage.ETS, table: component(name, Storage)})

    validate_limits!(config)
    validate_native_boundary!()

    children = [
      {Jido, name: engine(name), max_tasks: Keyword.get(config, :max_jido_tasks, 1_000)},
      {Registry, keys: :unique, name: registry(name), meta: [config: config]},
      {Task.Supervisor, name: slots(name, :model), max_children: config[:max_active]},
      {Task.Supervisor, name: slots(name, :process), max_children: config[:max_processes]},
      {Task.Supervisor, name: slots(name, :subagent), max_children: config[:max_subagents]},
      {DynamicSupervisor,
       name: sessions(name), strategy: :one_for_one, max_children: config[:max_sessions]},
      Supervisor.child_spec({OhMyJido.Eval, config[:eval]}, id: :eval)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Starts a session in an existing workspace with explicit permissions.

  `:bundles` selects available tools; `:tools` supplies an explicit Action list
  instead. A session selection replaces the runtime selection and never adds
  permissions. Supplying both options fails before an agent starts.
  Permissions default to none. `:id` must be a string of 1 to 128 bytes.
  A stored ID restores its checkpoint rather than resetting the session;
  an already supervised ID returns `{:error, :session_exists}`.
  """
  @spec start_session(atom(), keyword()) :: {:ok, SessionRef.t()} | {:error, term()}
  def start_session(runtime, opts) when is_atom(runtime) and is_list(opts) do
    with {:ok, config} <- config(runtime),
         {:ok, opts} <- session_options(opts),
         {:ok, root} <- OhMyJido.Workspace.new(Keyword.get(opts, :workspace)),
         id when is_binary(id) and byte_size(id) in 1..128 <-
           Keyword.get_lazy(opts, :id, &Jido.Util.generate_id/0) do
      start_session_child(runtime, id, Keyword.put(opts, :workspace, root), config)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_session_id}
    end
  end

  def start_session(_runtime, _opts), do: {:error, :invalid_session_options}

  @doc "Restores a durable session without replaying interrupted work."
  @spec resume_session(atom(), String.t()) :: {:ok, SessionRef.t()} | {:error, term()}
  def resume_session(runtime, id) when is_atom(runtime) and is_binary(id) do
    with {:ok, config} <- config(runtime),
         {adapter, opts} <- Jido.Storage.normalize_storage(config[:storage]),
         {:ok, saved} <- Jido.Storage.fetch_checkpoint(adapter, {runtime, id}, opts) do
      start_session_child(runtime, id, [restore: saved], config)
    end
  end

  @doc "Lists the durable identities of currently supervised sessions."
  @spec list_sessions(atom()) :: [SessionRef.t()]
  def list_sessions(runtime) do
    registry(runtime)
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reduce([], fn {id, pid}, sessions ->
      if Process.alive?(pid),
        do: [%SessionRef{runtime: runtime, id: id} | sessions],
        else: sessions
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc false
  @spec config(atom()) :: {:ok, keyword()} | {:error, :runtime_unavailable}
  def config(runtime) do
    Registry.meta(registry(runtime), :config)
  rescue
    ArgumentError -> {:error, :runtime_unavailable}
  end

  @doc false
  @spec reserve(atom() | nil, :model | :process | :subagent, pid()) ::
          {:ok, pid() | nil} | {:error, term()}
  def reserve(nil, _kind, _owner), do: {:ok, nil}

  def reserve(runtime, kind, owner) when kind in [:model, :process, :subagent] do
    case Task.Supervisor.start_child(slots(runtime, kind), fn -> hold_slot(owner) end) do
      {:ok, pid} -> {:ok, pid}
      {:error, :max_children} -> {:error, {:capacity, kind}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  @doc false
  @spec release(pid() | nil) :: :ok
  def release(nil), do: :ok

  def release(pid) when is_pid(pid) do
    send(pid, :release)
    :ok
  end

  @doc false
  @spec via(SessionRef.t()) :: {:via, Registry, {atom(), String.t()}}
  def via(%SessionRef{runtime: runtime, id: id}), do: {:via, Registry, {registry(runtime), id}}

  @doc false
  def engine(runtime), do: component(runtime, Engine)
  @doc false
  def registry(runtime), do: component(runtime, Sessions)
  @doc false
  def sessions(runtime), do: component(runtime, SessionSupervisor)

  @doc false
  @spec eval(atom()) :: pid() | nil
  def eval(runtime) do
    runtime
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {:eval, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end

  defp start_session_child(runtime, id, opts, config) do
    ref = %SessionRef{runtime: runtime, id: id}
    child_opts = [ref: ref, options: opts, config: config]

    case DynamicSupervisor.start_child(sessions(runtime), {Session, child_opts}) do
      {:ok, _pid} -> {:ok, ref}
      {:error, {:already_started, _pid}} -> {:error, :session_exists}
      {:error, :max_children} -> {:error, {:capacity, :sessions}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slots(runtime, :model), do: component(runtime, ModelSlots)
  defp slots(runtime, :process), do: component(runtime, ProcessSlots)
  defp slots(runtime, :subagent), do: component(runtime, SubagentSlots)
  defp component(runtime, suffix), do: Module.concat(runtime, suffix)

  defp hold_slot(owner) do
    monitor = Process.monitor(owner)

    receive do
      :release -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end
  end

  defp runtime_name!(opts) do
    unless is_list(opts) and Keyword.keyword?(opts) do
      raise ArgumentError, "OhMyJido runtime options must be a keyword list with :name"
    end

    case Keyword.get(opts, :name) do
      name when is_atom(name) and name not in [nil, true, false] ->
        name

      _ ->
        raise ArgumentError,
              "OhMyJido requires a named runtime; supervise {OhMyJido, name: MyApp.Coding}"
    end
  end

  defp runtime_options!(opts) do
    case session_options(opts) do
      {:ok, options} ->
        options

      {:error, reason} ->
        raise ArgumentError, "invalid OhMyJido tool configuration: #{inspect(reason)}"
    end
  end

  defp session_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_session_options}

      Keyword.has_key?(opts, :bundles) and Keyword.has_key?(opts, :tools) ->
        {:error, {:conflicting_options, [:bundles, :tools]}}

      Keyword.has_key?(opts, :bundles) ->
        select_bundles(opts)

      Keyword.has_key?(opts, :tools) ->
        validate_tools(opts)

      true ->
        {:ok, opts}
    end
  end

  defp select_bundles(opts) do
    case OhMyJido.Tools.select(opts[:bundles]) do
      {:ok, tools} -> {:ok, opts |> Keyword.delete(:bundles) |> Keyword.put(:tools, tools)}
      {:error, reason} -> {:error, {:invalid_session_option, :bundles, reason}}
    end
  end

  defp validate_tools(opts) do
    tools = opts[:tools]

    with true <- is_list(tools) and Enum.all?(tools, &is_atom/1),
         {:ok, _tools} <- Jido.Util.validate_actions(tools) do
      {:ok, opts}
    else
      _ -> {:error, {:invalid_session_option, :tools, :expected_action_modules}}
    end
  end

  defp credential_host!(config) do
    case Keyword.pop(config, :credentials) do
      {nil, config} -> config
      {credentials, config} -> put_local_credentials!(config, credentials)
    end
  end

  defp put_local_credentials!(config, {resolver, options} = credentials)
       when is_atom(resolver) and is_list(options) do
    unless Keyword.keyword?(options) and Code.ensure_loaded?(resolver) and
             function_exported?(resolver, :resolve, 3) do
      raise ArgumentError, "credentials must be {ResolverModule, options} exporting resolve/3"
    end

    case config[:host] do
      OhMyJido.Host.Local ->
        Keyword.put(config, :host, {OhMyJido.Host.Local, credentials: credentials})

      {OhMyJido.Host.Local, host_options} when is_list(host_options) ->
        Keyword.put(
          config,
          :host,
          {OhMyJido.Host.Local, Keyword.put(host_options, :credentials, credentials)}
        )

      _ ->
        raise ArgumentError,
              ":credentials is a Host.Local shortcut; configure credentials in your custom host instead"
    end
  end

  defp put_local_credentials!(_config, _credentials),
    do: raise(ArgumentError, "credentials must be {ResolverModule, options} exporting resolve/3")

  defp validate_limits!(config) do
    for key <- [
          :max_sessions,
          :max_active,
          :max_processes,
          :max_subagents,
          :max_resources,
          :max_runs,
          :max_effects,
          :max_secrets,
          :event_limit,
          :subscriber_limit,
          :max_pending_questions,
          :question_timeout_ms,
          :tool_timeout_ms,
          :run_timeout_ms,
          :max_iterations
        ] do
      if not is_integer(config[key]) or config[key] < 1 do
        raise ArgumentError, "#{key} must be a positive integer"
      end
    end
  end

  defp validate_native_boundary! do
    unless Code.ensure_loaded?(Jido.AgentServer) and
             function_exported?(Jido.AgentServer, :private_diagnostics_version, 0) and
             Jido.AgentServer.private_diagnostics_version() == 1 do
      raise ArgumentError,
            "Jido private diagnostic boundary is unavailable; use the pinned native dependency"
    end
  end
end
