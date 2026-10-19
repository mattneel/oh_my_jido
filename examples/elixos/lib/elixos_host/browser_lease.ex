defmodule ElixosHost.BrowserLease do
  @moduledoc "One monitored owner for the actual singleton browser, with timeout tombstones."
  use GenServer, restart: :temporary

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
  end

  def check(server, context, request),
    do: GenServer.call(server, {:check, identity(context), request})

  def run(server, context, request, function),
    do: GenServer.call(server, {:run, context, request, function}, :infinity)

  def release(server, context, page_id \\ nil),
    do: GenServer.call(server, {:release, identity(context), page_id})

  def owner(server), do: GenServer.call(server, :owner)

  @impl true
  def init(options) do
    {:ok,
     %{
       task_supervisor: Keyword.fetch!(options, :task_supervisor),
       owner: nil,
       owner_monitor: nil,
       page_id: nil,
       browser_pid: nil,
       active: nil,
       orphaned: false,
       poisoned: false
     }}
  end

  @impl true
  def handle_call(:owner, _from, state), do: {:reply, state.owner, state}

  def handle_call({:check, owner, request}, _from, state),
    do: {:reply, permitted(state, owner, request), state}

  def handle_call({:run, context, request, function}, from, state) do
    with :ok <- permitted(state, identity(context), request),
         {:ok, browser} <- Elixos.Browser.status(),
         true <- is_nil(state.browser_pid) or state.browser_pid == browser,
         true <- is_pid(context.coordinator) and Process.alive?(context.coordinator) do
      state = claim(state, context, browser)
      task = Task.Supervisor.async_nolink(state.task_supervisor, function)
      timer = Process.send_after(self(), {:deadline, task.ref}, request.timeout_ms)
      active = %{task: task, from: from, timer: timer}
      {:noreply, %{state | active: active}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      false -> {:reply, {:error, :browser_owner_or_service_unavailable}, state}
    end
  end

  def handle_call({:release, owner, page_id}, _from, state) do
    cond do
      not is_nil(state.owner) and state.owner != owner ->
        {:reply, {:error, :browser_owner_mismatch}, state}

      not is_nil(page_id) and page_id != state.page_id ->
        {:reply, {:error, :unknown_browser_page}, state}

      not is_nil(state.active) ->
        {:reply, {:error, :browser_operation_pending}, state}

      state.poisoned ->
        {:reply, {:error, :browser_reconciliation_required}, state}

      true ->
        {:reply, :ok, release_owner(state)}
    end
  end

  @impl true
  def handle_info({ref, result}, %{active: %{task: %{ref: ref}} = active} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(active.timer)

    result =
      case result do
        {:ok, response} when is_map(response) -> {:ok, Map.put(response, :page_id, state.page_id)}
        {:error, _reason} = error -> error
        _invalid -> {:error, %{reason: :invalid_browser_response, effect: :uncertain}}
      end

    if active.from, do: GenServer.reply(active.from, result)
    poisoned = match?({:error, %{effect: :uncertain}}, result)
    state = %{state | active: nil, poisoned: state.poisoned or poisoned}
    {:noreply, if(state.orphaned and not state.poisoned, do: release_owner(state), else: state)}
  end

  def handle_info({:deadline, ref}, %{active: %{task: %{ref: ref}} = active} = state) do
    if active.from,
      do: GenServer.reply(active.from, {:error, %{reason: :browser_timeout, effect: :uncertain}})

    # Do not kill the caller and then admit another session: the actual Browser
    # GenServer may still be executing the request. Its late reply drains first.
    {:noreply, %{state | active: %{active | from: nil}}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active: %{task: %{ref: ref}} = active} = state
      ) do
    Process.cancel_timer(active.timer)

    if active.from,
      do:
        GenServer.reply(
          active.from,
          {:error, %{reason: :browser_worker_failed, effect: :uncertain}}
        )

    {:noreply, %{state | active: nil, poisoned: true}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{owner_monitor: monitor} = state) do
    state = %{state | orphaned: true}

    {:noreply,
     if(is_nil(state.active) and not state.poisoned, do: release_owner(state), else: state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp permitted(%{poisoned: true}, _owner, _request),
    do: {:error, :browser_reconciliation_required}

  defp permitted(%{owner: held}, owner, %{operation: :navigate})
       when not is_nil(held) and held != owner,
       do: {:error, :browser_leased}

  defp permitted(%{owner: held}, owner, _request) when not is_nil(held) and held != owner,
    do: {:error, :browser_owner_mismatch}

  defp permitted(%{active: active}, _owner, _request) when not is_nil(active),
    do: {:error, :browser_operation_pending}

  defp permitted(%{owner: nil}, _owner, %{operation: :navigate} = request) do
    if Map.has_key?(request, :page_id), do: {:error, :unknown_browser_page}, else: :ok
  end

  defp permitted(%{owner: nil}, _owner, _request), do: {:error, :unknown_browser_page}

  defp permitted(state, _owner, %{operation: :navigate} = request) do
    if not Map.has_key?(request, :page_id) or request.page_id == state.page_id,
      do: :ok,
      else: {:error, :unknown_browser_page}
  end

  defp permitted(state, _owner, %{page_id: page_id}) when page_id == state.page_id, do: :ok
  defp permitted(_state, _owner, _request), do: {:error, :unknown_browser_page}

  defp claim(%{owner: nil} = state, context, browser) do
    %{
      state
      | owner: identity(context),
        owner_monitor: Process.monitor(context.coordinator),
        page_id: Jido.Util.generate_id(),
        browser_pid: browser,
        orphaned: false
    }
  end

  defp claim(state, _context, _browser), do: state

  defp release_owner(state) do
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])
    # Release only our lease; the host's browser process and page remain owned by Elixos.
    %{state | owner: nil, owner_monitor: nil, page_id: nil, browser_pid: nil, orphaned: false}
  end

  defp identity(context), do: {context.runtime, context.session_id}
end
