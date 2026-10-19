defmodule OhMyJido.Eval.PortOwner do
  @moduledoc false
  use GenServer

  alias OhMyJido.Eval.Bridge

  @max_frame 8_388_608

  def start_link(executable, arguments, workspace, opts) do
    GenServer.start_link(
      __MODULE__,
      {executable, arguments, workspace, Keyword.put(opts, :owner, self())}
    )
  end

  def open(pid, language, workspace, options, timeout) do
    GenServer.call(pid, {:open, language, workspace, options}, timeout)
  end

  def execute(pid, request), do: GenServer.call(pid, {:execute, request}, request.timeout + 1_000)
  def identity(pid), do: GenServer.call(pid, :identity)

  @impl true
  def init({executable, arguments, workspace, opts}) do
    Process.flag(:trap_exit, true)

    {executable, prefix} =
      case executable do
        {path, prefix} -> {path, prefix}
        path -> {path, []}
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        {:line, @max_frame},
        {:args, prefix ++ arguments},
        {:cd, workspace}
      ])

    with {:os_pid, launcher_pid} <- Port.info(port, :os_pid),
         {:ok, launcher_identity} <- OhMyJido.Process.capture_identity(launcher_pid) do
      {:ok,
       %{
         port: port,
         bridge: Keyword.fetch!(opts, :bridge),
         tasks: Keyword.fetch!(opts, :tasks),
         owner: Keyword.fetch!(opts, :owner),
         ready: false,
         opened: false,
         open_from: nil,
         open_message: nil,
         launcher_pid: launcher_pid,
         launcher_identity: launcher_identity,
         lease: nil,
         active: nil,
         callbacks: %{},
         requests: 0
       }}
    else
      _unavailable ->
        Port.close(port)
        {:stop, :launcher_identity_unavailable}
    end
  end

  @impl true
  def handle_call({:open, language, workspace, options}, from, state) do
    message = %{
      op: "open",
      language: Atom.to_string(language),
      workspace: workspace,
      options:
        Map.new(
          Keyword.take(options, [
            :memory_limit,
            :max_stack_size,
            :max_convert_depth,
            :max_convert_nodes,
            :bootstrap
          ])
        )
    }

    state = %{state | open_from: from, open_message: message}
    if state.ready, do: send_frame(state.port, message)
    {:noreply, state}
  end

  def handle_call({:execute, request}, from, %{opened: true, active: nil} = state) do
    wire_request = Map.take(request, [:id, :generation, :source, :timeout, :output_limit])
    send_frame(state.port, %{op: "execute", request: wire_request})
    {:noreply, %{state | active: %{from: from, request: request}, requests: 0}}
  end

  def handle_call({:execute, _request}, _from, state),
    do: {:reply, {:error, :kernel_busy_or_unavailable}, state}

  def handle_call(:identity, _from, state), do: {:reply, state.lease, state}

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    with true <- wire_shape?(line, 0, 0, false, false, 0),
         {:ok, message} when is_map(message) <- Jason.decode(line) do
      handle_frame(message, state)
    else
      false -> protocol_error(state, :json_complexity_limit)
      _invalid -> protocol_error(state, :invalid_json)
    end
  end

  def handle_info({port, {:data, {:noeol, _fragment}}}, %{port: port} = state),
    do: protocol_error(state, :frame_limit)

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: protocol_error(state, {:erts_exit, status})

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: protocol_error(state, {:port_exit, reason})

  def handle_info({ref, value}, state) when is_reference(ref) do
    case Map.pop(state.callbacks, ref) do
      {nil, _callbacks} ->
        {:noreply, state}

      {callback, callbacks} ->
        Process.demonitor(ref, [:flush])
        reply_callback(callback, value, state)

        {:noreply, %{state | callbacks: callbacks}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.callbacks, ref) do
      {nil, _callbacks} ->
        {:noreply, state}

      {callback, callbacks} ->
        send_frame(state.port, %{
          op: "reply",
          id: callback.id,
          result: %{ok: false, error: "bridge_unavailable"}
        })

        {:noreply, %{state | callbacks: callbacks}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.callbacks, fn {_ref, callback} -> Process.exit(callback.task.pid, :kill) end)
    if state.active, do: GenServer.reply(state.active.from, {:error, :erts_closed})
    if state.open_from, do: GenServer.reply(state.open_from, {:error, :erts_closed})
    release_group(state)
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp reply_callback(callback, value, state) do
    if active?(state, callback.generation, callback.execution_id) do
      result = if value == :ok, do: %{ack: true}, else: value
      send_frame(state.port, %{op: "reply", id: callback.id, result: result})
    end
  end

  defp handle_frame(%{"type" => "ready", "os_pid" => pid}, %{ready: false} = state) do
    case bind_identity(pid, state) do
      {:ok, lease} ->
        if state.open_message, do: send_frame(state.port, state.open_message)
        {:noreply, %{state | ready: true, lease: lease}}

      {:error, reason} ->
        protocol_error(state, reason)
    end
  end

  defp handle_frame(%{"type" => "opened"}, %{open_from: from} = state) when not is_nil(from) do
    GenServer.reply(from, {:ok, state.lease})
    {:noreply, %{state | opened: true, open_from: nil, open_message: nil}}
  end

  defp handle_frame(
         %{
           "type" => "result",
           "generation" => generation,
           "execution_id" => id,
           "result" => result
         },
         state
       )
       when is_map(result) do
    if active?(state, generation, id) do
      case result(result) do
        {:ok, result} ->
          GenServer.reply(state.active.from, {:ok, result})
          {:noreply, %{state | active: nil}}

        {:error, reason} ->
          protocol_error(state, reason)
      end
    else
      protocol_error(state, :stale_result)
    end
  end

  defp handle_frame(
         %{
           "type" => "callback",
           "generation" => generation,
           "execution_id" => execution_id,
           "id" => id,
           "operation" => operation,
           "arguments" => arguments
         },
         state
       )
       when is_integer(id) and id >= 0 and is_list(arguments) and is_binary(operation) do
    cond do
      not active?(state, generation, execution_id) ->
        protocol_error(state, :stale_callback)

      state.requests >= 1_024 ->
        protocol_error(state, :bridge_request_limit)

      map_size(state.callbacks) >= 8 ->
        send_frame(state.port, %{op: "reply", id: id, result: %{ok: false, error: "bridge_busy"}})
        {:noreply, %{state | requests: state.requests + 1}}

      true ->
        decoded = operation(operation, arguments)
        bridge = state.bridge
        timeout = state.active.request.timeout + 1_000

        task =
          Task.Supervisor.async_nolink(state.tasks, fn ->
            Bridge.call(bridge, generation, execution_id, decoded, timeout)
          end)

        callback = %{task: task, id: id, generation: generation, execution_id: execution_id}

        {:noreply,
         %{
           state
           | callbacks: Map.put(state.callbacks, task.ref, callback),
             requests: state.requests + 1
         }}
    end
  end

  defp handle_frame(%{"type" => "fatal", "error" => error}, state) when is_binary(error),
    do: protocol_error(state, {:worker_error, error})

  defp handle_frame(_message, state), do: protocol_error(state, :unknown_frame)

  defp operation("tool", [name, parameters]) when is_binary(name) and is_map(parameters),
    do: {:tool, name, parameters}

  defp operation("display", [text]) when is_binary(text), do: {:display, text}

  defp operation("artifact", [name, media_type, encoded]) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, data} -> {:artifact, name, media_type, data}
      :error -> :invalid
    end
  end

  defp operation("output", ["stdout", text, clipped?]) when is_boolean(clipped?),
    do: {:output, :stdout, text, clipped?}

  defp operation("output", ["stderr", text, clipped?]) when is_boolean(clipped?),
    do: {:output, :stderr, text, clipped?}

  defp operation(_operation, _arguments), do: :invalid

  defp active?(%{active: %{request: %{generation: generation, id: id}}}, generation, id), do: true
  defp active?(_state, _generation, _id), do: false

  defp result(%{
         "status" => status,
         "display" => display,
         "diagnostics" => diagnostics,
         "error" => error,
         "truncated" => truncated?
       })
       when status in ["ok", "error", "timeout"] and is_binary(display) and
              is_list(diagnostics) and (is_nil(error) or is_binary(error)) and
              is_boolean(truncated?) do
    if valid_diagnostics?(diagnostics, 100) do
      status = result_status(status)

      {:ok,
       %{
         status: status,
         display: display,
         error: error,
         diagnostics: Enum.map(diagnostics, &diagnostic/1),
         truncated: truncated?
       }}
    else
      {:error, :invalid_diagnostics}
    end
  end

  defp result(_result), do: {:error, :invalid_result}

  defp result_status("ok"), do: :ok
  defp result_status("error"), do: :error
  defp result_status("timeout"), do: :timeout

  defp valid_diagnostics?([], _remaining), do: true

  defp valid_diagnostics?([entry | rest], remaining) when remaining > 0,
    do: valid_diagnostic?(entry) and valid_diagnostics?(rest, remaining - 1)

  defp valid_diagnostics?(_entries, _remaining), do: false

  defp valid_diagnostic?(%{"severity" => severity, "message" => message, "line" => line}),
    do:
      severity in ["warning", "error"] and is_binary(message) and
        (is_nil(line) or is_integer(line))

  defp valid_diagnostic?(_entry), do: false

  defp diagnostic(%{"severity" => severity, "message" => message, "line" => line}) do
    %{
      severity: if(severity == "warning", do: :warning, else: :error),
      message: message,
      line: line
    }
  end

  defp bind_identity(text, state) when is_binary(text) and byte_size(text) <= 20 do
    with {pid, ""} when pid > 1 <- Integer.parse(text),
         {:ok, child} <- OhMyJido.Process.capture_identity(pid),
         true <- descends_from?(pid, child, state.launcher_pid, state.launcher_identity.start, 32),
         {leader, ""} when leader > 1 <- Integer.parse(child.group),
         true <- child.session == child.group,
         {:ok, identity} <-
           if(leader == pid, do: {:ok, child}, else: OhMyJido.Process.capture_identity(leader)),
         true <- identity.group == child.group and identity.session == child.session,
         true <-
           descends_from?(leader, identity, state.launcher_pid, state.launcher_identity.start, 32) do
      {:ok, %{os_pid: leader, os_identity: identity}}
    else
      _unmapped -> {:error, :unmapped_erts_identity}
    end
  end

  defp bind_identity(_pid, _state), do: {:error, :unmapped_erts_identity}

  defp descends_from?(pid, identity, pid, start, _remaining), do: identity.start == start
  defp descends_from?(_pid, _identity, _ancestor, _start, 0), do: false

  defp descends_from?(_pid, identity, ancestor, start, remaining) do
    with {parent, ""} when parent > 1 <- Integer.parse(identity.parent),
         {:ok, next} <- OhMyJido.Process.capture_identity(parent) do
      descends_from?(parent, next, ancestor, start, remaining - 1)
    else
      _unavailable -> false
    end
  end

  defp release_group(%{lease: %{os_pid: pid, os_identity: identity}}),
    do: OhMyJido.Process.terminate_group(pid, identity)

  defp release_group(state) do
    pid = state.launcher_pid

    with {:ok, identity} <- OhMyJido.Process.capture_identity(pid),
         true <- identity.start == state.launcher_identity.start,
         true <- identity.group == Integer.to_string(pid) and identity.session == identity.group do
      OhMyJido.Process.terminate_group(pid, identity)
    else
      _unavailable -> {:error, :cleanup_uncertain}
    end
  end

  defp wire_shape?(_bytes, depth, nodes, _quoted, _escaped, token)
       when depth < 0 or depth > 32 or nodes > 32_768 or token > 128, do: false

  defp wire_shape?(<<>>, 0, _nodes, false, false, _token), do: true
  defp wire_shape?(<<>>, _depth, _nodes, _quoted, _escaped, _token), do: false

  defp wire_shape?(<<_byte, rest::binary>>, depth, nodes, true, true, _token),
    do: wire_shape?(rest, depth, nodes, true, false, 0)

  defp wire_shape?(<<92, rest::binary>>, depth, nodes, true, false, _token),
    do: wire_shape?(rest, depth, nodes, true, true, 0)

  defp wire_shape?(<<34, rest::binary>>, depth, nodes, true, false, _token),
    do: wire_shape?(rest, depth, nodes, false, false, 0)

  defp wire_shape?(<<_byte, rest::binary>>, depth, nodes, true, false, _token),
    do: wire_shape?(rest, depth, nodes, true, false, 0)

  defp wire_shape?(<<34, rest::binary>>, depth, nodes, false, false, _token),
    do: wire_shape?(rest, depth, nodes + 1, true, false, 0)

  defp wire_shape?(<<byte, rest::binary>>, depth, nodes, false, false, _token)
       when byte in [123, 91],
       do: wire_shape?(rest, depth + 1, nodes + 1, false, false, 0)

  defp wire_shape?(<<byte, rest::binary>>, depth, nodes, false, false, _token)
       when byte in [125, 93],
       do: wire_shape?(rest, depth - 1, nodes, false, false, 0)

  defp wire_shape?(<<byte, rest::binary>>, depth, nodes, false, false, _token)
       when byte in [44, 58],
       do: wire_shape?(rest, depth, nodes + 1, false, false, 0)

  defp wire_shape?(<<byte, rest::binary>>, depth, nodes, false, false, _token)
       when byte in [9, 10, 13, 32],
       do: wire_shape?(rest, depth, nodes, false, false, 0)

  defp wire_shape?(<<_byte, rest::binary>>, depth, nodes, false, false, token),
    do: wire_shape?(rest, depth, nodes, false, false, token + 1)

  defp protocol_error(state, reason) do
    if state.active, do: GenServer.reply(state.active.from, {:error, {:erts_protocol, reason}})
    if state.open_from, do: GenServer.reply(state.open_from, {:error, {:erts_protocol, reason}})
    {:stop, :normal, %{state | active: nil, open_from: nil}}
  end

  defp send_frame(port, message) do
    encoded = Jason.encode!(message)
    if byte_size(encoded) >= @max_frame, do: raise(ArgumentError, "Eval frame limit")
    true = Port.command(port, [encoded, "\n"])
    :ok
  end
end
