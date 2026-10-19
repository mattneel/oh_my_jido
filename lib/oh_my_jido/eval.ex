defmodule OhMyJido.Eval do
  @moduledoc """
  Supervised, bounded, persistent language kernels owned by coding sessions.

  Configure `backends: %{elixir: opts, javascript: opts, python: opts}`. No backend
  is enabled implicitly. Elixir and JavaScript require `isolation: :trusted` for
  explicitly trusted code, or `isolation: :os, launcher: {path, argv_prefix}` for
  a host-provided isolation launcher. A separate ERTS is crash separation, not an
  operating-system sandbox. Python uses Snakepit's managed workers exclusively.

  A timeout, hard cancellation, crash or idle expiry invalidates retained state.
  The next cell fails until the host explicitly resets or closes the kernel.
  Cells and host effects are never automatically retried.
  """
  use Supervisor

  alias OhMyJido.Context
  alias OhMyJido.Eval.{Kernel, Manager}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    # The supervisor owns only the retained-state index. Manager restarts must
    # not silently turn a previously used kernel into an empty new namespace.
    index = :ets.new(__MODULE__, [:set, :public])
    manager_opts = opts |> Keyword.put(:supervisor, self()) |> Keyword.put(:index, index)

    children = [
      Supervisor.child_spec({Task.Supervisor, max_children: Keyword.get(opts, :max_tasks, 64)},
        id: :tasks
      ),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :kernels),
      Supervisor.child_spec({Manager, manager_opts}, id: :manager)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def open(server, context, language, _opts \\ []) do
    with {:ok, context} <- Context.fetch(context),
         :ok <- permitted(context),
         {:ok, pid} <- manager_call(server, {:open, context, language}) do
      {:ok, Kernel.info(pid)}
    end
  catch
    :exit, reason -> {:error, {:kernel_invalidated, reason}}
  end

  def execute(server, context, language, source, opts \\ []) do
    with {:ok, context} <- Context.fetch(context),
         :ok <- permitted(context),
         {:ok, pid} <- manager_call(server, {:open, context, language}) do
      Kernel.execute(pid, context, source, opts)
    end
  catch
    :exit, reason -> {:error, {:kernel_invalidated, reason}}
  end

  def interrupt(server, session_id, language) do
    with {:ok, pid} <- manager_call(server, {:lookup, session_id, language}),
         do: Kernel.interrupt(pid)
  catch
    :exit, reason -> {:error, {:kernel_invalidated, reason}}
  end

  def interrupt(server, session_id, language, execution_id) do
    with {:ok, pid} <- manager_call(server, {:lookup, session_id, language}),
         do: Kernel.interrupt(pid, execution_id)
  catch
    :exit, reason -> {:error, {:kernel_invalidated, reason}}
  end

  def reset(server, %Context{} = context, language) do
    reset_kernel(server, context.session_id, language, context)
  end

  def reset(server, session_id, language), do: reset_kernel(server, session_id, language, nil)

  defp reset_kernel(server, session_id, language, context) do
    case manager_call(server, {:reset, session_id, language, context}) do
      {:reset_result, result} -> result
      {:ok, pid} -> {:ok, Kernel.info(pid)}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:kernel_invalidated, reason}}
  end

  def close(server, session_id, language),
    do: manager_call(server, {:close, session_id, language})

  def close_session(server, session_id), do: manager_call(server, {:close_session, session_id})

  def info(server, session_id, language) do
    with {:ok, pid} <- manager_call(server, {:lookup, session_id, language}),
         do: {:ok, Kernel.info(pid)}
  catch
    :exit, reason -> {:error, {:kernel_invalidated, reason}}
  end

  @doc false
  def child(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _kind, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
  end

  defp manager_call(server, message) do
    case child(server, :manager) do
      nil -> {:error, :eval_unavailable}
      manager -> GenServer.call(manager, message, :infinity)
    end
  catch
    :exit, reason -> {:error, {:eval_unavailable, reason}}
  end

  defp permitted(context) do
    if Context.permitted?(context, :eval), do: :ok, else: {:error, {:permission_denied, :eval}}
  end
end
