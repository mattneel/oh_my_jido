defmodule OhMyJidoDocs.Editor.WriterLease do
  @moduledoc false

  alias OhMyJidoDocs.Workspaces

  @registry OhMyJidoDocs.Editor.WriterRegistry
  @tasks OhMyJidoDocs.Editor.WriterTasks
  @timeout 5_000

  def lookup(run) do
    case Registry.lookup(@registry, run.id) do
      [{pid, metadata}] ->
        if Process.alive?(pid) and metadata.token == run.source_writer_token and
             metadata.session_id == run.session_id and metadata.workspace == run.workspace,
           do: {:ok, Map.put(metadata, :pid, pid)},
           else: {:error, :invalid_writer_claim}

      [] ->
        {:error, :writer_missing}
    end
  rescue
    ArgumentError -> {:error, :writer_state_unavailable}
  end

  def start(run, origin) do
    owner = self()
    request = make_ref()

    case Task.Supervisor.start_child(@tasks, fn -> hold(run, origin, owner, request) end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^request, {:ok, metadata}} ->
            Process.demonitor(monitor, [:flush])
            {:ok, Map.put(metadata, :pid, pid)}

          {^request, {:error, reason}} ->
            Process.demonitor(monitor, [:flush])
            {:error, reason}

          {:DOWN, ^monitor, :process, ^pid, _reason} ->
            {:error, :writer_lease_unavailable}
        after
          @timeout ->
            Process.demonitor(monitor, [:flush])
            {:error, :writer_lease_unconfirmed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :writer_state_unavailable}
  end

  def bind(lease, native_pid), do: request(lease, {:bind, native_pid})
  def begin_native(lease), do: request(lease, :begin_native)
  def confirm_stopped(lease, native_pid), do: request(lease, {:confirm_stopped, native_pid})
  def acknowledge_absence(lease), do: request(lease, :acknowledge_absence)
  def release(lease), do: request(lease, :release)
  def info(lease), do: request(lease, :info)

  def matches?(run, context) do
    with true <- run.source_writer_pending,
         {:ok, lease} <- lookup(run) do
      lease.phase == :held and lease.native_pid == context.coordinator and
        is_pid(lease.native_pid) and Process.alive?(lease.native_pid) and not lease.native_down
    else
      _missing -> false
    end
  end

  def entries do
    Registry.select(@registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  rescue
    ArgumentError -> []
  end

  defp hold(run, origin, owner, request) do
    metadata = %{
      run_id: run.id,
      session_id: run.session_id,
      workspace: run.workspace,
      token: run.source_writer_token,
      origin: origin,
      phase: :acquiring,
      native_pid: nil,
      native_attempted: false,
      native_down: false,
      native_reason: nil,
      stop_acknowledged: false,
      settled: false
    }

    case Registry.register(@registry, run.id, metadata) do
      {:ok, _registry} ->
        result =
          Workspaces.with_workspace_lease(run.workspace, fn ->
            state = %{metadata: %{metadata | phase: :held}, native_monitor: nil}
            publish(state)
            send(owner, {request, {:ok, state.metadata}})
            hold_lease(state)
          end)

        if match?({:error, _}, result), do: send(owner, {request, result})
        Registry.unregister(@registry, run.id)

      {:error, _reason} ->
        send(owner, {request, {:error, :writer_lease_exists}})
    end
  end

  defp hold_lease(state) do
    receive do
      {:writer_lease, from, ref, token, :info} when token == state.metadata.token ->
        send(from, {ref, {:ok, state.metadata}})
        hold_lease(state)

      {:writer_lease, from, ref, token, :begin_native} when token == state.metadata.token ->
        handle_begin_native(state, from, ref)

      {:writer_lease, from, ref, token, {:bind, native_pid}} when token == state.metadata.token ->
        handle_bind(state, from, ref, native_pid)

      {:writer_lease, from, ref, token, {:confirm_stopped, native_pid}}
      when token == state.metadata.token ->
        handle_confirm_stopped(state, from, ref, native_pid)

      {:writer_lease, from, ref, token, :acknowledge_absence}
      when token == state.metadata.token ->
        handle_acknowledge_absence(state, from, ref)

      {:writer_lease, from, ref, token, :release} when token == state.metadata.token ->
        handle_release(state, from, ref)

      {:DOWN, monitor, :process, native_pid, reason} when monitor == state.native_monitor ->
        handle_native_down(state, native_pid, reason)

      _unknown ->
        hold_lease(state)
    end
  end

  defp handle_begin_native(state, from, ref) do
    if is_nil(state.metadata.native_pid) do
      state = %{state | metadata: %{state.metadata | native_attempted: true}}
      publish(state)
      send(from, {ref, :ok})
      hold_lease(state)
    else
      send(from, {ref, {:error, :native_identity_mismatch}})
      hold_lease(state)
    end
  end

  defp handle_bind(state, from, ref, native_pid) do
    allowed = native_binding_allowed?(state.metadata, native_pid)

    cond do
      current_native_alive?(state.metadata, native_pid) ->
        send(from, {ref, :ok})
        hold_lease(state)

      allowed and is_pid(native_pid) and Process.alive?(native_pid) ->
        state = monitor_native(state, native_pid)
        publish(state)
        send(from, {ref, :ok})
        hold_lease(state)

      true ->
        send(from, {ref, {:error, :native_identity_mismatch}})
        hold_lease(state)
    end
  end

  defp native_binding_allowed?(metadata, native_pid) do
    is_nil(metadata.native_pid) or metadata.native_pid == native_pid or
      (metadata.native_down and metadata.settled)
  end

  defp current_native_alive?(metadata, native_pid) do
    metadata.native_pid == native_pid and not metadata.native_down and
      is_pid(native_pid) and Process.alive?(native_pid)
  end

  defp monitor_native(state, native_pid) do
    if state.native_monitor, do: Process.demonitor(state.native_monitor, [:flush])

    metadata = %{
      state.metadata
      | native_pid: native_pid,
        native_attempted: true,
        native_down: false,
        native_reason: nil,
        settled: false,
        stop_acknowledged: false
    }

    %{state | metadata: metadata, native_monitor: Process.monitor(native_pid)}
  end

  defp handle_confirm_stopped(state, from, ref, native_pid) do
    acknowledged =
      state.metadata.native_pid == native_pid and is_pid(native_pid) and
        not Process.alive?(native_pid)

    confirmed =
      acknowledged and state.metadata.native_down and graceful_stop?(state.metadata.native_reason)

    metadata = %{state.metadata | stop_acknowledged: acknowledged, settled: confirmed}
    state = %{state | metadata: metadata}
    publish(state)
    send(from, {ref, if(confirmed, do: :ok, else: {:error, :native_stop_unconfirmed})})
    hold_lease(state)
  end

  defp handle_acknowledge_absence(state, from, ref) do
    if is_nil(state.metadata.native_pid) or not Process.alive?(state.metadata.native_pid) do
      state = %{state | metadata: %{state.metadata | settled: true}}
      publish(state)
      send(from, {ref, :ok})
      hold_lease(state)
    else
      send(from, {ref, {:error, :native_session_active}})
      hold_lease(state)
    end
  end

  defp handle_release(state, from, ref) do
    if state.metadata.settled or is_nil(state.metadata.native_pid) do
      send(from, {ref, :ok})
      :ok
    else
      send(from, {ref, {:error, :native_stop_unconfirmed}})
      hold_lease(state)
    end
  end

  defp handle_native_down(state, native_pid, reason) do
    settled = state.metadata.stop_acknowledged and graceful_stop?(reason)
    metadata = %{state.metadata | native_down: true, native_reason: reason, settled: settled}
    state = %{state | metadata: metadata, native_monitor: nil}
    publish(state)

    if observer = Process.whereis(OhMyJidoDocs.Editor.Observer),
      do: send(observer, {:writer_native_down, metadata.run_id, metadata.token, native_pid})

    hold_lease(state)
  end

  defp graceful_stop?(reason) do
    reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)
  end

  defp publish(state) do
    Registry.update_value(@registry, state.metadata.run_id, fn _previous -> state.metadata end)
  end

  defp request(lease, command) do
    monitor = Process.monitor(lease.pid)
    ref = make_ref()
    send(lease.pid, {:writer_lease, self(), ref, lease.token, command})

    receive do
      {^ref, result} ->
        if command == :release and result == :ok do
          receive do
            {:DOWN, ^monitor, :process, _pid, :normal} -> :ok
            {:DOWN, ^monitor, :process, _pid, _reason} -> {:error, :writer_release_unconfirmed}
          after
            @timeout ->
              Process.demonitor(monitor, [:flush])
              {:error, :writer_release_unconfirmed}
          end
        else
          Process.demonitor(monitor, [:flush])
          result
        end

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :writer_lease_unavailable}
    after
      @timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :writer_lease_unavailable}
    end
  end
end
