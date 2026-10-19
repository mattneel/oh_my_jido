defmodule OhMyJido.Eval.PortKernel do
  @moduledoc false
  use GenServer

  alias OhMyJido.Eval.{Output, PeerIO, PeerKernel}

  @max_frame 8_388_608
  @stdio_limit 65_536

  # OTP's -user callback registers the native IO server during kernel boot.
  # No distribution or arbitrary origin destination is installed.
  def start do
    {:ok, pid} = GenServer.start_link(__MODULE__, :stdio)
    pid
  end

  @impl true
  def init(:stdio) do
    Process.flag(:trap_exit, true)
    port = Port.open({:fd, 0, 1}, [:binary, :eof, {:line, @max_frame}])
    Process.register(self(), :user)
    Process.group_leader(self(), self())
    {:ok, stderr} = PeerIO.start_link(self(), :stdio, :stderr)
    if Process.whereis(:standard_error), do: Process.unregister(:standard_error)
    Process.register(stderr, :standard_error)
    if :init.notify_when_started(self()) == :started, do: send(self(), {:init, :started})

    {:ok, %{port: port, kernel: nil, active: nil, pending: %{}, sequence: 0, stdio: new_stdio()}}
  end

  @impl true
  def handle_info({:init, :started}, state) do
    owner = self()

    spawn_link(fn ->
      {:ok, _applications} = :application.ensure_all_started(:elixir)
      send(owner, :elixir_ready)
    end)

    {:noreply, state}
  end

  def handle_info(:elixir_ready, state) do
    frame(state.port, %{type: "ready", os_pid: System.pid()})
    {:noreply, state}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, message} -> command(message, state)
      _invalid -> halt(state, :invalid_json)
    end
  end

  def handle_info({port, {:data, {:noeol, _fragment}}}, %{port: port} = state),
    do: halt(state, :frame_limit)

  def handle_info({port, :eof}, %{port: port} = _state), do: :erlang.halt(0)
  def handle_info({:EXIT, port, _reason}, %{port: port} = _state), do: :erlang.halt(0)

  def handle_info({:opened, {:ok, kernel}}, state) do
    Process.monitor(kernel)
    frame(state.port, %{type: "opened"})
    {:noreply, %{state | kernel: kernel}}
  end

  def handle_info({:opened, {:error, reason}}, state), do: halt(state, reason)

  def handle_info(
        {:evaluated, generation, id, {:ok, result}},
        %{active: %{generation: generation, id: id} = request} = state
      ) do
    case state.stdio do
      %{stdout: [], stderr: [], truncated: false} ->
        complete(state, request, result)

      stdio ->
        owner = self()

        spawn_link(fn ->
          flush_stdio(owner, request, stdio)
          send(owner, {:completed, generation, id, result})
        end)

        {:noreply, %{state | stdio: new_stdio()}}
    end
  end

  def handle_info(
        {:completed, generation, id, result},
        %{active: %{generation: generation, id: id} = request} = state
      ),
      do: complete(state, request, result)

  def handle_info({:evaluated, _generation, _id, error}, state), do: halt(state, error)

  def handle_info({:io_request, from, ref, {:omj_eval, generation, id, operation}}, state) do
    if active?(state, generation, id) and map_size(state.pending) < 8 do
      case operation(operation) do
        {:ok, name, arguments} ->
          sequence = state.sequence + 1

          frame(state.port, %{
            type: "callback",
            generation: generation,
            execution_id: id,
            id: sequence,
            operation: name,
            arguments: arguments
          })

          {:noreply,
           %{state | sequence: sequence, pending: Map.put(state.pending, sequence, {from, ref})}}

        {:error, reason} ->
          send(from, {:io_reply, ref, %{"ok" => false, "error" => Atom.to_string(reason)}})
          {:noreply, state}
      end
    else
      send(from, {:io_reply, ref, %{"ok" => false, "error" => "stale_or_busy_execution"}})
      {:noreply, state}
    end
  end

  # Elixir.start/2 configures standard IO before its application can start.
  # Rejecting setopts also makes OTP's logger fall back to raw OS stderr,
  # corrupting the JSON channel. Keep ordinary native IO separate from control,
  # then deliver its bounded output through the active cell's existing bridge.
  def handle_info({:io_request, from, ref, {:omj_stdio, stream, request}}, state)
      when stream in [:stdout, :stderr] do
    {reply, state} = stdio_request(request, stream, state)
    send(from, {:io_reply, ref, reply})
    {:noreply, state}
  end

  def handle_info({:io_request, from, ref, request}, state) do
    {reply, state} = stdio_request(request, :stdout, state)
    send(from, {:io_reply, ref, reply})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, kernel, reason}, %{kernel: kernel} = state),
    do: halt(state, reason)

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: halt(state, reason)
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp command(
         %{
           "op" => "open",
           "language" => language,
           "workspace" => workspace,
           "options" => options
         },
         %{kernel: nil} = state
       )
       when is_binary(workspace) and is_map(options) do
    case language(language) do
      {:ok, language} ->
        opts = kernel_options(options)
        owner = self()

        spawn_link(fn ->
          send(
            owner,
            {:opened, PeerKernel.start(language, Keyword.put(opts, :workspace, workspace))}
          )
        end)

        {:noreply, state}

      {:error, reason} ->
        halt(state, reason)
    end
  end

  defp command(
         %{
           "op" => "execute",
           "request" => %{
             "id" => id,
             "generation" => generation,
             "source" => source,
             "timeout" => timeout,
             "output_limit" => output_limit
           }
         },
         %{kernel: kernel, active: nil} = state
       )
       when is_pid(kernel) and is_binary(id) and is_integer(generation) and is_binary(source) and
              is_integer(timeout) and timeout > 0 and is_integer(output_limit) and
              output_limit > 0 do
    request = %{
      id: id,
      generation: generation,
      source: source,
      timeout: timeout,
      output_limit: output_limit
    }

    owner = self()
    stdio = state.stdio

    spawn_link(fn ->
      flush_stdio(owner, request, stdio)
      send(owner, {:evaluated, generation, id, PeerKernel.execute(kernel, request)})
    end)

    {:noreply, %{state | active: request, stdio: new_stdio()}}
  end

  defp command(%{"op" => "reply", "id" => id, "result" => result}, state) when is_integer(id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        halt(state, :unknown_callback)

      {{from, ref}, pending} ->
        value = if result == %{"ack" => true}, do: :ok, else: result
        send(from, {:io_reply, ref, value})
        {:noreply, %{state | pending: pending}}
    end
  end

  defp command(_message, state), do: halt(state, :unknown_operation)

  defp kernel_options(options) do
    Enum.flat_map(
      [
        {:bootstrap, "bootstrap"},
        {:memory_limit, "memory_limit"},
        {:max_stack_size, "max_stack_size"},
        {:max_convert_depth, "max_convert_depth"},
        {:max_convert_nodes, "max_convert_nodes"}
      ],
      fn {key, name} ->
        case Map.fetch(options, name) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end
    )
  end

  defp operation({:tool, name, parameters}) when is_binary(name) and is_map(parameters) do
    case Output.structured(parameters, 1_048_576) do
      {:ok, parameters} -> {:ok, "tool", [name, parameters]}
      {:error, _reason} -> {:error, :non_structured_value}
    end
  end

  defp operation({:display, text}) when is_binary(text), do: {:ok, "display", [text]}

  defp operation({:artifact, name, media_type, data})
       when is_binary(name) and is_binary(media_type) and is_binary(data),
       do: {:ok, "artifact", [name, media_type, Base.encode64(data)]}

  defp operation({:output, stream, text, clipped?})
       when stream in [:stdout, :stderr] and is_binary(text) and is_boolean(clipped?),
       do: {:ok, "output", [Atom.to_string(stream), text, clipped?]}

  defp operation(_operation), do: {:error, :unknown_bridge_operation}

  defp complete(state, request, result) do
    frame(state.port, %{
      type: "result",
      generation: request.generation,
      execution_id: request.id,
      result: result(result, request.output_limit)
    })

    {:noreply, %{state | active: nil}}
  end

  defp result(result, limit) do
    diagnostics =
      result
      |> Map.get(:diagnostics, [])
      |> Enum.take(100)
      |> Enum.map(fn entry ->
        position = Map.get(entry, :position)

        line =
          case position do
            {line, _column} when is_integer(line) -> line
            line when is_integer(line) -> line
            _other -> nil
          end

        %{
          severity: Map.get(entry, :severity, :error),
          message: Map.get(entry, :message, ""),
          line: line
        }
      end)

    output = Output.new(limit) |> Output.diagnostics(diagnostics)
    output = %{output | truncated: output.truncated or Map.get(result, :truncated, false)}
    {output, _piece} = Output.text(output, :display, Map.get(result, :display, ""))

    output =
      case Map.get(result, :error) do
        nil -> output
        error -> Output.text(output, :error, error) |> elem(0)
      end

    output
    |> Output.finish()
    |> Map.take([:display, :error, :diagnostics, :truncated])
    |> Map.put(:status, Map.fetch!(result, :status))
  end

  defp language("elixir"), do: {:ok, :elixir}
  defp language("javascript"), do: {:ok, :javascript}
  defp language(_language), do: {:error, :unsupported_language}

  defp active?(%{active: %{generation: generation, id: id}}, generation, id), do: true
  defp active?(_state, _generation, _id), do: false

  defp stdio_request({:requests, requests}, stream, state) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {_reply, acc} ->
      case stdio_request(request, stream, acc) do
        {{:error, _reason}, _state} = error -> {:halt, error}
        result -> {:cont, result}
      end
    end)
  end

  defp stdio_request({:put_chars, encoding, chars}, stream, state),
    do: stdio_chars(chars, encoding, stream, state)

  defp stdio_request({:put_chars, chars}, stream, state),
    do: stdio_chars(chars, :unicode, stream, state)

  defp stdio_request({:put_chars, encoding, module, function, args}, stream, state) do
    stdio_chars(apply(module, function, args), encoding, stream, state)
  rescue
    _exception -> {{:error, :request}, state}
  end

  defp stdio_request({:put_chars, module, function, args}, stream, state),
    do: stdio_request({:put_chars, :unicode, module, function, args}, stream, state)

  defp stdio_request(request, _stream, state) when request in [:getopts, {:getopts}],
    do: {[binary: true, encoding: :unicode], state}

  defp stdio_request({:setopts, opts}, _stream, state) when is_list(opts) do
    if Enum.all?(opts, &(&1 in [:binary, {:binary, true}, {:encoding, :unicode}])),
      do: {:ok, state},
      else: {{:error, :enotsup}, state}
  end

  defp stdio_request(_request, _stream, state), do: {{:error, :enotsup}, state}

  defp stdio_chars(chars, encoding, stream, state) do
    case :unicode.characters_to_binary(chars, encoding) do
      text when is_binary(text) ->
        {piece, clipped?} = Output.clip(text, state.stdio.remaining)

        stdio = %{
          state.stdio
          | remaining: state.stdio.remaining - byte_size(piece),
            truncated: state.stdio.truncated or clipped?
        }

        stdio = if piece == "", do: stdio, else: Map.update!(stdio, stream, &[piece | &1])

        {:ok, %{state | stdio: stdio}}

      _invalid ->
        {{:error, :request}, state}
    end
  rescue
    _exception -> {{:error, :request}, state}
  end

  defp new_stdio,
    do: %{stdout: [], stderr: [], remaining: @stdio_limit, truncated: false}

  defp stdio_text(stdio, stream),
    do: stdio |> Map.fetch!(stream) |> Enum.reverse() |> IO.iodata_to_binary()

  defp flush_stdio(_owner, _request, %{stdout: [], stderr: [], truncated: false}), do: :ok

  defp flush_stdio(owner, request, stdio) do
    Enum.each([:stdout, :stderr], fn stream ->
      text = stdio_text(stdio, stream)

      if text != "" or stdio.truncated do
        :ok =
          :io.request(
            owner,
            {:omj_eval, request.generation, request.id, {:output, stream, text, stdio.truncated}}
          )
      end
    end)
  end

  defp frame(port, message) do
    encoded = Jason.encode!(message)
    if byte_size(encoded) >= @max_frame, do: :erlang.halt(72)
    true = Port.command(port, [encoded, "\n"])
  end

  defp halt(state, reason) do
    error =
      IO.iodata_to_binary([
        Output.inspect_value(reason, 1_024),
        "\n",
        stdio_text(state.stdio, :stdout),
        stdio_text(state.stdio, :stderr)
      ])

    frame(state.port, %{type: "fatal", error: error})
    :erlang.halt(71)
  end
end
