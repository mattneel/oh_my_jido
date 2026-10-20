defmodule OhMyJido.Eval.Bridge do
  @moduledoc false
  use GenServer

  alias OhMyJido.{Context, Redact, Tool}
  alias OhMyJido.Eval.Output

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def activate(server, context, request) do
    GenServer.call(server, {:activate, context, request})
  end

  def finish(server, result), do: GenServer.call(server, {:finish, result})
  def invalidate(server), do: GenServer.call(server, :invalidate)

  def track_python(server, worker_id, session_id \\ nil),
    do: GenServer.call(server, {:track_python, worker_id, session_id})

  def python_sessions(server, worker_id),
    do: GenServer.call(server, {:python_sessions, worker_id})

  def forget_python(server, worker_id), do: GenServer.cast(server, {:forget_python, worker_id})

  def call(server, generation, execution_id, operation, timeout \\ 5_000) do
    GenServer.call(server, {:request, generation, execution_id, operation}, timeout)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       tasks: Keyword.fetch!(opts, :tasks),
       callback_timeout: Keyword.get(opts, :callback_timeout, 2_000),
       active: nil,
       output: Output.new(1),
       callbacks: %{},
       uncertain: false,
       interruption: nil,
       python_workers: %{}
     }}
  end

  @impl true
  def handle_cast({:forget_python, worker_id}, state),
    do: {:noreply, %{state | python_workers: Map.delete(state.python_workers, worker_id)}}

  @impl true
  def handle_call({:worker_ready, _worker_id}, _from, state), do: {:reply, :ok, state}

  def handle_call({:track_python, worker_id, session_id}, _from, state) do
    workers =
      Map.put(
        state.python_workers,
        worker_id,
        session_id || Map.get(state.python_workers, worker_id)
      )

    {:reply, :ok, %{state | python_workers: workers}}
  end

  def handle_call({:python_sessions, worker_id}, _from, state),
    do: {:reply, List.wrap(Map.get(state.python_workers, worker_id)), state}

  def handle_call({:activate, context, request}, _from, state) do
    state = stop_callbacks(state)

    case host_secrets(context) do
      {:ok, secrets} ->
        active = %{
          context: context,
          request: request,
          deadline: Map.get(request, :deadline, now() + request.timeout)
        }

        {:reply, :ok,
         %{
           state
           | active: active,
             output: Output.new(request.output_limit, secrets),
             uncertain: false,
             interruption: nil
         }}

      {:error, reason} ->
        {:reply, {:error, {:redaction_unavailable, reason}}, %{state | active: nil}}
    end
  end

  def handle_call(:invalidate, _from, state) do
    state = stop_callbacks(state)
    {:reply, :ok, %{state | active: nil}}
  end

  def handle_call({:finish, result}, _from, state) do
    state = stop_callbacks(state)

    output = %{
      state.output
      | truncated: state.output.truncated or Map.get(result, :truncated, false)
    }

    {output, events} = Output.flush(output)
    Enum.each(events, fn {stream, text} -> emit_output(state.active, stream, text) end)
    output = Output.diagnostics(output, Map.get(result, :diagnostics, []))
    {output, _piece} = Output.text(output, :display, Map.get(result, :display, ""))

    output =
      case Map.get(result, :error) do
        nil ->
          output

        error ->
          text =
            if is_binary(error),
              do: error,
              else: Output.inspect_value(error, max(output.remaining, 1))

          {next, _piece} = Output.text(output, :error, text)
          next
      end

    finished = Map.merge(result, Output.finish(output))

    finished =
      Map.put(
        finished,
        :effects,
        if(state.uncertain, do: :uncertain, else: Map.get(result, :effects, :completed))
      )

    finished =
      if state.interruption == :callback_timeout,
        do: Map.put(finished, :status, :timeout),
        else: finished

    {:reply, finished, %{state | output: output, active: nil}}
  end

  def handle_call({:request, generation, id, operation}, from, state) do
    dispatch(generation, id, operation, {:call, from}, state)
  end

  @impl true
  def handle_info({:io_request, from, ref, {:omj_eval, generation, id, operation}}, state) do
    case dispatch(generation, id, operation, {:io, from, ref}, state) do
      {:noreply, next} ->
        {:noreply, next}

      {:reply, reply, next} ->
        send(from, {:io_reply, ref, reply})
        {:noreply, next}
    end
  end

  def handle_info({:io_request, from, ref, _boot_or_unattributed_io}, state) do
    send(from, {:io_reply, ref, :ok})
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.callbacks, ref) do
      {nil, _callbacks} ->
        {:noreply, state}

      {callback, callbacks} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(callback.timer)
        state = %{state | callbacks: callbacks}

        if now() >= callback.deadline do
          {:noreply, callback_expired(callback, state)}
        else
          reply(callback.from, wire_result(result, state))
          {:noreply, state}
        end
    end
  end

  def handle_info({:callback_deadline, ref}, state) do
    case Map.pop(state.callbacks, ref) do
      {nil, _callbacks} ->
        {:noreply, state}

      {callback, callbacks} ->
        Process.exit(callback.task.pid, :kill)
        Process.demonitor(ref, [:flush])
        {:noreply, callback_expired(callback, %{state | callbacks: callbacks})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.callbacks, ref) do
      {nil, _callbacks} ->
        {:noreply, state}

      {callback, callbacks} ->
        Process.cancel_timer(callback.timer)
        reply(callback.from, failure({:callback_failed, reason}))
        {:noreply, %{state | callbacks: callbacks, uncertain: true}}
    end
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_callbacks(state)

    Enum.each(state.python_workers, fn {id, session} ->
      OhMyJido.Eval.Python.release_worker(id, List.wrap(session))
    end)

    :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp dispatch(generation, id, operation, from, state) do
    if active?(state, generation, id) do
      operation(operation, from, state)
    else
      respond(from, failure(:stale_execution), state)
    end
  end

  defp operation({:output, stream, text, clipped?}, from, state)
       when stream in [:stdout, :stderr] and is_binary(text) do
    {output, piece} = Output.text(state.output, stream, text)
    output = %{output | truncated: output.truncated or clipped?}
    emit_output(state.active, stream, piece)
    respond(from, :ok, %{state | output: output})
  end

  defp operation({:display, text}, from, state) when is_binary(text) do
    {output, piece} = Output.text(state.output, :displays, text)
    emit_output(state.active, :display, piece)
    respond(from, :ok, %{state | output: output})
  end

  defp operation({:artifact, name, media_type, data}, from, state) do
    case Output.artifact(state.output, name, media_type, data) do
      {:ok, output} -> respond(from, :ok, %{state | output: output})
      {:error, reason, output} -> respond(from, failure(reason), %{state | output: output})
    end
  end

  defp operation({:tool, name, parameters}, from, state)
       when is_binary(name) and is_map(parameters) do
    context = state.active.context
    request = state.active.request
    limit = min(state.callback_timeout, max(state.active.deadline - now(), 1))
    deadline = now() + limit

    with true <- byte_size(name) <= 128,
         {:ok, parameters} <- Output.structured(parameters, request.output_limit),
         {:ok, action} <- Tool.find(context, name),
         true <- action != OhMyJido.Tools.Eval,
         :ok <- allowed_tool(context, action),
         true <- map_size(state.callbacks) < 8 do
      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          execute_tool(context, name, parameters, deadline)
        end)

      Process.link(task.pid)
      timer = Process.send_after(self(), {:callback_deadline, task.ref}, max(deadline - now(), 0))
      callback = %{task: task, timer: timer, from: from, deadline: deadline}
      {:noreply, %{state | callbacks: Map.put(state.callbacks, task.ref, callback)}}
    else
      false -> respond(from, failure(:tool_denied), state)
      {:error, reason} -> respond(from, failure(reason), state)
    end
  end

  defp operation(_operation, from, state),
    do: respond(from, failure(:invalid_bridge_request), state)

  defp allowed_tool(context, action) do
    capability =
      if function_exported?(action, :capability, 0), do: action.capability(), else: :custom

    if Context.permitted?(context, capability),
      do: :ok,
      else: {:error, {:permission_denied, capability}}
  end

  defp execute_tool(context, name, parameters, deadline) do
    # Native V3 Exec monitors this supervised bridge task and cancels its
    # workers when the caller exits. Zero means no dispatch, not inline work.
    remaining = deadline - now()

    if remaining > 0,
      do: Tool.execute(context, name, parameters, timeout: remaining),
      else: {:error, :callback_timeout}
  end

  defp wire_result({:ok, result}, state) do
    result = Redact.sanitize(result, state.output.secrets, state.output.remaining)

    case Output.structured(result, state.output.remaining) do
      {:ok, result} -> %{"ok" => true, "result" => result}
      {:error, reason} -> failure(reason)
    end
  end

  defp wire_result({:error, reason}, state),
    do: failure(Redact.sanitize(reason, state.output.secrets, state.output.remaining))

  defp wire_result(other, state),
    do:
      failure(
        Redact.sanitize(
          {:invalid_tool_result, other},
          state.output.secrets,
          state.output.remaining
        )
      )

  defp callback_expired(callback, state) do
    reply(callback.from, failure(:callback_timeout))
    %{request: request} = state.active
    send(state.owner, {:callback_timeout, request.generation, request.id})
    %{state | uncertain: true, interruption: :callback_timeout}
  end

  defp active?(
         %{active: %{request: %{generation: generation, id: id}, deadline: deadline}},
         generation,
         id
       ),
       do: now() < deadline

  defp active?(_state, _generation, _id), do: false

  defp stop_callbacks(state) do
    Enum.each(state.callbacks, fn {ref, callback} ->
      Process.cancel_timer(callback.timer)
      Process.exit(callback.task.pid, :kill)
      Process.demonitor(ref, [:flush])
      reply(callback.from, failure(:execution_finished))
    end)

    %{state | callbacks: %{}, uncertain: state.uncertain or map_size(state.callbacks) > 0}
  end

  defp host_secrets(%{coordinator: nil} = context),
    do: {:ok, Map.get(context.metadata, :secrets, [])}

  defp host_secrets(context) do
    case OhMyJido.Session.redaction_secrets(context.coordinator) do
      {:ok, secrets} -> {:ok, Enum.uniq(secrets ++ Map.get(context.metadata, :secrets, []))}
      {:error, _reason} = error -> error
    end
  end

  defp emit_output(nil, _stream, _text), do: :ok
  defp emit_output(_active, _stream, ""), do: :ok

  defp emit_output(%{context: context, request: request}, stream, text) do
    if is_pid(context.coordinator) do
      send(context.coordinator, {:eval_output, context.session_id, request.id, stream, text})
    end
  end

  defp respond({:call, _from}, value, state), do: {:reply, value, state}

  defp respond({:io, _pid, _ref} = from, value, state) do
    reply(from, value)
    {:noreply, state}
  end

  defp reply({:call, from}, value), do: GenServer.reply(from, value)
  defp reply({:io, pid, ref}, value), do: send(pid, {:io_reply, ref, value})

  defp failure(reason),
    do: %{"ok" => false, "error" => inspect(reason, limit: 20, printable_limit: 512)}

  defp now, do: System.monotonic_time(:millisecond)
end
