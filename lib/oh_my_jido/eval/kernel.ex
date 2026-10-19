defmodule OhMyJido.Eval.Kernel do
  @moduledoc false
  use GenServer, restart: :temporary, shutdown: 30_000

  alias OhMyJido.Eval.Bridge

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def execute(pid, context, source, opts),
    do: GenServer.call(pid, {:execute, context, source, opts}, :infinity)

  def interrupt(pid), do: GenServer.call(pid, :interrupt, :infinity)
  def interrupt(pid, execution_id), do: GenServer.call(pid, {:interrupt, execution_id}, :infinity)
  def reset(pid), do: GenServer.call(pid, :reset, :infinity)
  def info(pid), do: GenServer.call(pid, :info)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    backend = Keyword.fetch!(opts, :backend)
    generation = Keyword.get(opts, :generation, 1)

    {:ok, bridge} =
      Bridge.start_link(
        owner: self(),
        tasks: Keyword.fetch!(opts, :tasks),
        callback_timeout: Keyword.get(opts, :callback_timeout, 2_000)
      )

    context = Keyword.fetch!(opts, :context)

    backend_opts =
      opts
      |> Keyword.fetch!(:backend_opts)
      |> Keyword.merge(
        bridge: bridge,
        tasks: Keyword.fetch!(opts, :tasks),
        generation: generation,
        callback_timeout: Keyword.get(opts, :callback_timeout, 2_000)
      )

    case backend.open(Keyword.fetch!(opts, :context), backend_opts) do
      {:ok, handle} ->
        monitor = Process.monitor(handle.worker)

        {:ok,
         %{
           backend: backend,
           handle: handle,
           bridge: bridge,
           tasks: Keyword.fetch!(opts, :tasks),
           context: context,
           server: Keyword.fetch!(opts, :server),
           language: Keyword.fetch!(opts, :language),
           coordinator_monitor:
             if(is_pid(context.coordinator), do: Process.monitor(context.coordinator)),
           generation: generation,
           monitor: monitor,
           status: :ready,
           reason: nil,
           execution: nil,
           last_used: now(),
           limits: Keyword.get(opts, :limits, [])
         }}

      {:error, reason} ->
        GenServer.stop(bridge)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:execute, _context, _source, _opts}, _from, %{status: :invalidated} = state),
    do: {:reply, {:error, {:kernel_invalidated, state.reason}}, state}

  def handle_call({:execute, _context, _source, _opts}, _from, %{status: :busy} = state),
    do: {:reply, {:error, :kernel_busy}, state}

  def handle_call({:execute, context, source, opts}, from, state) do
    with true <- Process.alive?(state.handle.worker),
         true <- context.workspace == state.context.workspace,
         {:ok, request} <- request(source, opts, state),
         {:ok, resource} <- prepare_execution(context, state, request) do
      backend = state.backend
      handle = state.handle

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          execute_backend(backend, handle, request)
        end)

      timer =
        Process.send_after(
          self(),
          {:deadline, request.generation, request.id},
          max(request.deadline - now(), 0)
        )

      caller_monitor = Process.monitor(elem(from, 0))

      execution = %{
        task: task,
        timer: timer,
        from: from,
        request: request,
        caller_monitor: caller_monitor,
        resource: resource,
        started_at: now()
      }

      {:noreply,
       %{state | status: :busy, execution: execution, context: context, last_used: now()}}
    else
      false ->
        reason = if Process.alive?(state.handle.worker), do: :session_mismatch, else: :worker_down
        state = if reason == :worker_down, do: invalidate(state, reason, :crashed), else: state
        error = if reason == :worker_down, do: {:kernel_invalidated, reason}, else: reason
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:interrupt, id}, _from, %{execution: %{request: %{id: id}}} = state),
    do: {:reply, :ok, invalidate(state, :cancelled, :cancelled)}

  def handle_call({:interrupt, _stale_id}, _from, state),
    do: {:reply, {:error, :stale_execution}, state}

  def handle_call(:interrupt, _from, %{status: :busy} = state),
    do: {:reply, :ok, invalidate(state, :cancelled, :cancelled)}

  def handle_call(:interrupt, _from, state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    state = if state.execution, do: invalidate(state, :reset, :cancelled), else: state
    Bridge.invalidate(state.bridge)
    Process.demonitor(state.monitor, [:flush])

    case state.backend.reset(state.handle) do
      {:ok, handle} ->
        next = %{
          state
          | handle: handle,
            generation: state.generation + 1,
            monitor: Process.monitor(handle.worker),
            status: :ready,
            reason: nil,
            last_used: now()
        }

        {:reply, {:ok, snapshot(next)}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | status: :invalidated, reason: reason}}
    end
  end

  @impl true
  def handle_info({ref, result}, %{execution: %{task: %{ref: ref}}} = state) do
    execution = state.execution

    if now() >= execution.request.deadline do
      {:noreply, invalidate(state, :timeout, :timeout)}
    else
      finish_result(result, state, execution)
    end
  end

  def handle_info(
        {:deadline, generation, id},
        %{generation: generation, execution: %{request: %{id: id}}} = state
      ),
      do: {:noreply, invalidate(state, :timeout, :timeout)}

  def handle_info(
        {:callback_timeout, generation, id},
        %{generation: generation, execution: %{request: %{id: id}}} = state
      ),
      do: {:noreply, invalidate(state, :callback_timeout, :timeout)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{coordinator_monitor: ref} = state)
      when is_reference(ref),
      do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state),
    do: {:noreply, invalidate(state, {:worker_down, reason}, :crashed)}

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{execution: %{task: %{ref: ref}}} = state
      ),
      do: {:noreply, invalidate(state, {:execution_down, reason}, :crashed)}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{execution: %{caller_monitor: ref}} = state
      ),
      do: {:noreply, invalidate(state, :caller_down, :cancelled)}

  def handle_info({:EXIT, bridge, reason}, %{bridge: bridge} = state),
    do: {:stop, {:bridge_down, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  @impl true
  def terminate(_reason, state) do
    try do
      cond do
        state.execution && Process.alive?(state.bridge) ->
          invalidate(state, :closed, :cancelled)

        state.execution ->
          finish_execution(state.execution)
          Process.exit(state.execution.task.pid, :kill)
          GenServer.reply(state.execution.from, {:error, {:kernel_invalidated, :bridge_down}})

        true ->
          :ok
      end

      if Process.alive?(state.bridge), do: Bridge.invalidate(state.bridge)
    after
      state.backend.close(state.handle)
      if Process.alive?(state.bridge), do: GenServer.stop(state.bridge)
    end

    :ok
  end

  defp execute_backend(backend, handle, request) do
    if now() < request.deadline,
      do: backend.execute(handle, request),
      else: {:ok, %{status: :timeout}}
  end

  defp finish_result({:ok, %{status: status} = result}, state, execution)
       when status in [:ok, :error] do
    result = complete_result(state, result, :ready)
    finish_execution(execution)

    if result.effects == :uncertain do
      cleanup = state.backend.interrupt(state.handle, execution.request.id)
      result = Map.merge(result, %{kernel_state: :invalidated, cleanup: cleanup_state(cleanup)})
      GenServer.reply(execution.from, {:ok, result})

      {:noreply,
       %{
         state
         | status: :invalidated,
           reason: :unfinished_callback,
           execution: nil,
           last_used: now()
       }}
    else
      GenServer.reply(execution.from, {:ok, result})
      {:noreply, %{state | status: :ready, execution: nil, last_used: now()}}
    end
  end

  defp finish_result({:ok, %{status: :timeout}}, state, _execution),
    do: {:noreply, invalidate(state, :timeout, :timeout)}

  defp finish_result({:error, reason}, state, _execution),
    do: {:noreply, invalidate(state, reason, :crashed)}

  defp finish_result(other, state, _execution),
    do: {:noreply, invalidate(state, {:invalid_backend_result, other}, :crashed)}

  defp invalidate(%{status: :invalidated} = state, _reason, _status), do: state

  defp invalidate(state, reason, status) do
    Bridge.invalidate(state.bridge)

    cleanup =
      state.backend.interrupt(state.handle, if(state.execution, do: state.execution.request.id))

    if state.execution do
      execution = state.execution
      finish_execution(execution)
      Process.exit(execution.task.pid, :kill)

      result =
        complete_result(
          state,
          %{
            status: status,
            error: reason,
            display: "",
            effects: :uncertain,
            cleanup: cleanup_state(cleanup)
          },
          :invalidated
        )

      GenServer.reply(execution.from, {:ok, result})
    end

    %{state | status: :invalidated, reason: reason, execution: nil, last_used: now()}
  end

  defp cleanup_state(:ok), do: :confirmed
  defp cleanup_state(_uncertain), do: :uncertain

  defp complete_result(state, result, kernel_state) do
    result = Bridge.finish(state.bridge, result)

    Map.merge(result, %{
      generation: state.generation,
      execution_id: state.execution.request.id,
      kernel_state: kernel_state,
      duration_ms: now() - state.execution.started_at
    })
  end

  defp request(source, opts, state) when is_binary(source) do
    timeout = Keyword.get(opts, :timeout, Keyword.get(state.limits, :timeout, 30_000))
    output = Keyword.get(opts, :output_limit, Keyword.get(state.limits, :output_limit, 65_536))
    max_timeout = Keyword.get(state.limits, :max_timeout, 120_000)
    max_output = Keyword.get(state.limits, :max_output_limit, 1_048_576)
    max_source = Keyword.get(state.limits, :source_limit, 262_144)
    cell_id = Keyword.get(opts, :cell_id)
    id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    if valid_limit?(timeout, max_timeout) and valid_limit?(output, max_output) and
         valid_cell_id?(cell_id) and byte_size(source) <= max_source and String.valid?(source) do
      {:ok,
       %{
         id: id,
         cell_id: cell_id,
         source: source,
         timeout: timeout,
         output_limit: output,
         generation: state.generation,
         deadline: now() + timeout
       }}
    else
      {:error, :invalid_eval_request}
    end
  end

  defp request(_source, _opts, _state), do: {:error, :invalid_eval_request}

  defp valid_limit?(value, maximum),
    do: is_integer(value) and value > 0 and value <= maximum

  defp valid_cell_id?(nil), do: true

  defp valid_cell_id?(cell_id) when is_binary(cell_id),
    do: byte_size(cell_id) in 1..128 and String.valid?(cell_id)

  defp valid_cell_id?(_cell_id), do: false

  defp finish_execution(execution) do
    Process.cancel_timer(execution.timer)
    Process.demonitor(execution.task.ref, [:flush])
    Process.demonitor(execution.caller_monitor, [:flush])
    unregister_resource(execution.resource)
  end

  defp prepare_execution(context, state, request) do
    with {:ok, resource} <- register_resource(context, state, request) do
      case Bridge.activate(state.bridge, context, request) do
        :ok ->
          {:ok, resource}

        {:error, _reason} = error ->
          unregister_resource(resource)
          error
      end
    end
  end

  defp register_resource(%{coordinator: nil}, _state, _request), do: {:ok, nil}

  defp register_resource(context, state, request) do
    handle = %{
      runtime: state.server,
      controller: self(),
      session_id: context.session_id,
      language: state.language,
      execution_id: request.id,
      generation: request.generation
    }

    case OhMyJido.Session.register_resource(context.coordinator, context.run_id, :eval, handle) do
      {:ok, key} -> {:ok, {context.coordinator, key}}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:resource_registration_failed, reason}}
  end

  defp unregister_resource(nil), do: :ok

  defp unregister_resource({coordinator, key}),
    do: OhMyJido.Session.unregister_resource(coordinator, key)

  defp snapshot(state) do
    %{
      controller: self(),
      worker: state.handle.worker,
      generation: state.generation,
      status: state.status,
      reason: state.reason,
      last_used: state.last_used
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
