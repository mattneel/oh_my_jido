defmodule OhMyJido.Eval.Manager do
  @moduledoc false
  use GenServer

  alias OhMyJido.Eval.{Kernel, Peer, Python}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval, 30_000)
    Process.send_after(self(), :sweep, interval)
    index = Keyword.fetch!(opts, :index)

    entries =
      Map.new(:ets.tab2list(index), fn {key, generation, workspace} ->
        {key,
         %{
           pid: nil,
           monitor: nil,
           context: nil,
           workspace: workspace,
           generation: generation,
           reason: :eval_supervisor_restarted
         }}
      end)

    {:ok,
     %{
       supervisor: Keyword.fetch!(opts, :supervisor),
       opts: opts,
       index: index,
       entries: entries,
       interval: interval
     }}
  end

  @impl true
  def handle_call({:open, context, language}, _from, state) do
    key = {context.session_id, language}

    case Map.get(state.entries, key) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: {:reply, {:error, {:kernel_invalidated, :controller_down}}, state}

      %{reason: reason} ->
        {:reply, {:error, {:kernel_invalidated, reason}}, state}

      nil ->
        start_kernel(key, context, language, 1, state)
    end
  end

  def handle_call({:lookup, session_id, language}, _from, state) do
    reply =
      case Map.get(state.entries, {session_id, language}) do
        nil ->
          {:error, :not_open}

        %{pid: nil, reason: reason} ->
          {:error, {:kernel_invalidated, reason}}

        %{pid: pid} ->
          if Process.alive?(pid),
            do: {:ok, pid},
            else: {:error, {:kernel_invalidated, :controller_down}}
      end

    {:reply, reply, state}
  end

  def handle_call({:reset, session_id, language, context}, _from, state) do
    key = {session_id, language}

    case Map.get(state.entries, key) do
      nil ->
        {:reply, {:error, :not_open}, state}

      entry ->
        reset_entry(key, entry, context || entry.context, state)
    end
  end

  def handle_call({:close, session_id, language}, _from, state) do
    {:reply, :ok, close_entry({session_id, language}, state, :closed)}
  end

  def handle_call({:close_session, session_id}, _from, state) do
    next =
      state.entries
      |> Map.keys()
      |> Enum.filter(fn {id, _language} -> id == session_id end)
      |> Enum.reduce(state, fn key, acc -> close_entry(key, acc, :closed) end)

    {:reply, :ok, next}
  end

  @impl true
  def handle_info(:sweep, state) do
    idle_timeout = Keyword.get(state.opts, :idle_timeout, 300_000)
    cutoff = System.monotonic_time(:millisecond) - idle_timeout

    next =
      Enum.reduce(state.entries, state, fn
        {key, %{pid: pid}}, acc when is_pid(pid) ->
          case safe_info(pid) do
            %{status: status, last_used: last_used}
            when status != :busy and last_used <= cutoff ->
              close_entry(key, acc, :idle_expired)

            _ ->
              acc
          end

        _entry, acc ->
          acc
      end)

    Process.send_after(self(), :sweep, state.interval)
    {:noreply, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    entries =
      Map.new(state.entries, fn
        {key, %{monitor: ^ref} = entry} ->
          {key, %{entry | pid: nil, reason: {:controller_down, reason}}}

        entry ->
          entry
      end)

    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp reset_entry(_key, _entry, nil, state),
    do: {:reply, {:error, :reset_context_required}, state}

  defp reset_entry({_session_id, language} = key, entry, context, state) do
    cond do
      context.workspace != entry.workspace ->
        {:reply, {:error, :session_mismatch}, state}

      is_pid(entry.pid) and Process.alive?(entry.pid) and
          context.coordinator == entry.context.coordinator ->
        reset_live_entry(key, entry, context, state)

      true ->
        state = close_entry(key, state, :explicit_reset)
        start_kernel(key, context, language, entry.generation + 1, state)
    end
  end

  defp reset_live_entry(key, entry, context, state) do
    case Kernel.reset(entry.pid) do
      {:ok, info} = result ->
        entry = %{entry | generation: info.generation, context: context}
        :ets.insert(state.index, {key, info.generation, context.workspace})

        {:reply, {:reset_result, result}, %{state | entries: Map.put(state.entries, key, entry)}}

      error ->
        {:reply, {:reset_result, error}, state}
    end
  end

  defp start_kernel(key, context, language, generation, state) do
    backends = Keyword.get(state.opts, :backends, %{})

    with {:ok, backend_opts} <- configured(backends, language),
         {:ok, backend, backend_opts} <- backend(language, backend_opts),
         :ok <- admitted(state),
         {:ok, pid} <-
           DynamicSupervisor.start_child(
             child(state, :kernels),
             {Kernel,
              backend: backend,
              backend_opts: backend_opts,
              context: context,
              tasks: child(state, :tasks),
              generation: generation,
              server: state.supervisor,
              language: language,
              callback_timeout: Keyword.get(state.opts, :callback_timeout, 2_000),
              limits: Keyword.get(state.opts, :limits, [])}
           ) do
      entry = %{
        pid: pid,
        monitor: Process.monitor(pid),
        context: context,
        workspace: context.workspace,
        generation: generation,
        reason: nil
      }

      :ets.insert(state.index, {key, generation, context.workspace})
      {:reply, {:ok, pid}, %{state | entries: Map.put(state.entries, key, entry)}}
    else
      {:error, reason} -> {:reply, {:error, unwrap_start_error(reason)}, state}
    end
  end

  defp admitted(state) do
    count = Enum.count(state.entries, fn {_key, entry} -> is_pid(entry.pid) end)
    if count < Keyword.get(state.opts, :max_kernels, 8), do: :ok, else: {:error, :kernel_limit}
  end

  defp configured(backends, language) do
    case Map.fetch(backends, language) do
      {:ok, opts} when is_list(opts) -> {:ok, opts}
      _ -> {:error, {:backend_unavailable, language}}
    end
  end

  defp backend(language, opts) do
    case Keyword.pop(opts, :backend) do
      {nil, opts} -> builtin_backend(language, opts)
      {module, opts} -> host_backend(module, Keyword.put(opts, :language, language))
    end
  end

  defp builtin_backend(language, opts) when language in [:elixir, :javascript],
    do: {:ok, Peer, Keyword.put(opts, :language, language)}

  defp builtin_backend(:python, opts), do: {:ok, Python, opts}
  defp builtin_backend(language, _opts), do: {:error, {:backend_unavailable, language}}

  defp host_backend(module, opts) when is_atom(module) do
    exported =
      Code.ensure_loaded?(module) and
        Enum.all?(
          [open: 2, execute: 2, interrupt: 2, reset: 1, close: 1],
          fn {name, arity} -> function_exported?(module, name, arity) end
        )

    if exported, do: {:ok, module, opts}, else: {:error, {:invalid_backend, module}}
  end

  defp host_backend(module, _opts), do: {:error, {:invalid_backend, module}}

  defp child(state, id), do: OhMyJido.Eval.child(state.supervisor, id)

  defp close_entry(key, state, reason) do
    case Map.get(state.entries, key) do
      nil ->
        state

      entry ->
        if is_reference(entry.monitor), do: Process.demonitor(entry.monitor, [:flush])

        if is_pid(entry.pid),
          do: DynamicSupervisor.terminate_child(child(state, :kernels), entry.pid)

        entries =
          if reason == :closed do
            :ets.delete(state.index, key)
            Map.delete(state.entries, key)
          else
            Map.put(state.entries, key, %{entry | pid: nil, monitor: nil, reason: reason})
          end

        %{state | entries: entries}
    end
  end

  defp safe_info(pid) do
    Kernel.info(pid)
  catch
    :exit, _reason -> nil
  end

  defp unwrap_start_error({reason, {Kernel, :start_link, _args}}), do: reason
  defp unwrap_start_error(reason), do: reason
end
