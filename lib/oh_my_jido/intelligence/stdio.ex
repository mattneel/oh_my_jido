defmodule OhMyJido.Intelligence.Stdio do
  @moduledoc """
  Bounded stdio ownership for the reference LSP, DAP and MCP adapters.

  Executables and arguments are host configuration, never model parameters.
  Every instance is bound to one session and workspace. Linux process-group
  identity protects cleanup against PID reuse; a separate OTP task observes
  even an abruptly killed protocol owner. No remote transport is opened here.
  """

  use GenServer

  alias OhMyJido.{Context, Files, Tool, Workspace}
  alias OhMyJido.Intelligence.Framing

  @default_frame_bytes 1_048_576
  @default_timeout 10_000
  @default_pending_timeout 300_000
  @max_events 64
  @max_pending 8

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: start_owner(opts, :linked)

  @doc "Starts a monitored, unlinked client for a finite human-initiated smoke."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: start_owner(opts, :unlinked)

  defp start_owner(opts, mode) do
    with {:ok, context} <- Context.fetch(Keyword.get(opts, :context)),
         protocol when protocol in [:lsp, :dap, :mcp] <- Keyword.get(opts, :protocol),
         :ok <-
           Tool.authorize(context, capability(protocol), %{
             operation: :start_server,
             executable: Keyword.get(opts, :executable),
             external_process: true
           }) do
      opts = Keyword.put_new(opts, :owner, context.coordinator || self())

      case mode do
        :linked -> GenServer.start_link(__MODULE__, opts)
        :unlinked -> GenServer.start(__MODULE__, opts)
      end
    else
      nil -> {:error, :protocol_context_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_protocol}
    end
  end

  @spec bind(GenServer.server(), Context.t()) :: {:ok, map()} | {:error, term()}
  def bind(server, context),
    do: call(server, {:bind, context.session_id, context.workspace}, @default_timeout)

  @spec request(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def request(server, command, params, timeout \\ @default_timeout),
    do: call(server, {:request, command, params, timeout}, timeout + 1_000)

  @spec begin_request(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  @spec begin_request(GenServer.server(), String.t(), map(), pos_integer(), integer() | :infinity) ::
          {:ok, pos_integer()} | {:error, term()}
  def begin_request(
        server,
        command,
        params,
        timeout \\ @default_pending_timeout,
        max_id_bytes \\ :infinity
      ),
      do: call(server, {:begin_request, command, params, timeout, max_id_bytes}, @default_timeout)

  @spec await_response(GenServer.server(), pos_integer(), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def await_response(server, id, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    call(server, {:await_response, id, deadline}, timeout + 1_000)
  end

  @spec notify(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def notify(server, method, params),
    do: call(server, {:notify, method, params}, @default_timeout)

  @spec await_event(GenServer.server(), String.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def await_event(server, name, selector \\ %{}, timeout \\ @default_timeout),
    do: call(server, {:await_event, name, selector, timeout}, timeout + 1_000)

  @spec latest_event(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def latest_event(server, name, selector \\ %{}),
    do: call(server, {:latest_event, name, selector}, @default_timeout)

  @spec document_version(
          GenServer.server(),
          String.t(),
          :open | :change | :close,
          pos_integer() | nil
        ) :: {:ok, pos_integer()} | :ok | {:error, term()}
  def document_version(server, uri, operation, requested \\ nil),
    do: call(server, {:document_version, uri, operation, requested}, @default_timeout)

  @spec document_versions(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def document_versions(server), do: call(server, :document_versions, @default_timeout)

  @doc "Returns fingerprints of full source text successfully sent to the owned LSP server."
  @spec document_sources(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def document_sources(server), do: call(server, :document_sources, @default_timeout)

  @spec close(GenServer.server(), Context.t()) :: {:ok, map()} | {:error, term()}
  def close(server, context),
    do: call(server, {:close, context.session_id, context.workspace}, @default_timeout)

  @doc false
  @spec close_session(Context.t(), keyword()) :: :ok | {:error, term()}
  def close_session(context, opts) do
    case close(Keyword.get(opts, :server), context) do
      {:ok, %{cleanup: :confirmed}} -> :ok
      {:error, :protocol_closed} -> :ok
      {:ok, result} -> {:error, {:protocol_cleanup, result.cleanup}}
      {:error, _} = error -> error
    end
  end

  defp call(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :protocol_closed}
    :exit, {:normal, _} -> {:error, :protocol_closed}
    :exit, {:timeout, _} -> {:error, :protocol_timeout}
    :exit, reason -> {:error, {:protocol_owner_unavailable, reason}}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    context = Keyword.fetch!(opts, :context)

    with {:unix, :linux} <- :os.type(),
         setsid when is_binary(setsid) <- System.find_executable("setsid"),
         executable when is_binary(executable) <-
           resolve_executable(Keyword.get(opts, :executable)),
         {:ok, cwd} <- Workspace.resolve(context, "."),
         :ok <- validate_options(opts),
         {:ok, port, os_pid, process_identity} <- launch(setsid, executable, cwd, opts) do
      monitor = Process.monitor(Keyword.fetch!(opts, :owner))

      session_monitor =
        if is_pid(context.coordinator) and context.coordinator != opts[:owner],
          do: Process.monitor(context.coordinator)

      watchdog(self(), os_pid, process_identity)

      {:ok,
       %{
         port: port,
         protocol: Keyword.fetch!(opts, :protocol),
         framing: if(opts[:protocol] == :mcp, do: :lines, else: :headers),
         identity: %{
           id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
           os_pid: os_pid,
           protocol: opts[:protocol],
           session_id: context.session_id,
           workspace: cwd
         },
         process_identity: process_identity,
         owner_monitor: monitor,
         session_monitor: session_monitor,
         buffer: "",
         sequence: 1,
         pending: %{},
         completed: %{},
         response_waiters: %{},
         waiters: [],
         events: [],
         latest: %{},
         document_versions: %{},
         document_sources: %{},
         dropped_events: 0,
         max_frame_bytes:
           min(
             Keyword.get(opts, :max_frame_bytes, @default_frame_bytes),
             Map.get(context.limits, :protocol_frame_bytes, @default_frame_bytes)
           ),
         timeout:
           min(
             Keyword.get(opts, :timeout_ms, @default_timeout),
             Map.get(context.limits, :protocol_timeout_ms, @default_timeout)
           ),
         pending_timeout:
           min(
             Keyword.get(opts, :pending_timeout_ms, @default_pending_timeout),
             Map.get(context.limits, :protocol_pending_timeout_ms, @default_pending_timeout)
           ),
         configuration: Keyword.get(opts, :configuration, %{}),
         cleanup: :pending
       }}
    else
      nil -> {:stop, :protocol_executable_unavailable}
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :protocol_platform_unavailable}
    end
  end

  @impl true
  def handle_call({:bind, session_id, workspace}, _from, state) do
    reply =
      if owned?(state, session_id, workspace),
        do: {:ok, public_identity(state)},
        else: {:error, :protocol_identity_mismatch}

    {:reply, reply, state}
  end

  def handle_call({:request, command, params, timeout}, from, state) do
    if map_size(state.pending) >= @max_pending do
      {:reply, {:error, :protocol_request_limit}, state}
    else
      id = state.sequence
      message = request_message(state.protocol, id, command, params)

      case send_message(state, message) do
        :ok ->
          timer = Process.send_after(self(), {:request_timeout, id}, min(timeout, state.timeout))
          pending = Map.put(state.pending, id, %{from: from, timer: timer, command: command})
          {:noreply, %{state | sequence: id + 1, pending: pending}}

        error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:begin_request, command, params, timeout, max_id_bytes}, _from, state) do
    cond do
      map_size(state.pending) + map_size(state.completed) >= @max_pending ->
        {:reply, {:error, :protocol_request_limit}, state}

      max_id_bytes != :infinity and byte_size(Integer.to_string(state.sequence)) > max_id_bytes ->
        {:reply, {:error, :protocol_request_id_limit}, state}

      true ->
        id = state.sequence

        case send_message(state, request_message(state.protocol, id, command, params)) do
          :ok ->
            timer =
              Process.send_after(
                self(),
                {:request_timeout, id},
                min(timeout, state.pending_timeout)
              )

            pending = Map.put(state.pending, id, %{from: nil, timer: timer, command: command})
            {:reply, {:ok, id}, %{state | sequence: id + 1, pending: pending}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:await_response, id, deadline}, from, state) do
    if deadline <= System.monotonic_time(:millisecond) or not Process.alive?(elem(from, 0)) do
      {:reply, {:error, :protocol_timeout}, state}
    else
      case Map.pop(state.completed, id) do
        {nil, _completed} ->
          await_pending_response(state, id, from, deadline)

        {result, completed} ->
          {:reply, result, %{state | completed: completed}}
      end
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    case send_message(state, %{"jsonrpc" => "2.0", "method" => method, "params" => params}) do
      :ok -> {:reply, :ok, remember_document_source(state, method, params)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:latest_event, name, selector}, _from, state) do
    reply = state.latest |> Map.values() |> Enum.find(&event_matches?(&1, name, selector))
    {:reply, if(reply, do: {:ok, reply}, else: {:error, :event_unavailable}), state}
  end

  def handle_call(:document_versions, _from, state),
    do: {:reply, {:ok, state.document_versions}, state}

  def handle_call(:document_sources, _from, state),
    do: {:reply, {:ok, state.document_sources}, state}

  def handle_call({:document_version, uri, :close, _requested}, _from, state) do
    {:reply, :ok, %{state | document_versions: Map.delete(state.document_versions, uri)}}
  end

  def handle_call({:document_version, uri, operation, requested}, _from, state) do
    current = Map.get(state.document_versions, uri)
    version = requested || if(current, do: current + 1, else: 1)

    case validate_document_version(state, current, operation, version) do
      :ok ->
        latest = Map.delete(state.latest, {"textDocument/publishDiagnostics", uri})

        events =
          Enum.reject(
            state.events,
            &event_matches?(&1, "textDocument/publishDiagnostics", %{"uri" => uri})
          )

        {:reply, {:ok, version},
         %{
           state
           | document_versions: Map.put(state.document_versions, uri, version),
             latest: latest,
             events: events
         }}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:await_event, name, selector, timeout}, from, state) do
    case take_event(state.events, name, selector) do
      {:ok, event, events} ->
        {:reply, {:ok, event}, %{state | events: events}}

      :none when length(state.waiters) >= @max_pending ->
        {:reply, {:error, :protocol_request_limit}, state}

      :none ->
        ref = make_ref()
        timer = Process.send_after(self(), {:event_timeout, ref}, min(timeout, state.timeout))
        waiter = %{ref: ref, timer: timer, from: from, name: name, selector: selector}
        {:noreply, %{state | waiters: [waiter | state.waiters]}}
    end
  end

  def handle_call({:close, session_id, workspace}, _from, state) do
    if owned?(state, session_id, workspace) do
      cleanup = OhMyJido.Process.terminate_group(state.identity.os_pid, state.process_identity)
      status = if cleanup == :ok, do: :confirmed, else: :uncertain
      reply = {:ok, %{closed: true, cleanup: status, identity: public_identity(state)}}
      {:stop, :normal, reply, %{state | cleanup: status}}
    else
      {:reply, {:error, :protocol_identity_mismatch}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Framing.decode(state.buffer <> data, state.framing, state.max_frame_bytes) do
      {:ok, messages, buffer} ->
        state = Enum.reduce(messages, %{state | buffer: buffer}, &receive_message/2)
        {:noreply, state}

      {:error, reason} ->
        {:stop, {:protocol_failure, reason}, fail_pending(state, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, :normal, fail_pending(state, {:protocol_exited, status})}

  def handle_info({port, :eof}, %{port: port} = state),
    do: {:stop, :normal, fail_pending(state, :protocol_closed)}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: {:stop, :normal, fail_pending(state, {:protocol_port_exit, reason})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, fail_pending(state, :protocol_session_closed)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{session_monitor: ref} = state),
    do: {:stop, :normal, fail_pending(state, :protocol_session_closed)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.response_waiters, fn {_id, waiter} -> waiter.monitor == ref end) do
      nil ->
        {:noreply, state}

      {id, _waiter} ->
        {_waiter, state} = pop_response_waiter(state, id)
        {:noreply, state}
    end
  end

  def handle_info({:response_timeout, id, ref}, state) do
    case Map.get(state.response_waiters, id) do
      %{monitor: ^ref} = waiter ->
        GenServer.reply(waiter.from, {:error, :protocol_timeout})
        {_waiter, state} = pop_response_waiter(state, id)
        {:noreply, state}

      _expired ->
        {:noreply, state}
    end
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.get(state.pending, id) do
      nil ->
        {:noreply, state}

      pending ->
        cancel_request(state, id, pending.command)

        {:noreply, respond(state, id, {:error, {:protocol_timeout, pending.command}})}
    end
  end

  def handle_info({:event_timeout, ref}, state) do
    {expired, remaining} = Enum.split_with(state.waiters, &(&1.ref == ref))
    Enum.each(expired, &GenServer.reply(&1.from, {:error, {:protocol_event_timeout, &1.name}}))
    {:noreply, %{state | waiters: remaining}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fail_pending(state, :protocol_closed)

    if state.cleanup != :confirmed,
      do: OhMyJido.Process.terminate_group(state.identity.os_pid, state.process_identity)

    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp receive_message(%{"type" => "response", "request_seq" => id} = message, state) do
    result =
      if message["success"] == true,
        do: {:ok, Map.get(message, "body", %{})},
        else: {:error, {:dap_error, Map.take(message, ["command", "message", "body"])}}

    respond(state, id, result)
  end

  defp receive_message(%{"id" => id, "result" => result}, state),
    do: respond(state, id, {:ok, result})

  defp receive_message(%{"id" => id, "error" => error}, state),
    do: respond(state, id, {:error, {:protocol_error, error}})

  defp receive_message(%{"type" => "request", "seq" => seq, "command" => command}, state) do
    send_message(state, %{
      "seq" => state.sequence,
      "type" => "response",
      "request_seq" => seq,
      "command" => command,
      "success" => false,
      "message" => "Reverse requests require an explicit host implementation"
    })

    %{state | sequence: state.sequence + 1}
  end

  defp receive_message(%{"id" => id, "method" => method} = message, state) do
    response = reverse_request(state, id, method, Map.get(message, "params", %{}))
    send_message(state, response)
    state
  end

  defp receive_message(message, state) do
    name = event_name(message)

    if is_binary(name) do
      payload = event_fields(message)
      key = {name, Map.get(payload, "uri")}
      latest = Map.put(state.latest, key, message)
      latest = if map_size(latest) > @max_events, do: %{key => message}, else: latest

      {matches, remaining} =
        Enum.split_with(state.waiters, &event_matches?(message, &1.name, &1.selector))

      Enum.each(matches, fn waiter ->
        Process.cancel_timer(waiter.timer)
        GenServer.reply(waiter.from, {:ok, message})
      end)

      events =
        if matches == [],
          do: Enum.take(state.events ++ [message], -@max_events),
          else: state.events

      dropped = if matches == [] and length(state.events) >= @max_events, do: 1, else: 0

      %{
        state
        | latest: latest,
          waiters: remaining,
          events: events,
          dropped_events: state.dropped_events + dropped
      }
    else
      state
    end
  end

  defp await_pending_response(state, id, from, deadline) do
    case Map.get(state.pending, id) do
      %{from: nil} -> register_response_waiter(state, id, from, deadline)
      _unknown -> {:reply, {:error, :unknown_protocol_request}, state}
    end
  end

  defp register_response_waiter(state, id, from, deadline) do
    case Map.get(state.response_waiters, id) do
      nil ->
        add_response_waiter(state, id, from, deadline)

      waiter ->
        if response_waiter_active?(waiter) do
          {:reply, {:error, :protocol_response_already_awaited}, state}
        else
          GenServer.reply(waiter.from, {:error, :protocol_timeout})
          {_waiter, state} = pop_response_waiter(state, id)
          add_response_waiter(state, id, from, deadline)
        end
    end
  end

  defp add_response_waiter(state, id, from, deadline) do
    now = System.monotonic_time(:millisecond)
    deadline = min(deadline, now + state.timeout)
    monitor = Process.monitor(elem(from, 0))
    timer = Process.send_after(self(), {:response_timeout, id, monitor}, max(deadline - now, 0))
    waiter = %{from: from, monitor: monitor, timer: timer, deadline: deadline}
    {:noreply, %{state | response_waiters: Map.put(state.response_waiters, id, waiter)}}
  end

  defp response_waiter_active?(waiter),
    do:
      waiter.deadline > System.monotonic_time(:millisecond) and
        Process.alive?(elem(waiter.from, 0))

  defp pop_response_waiter(state, id) do
    {waiter, remaining} = Map.pop(state.response_waiters, id)
    if waiter, do: release_response_waiter(waiter)
    {waiter, %{state | response_waiters: remaining}}
  end

  defp release_response_waiter(waiter) do
    Process.cancel_timer(waiter.timer)
    Process.demonitor(waiter.monitor, [:flush])
  end

  defp remember_document_source(%{protocol: :lsp} = state, method, params)
       when method in ["textDocument/didOpen", "textDocument/didChange", "textDocument/didClose"] do
    document = protocol_field(params, "textDocument", :textDocument)
    uri = protocol_field(document, "uri", :uri)

    cond do
      not is_binary(uri) ->
        %{state | document_sources: %{}}

      method == "textDocument/didClose" ->
        %{state | document_sources: Map.delete(state.document_sources, uri)}

      not Map.has_key?(state.document_versions, uri) ->
        %{state | document_sources: Map.delete(state.document_sources, uri)}

      true ->
        version = protocol_field(document, "version", :version)

        text =
          if method == "textDocument/didOpen" do
            protocol_field(document, "text", :text)
          else
            full_change_text(protocol_field(params, "contentChanges", :contentChanges))
          end

        snapshot =
          if is_binary(text) and is_integer(version) and version > 0,
            do: Files.snapshot(text)

        source = %{version: version, snapshot: snapshot}
        %{state | document_sources: Map.put(state.document_sources, uri, source)}
    end
  end

  defp remember_document_source(state, _method, _params), do: state

  defp full_change_text([change]) when is_map(change) do
    if Map.has_key?(change, "range") or Map.has_key?(change, :range),
      do: nil,
      else: protocol_field(change, "text", :text)
  end

  defp full_change_text(_changes), do: nil

  defp protocol_field(map, string, atom) when is_map(map) do
    case Map.fetch(map, string) do
      {:ok, value} -> value
      :error -> Map.get(map, atom)
    end
  end

  defp protocol_field(_value, _string, _atom), do: nil

  defp validate_document_version(_state, nil, :change, _version),
    do: {:error, :lsp_document_not_open}

  defp validate_document_version(_state, current, :open, _version) when not is_nil(current),
    do: {:error, :lsp_document_already_open}

  defp validate_document_version(state, current, _operation, version) do
    cond do
      not advancing_version?(version, current) ->
        {:error, :lsp_document_version_stale}

      map_size(state.document_versions) >= @max_events and is_nil(current) ->
        {:error, :lsp_document_limit}

      true ->
        :ok
    end
  end

  defp advancing_version?(version, current),
    do: is_integer(version) and version > 0 and (is_nil(current) or version > current)

  defp respond(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {pending, remaining} ->
        Process.cancel_timer(pending.timer)
        state = %{state | pending: remaining}
        state = remember_server_info(state, pending.command, result)

        deliver_response(state, pending.from, id, result)
    end
  end

  defp remember_server_info(%{protocol: :lsp} = state, "initialize", {:ok, result}) do
    identity = Map.delete(state.identity, :server_info)

    case initialization_server_info(result) do
      nil -> %{state | identity: identity}
      info -> %{state | identity: Map.put(identity, :server_info, info)}
    end
  end

  defp remember_server_info(state, _command, _result), do: state

  defp initialization_server_info(%{"serverInfo" => %{"name" => name} = info})
       when is_binary(name) and byte_size(name) in 1..256 do
    if valid_protocol_string?(name) do
      info
      |> Map.take(["name", "version"])
      |> Enum.filter(fn {_key, value} ->
        is_binary(value) and byte_size(value) in 1..256 and valid_protocol_string?(value)
      end)
      |> Map.new()
    end
  end

  defp initialization_server_info(_result), do: nil

  defp deliver_response(state, nil, id, result) do
    case pop_response_waiter(state, id) do
      {nil, state} ->
        %{state | completed: Map.put(state.completed, id, result)}

      {waiter, state} ->
        if response_waiter_active?(waiter) do
          GenServer.reply(waiter.from, result)
          state
        else
          GenServer.reply(waiter.from, {:error, :protocol_timeout})
          %{state | completed: Map.put(state.completed, id, result)}
        end
    end
  end

  defp deliver_response(state, from, _id, result) do
    GenServer.reply(from, result)
    state
  end

  defp reverse_request(%{protocol: :lsp} = state, id, "workspace/configuration", params) do
    result =
      Enum.map(Map.get(params, "items", []), &Map.get(state.configuration, &1["section"], %{}))

    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp reverse_request(%{protocol: :lsp} = state, id, "workspace/workspaceFolders", _params) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => [
        %{
          "uri" => URI.to_string(%URI{scheme: "file", path: state.identity.workspace}),
          "name" => Path.basename(state.identity.workspace)
        }
      ]
    }
  end

  defp reverse_request(_state, id, _method, _params),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Reverse requests are not granted"}
    }

  defp cancel_request(%{protocol: :lsp} = state, id, _command),
    do:
      send_message(state, %{
        "jsonrpc" => "2.0",
        "method" => "$/cancelRequest",
        "params" => %{"id" => id}
      })

  defp cancel_request(%{protocol: :mcp}, _id, "initialize"), do: :ok

  defp cancel_request(%{protocol: :mcp} = state, id, _command),
    do:
      send_message(state, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => id, "reason" => "Request deadline elapsed"}
      })

  defp cancel_request(%{protocol: :dap}, _id, _command), do: :ok

  defp request_message(:dap, id, command, args),
    do: %{"seq" => id, "type" => "request", "command" => command, "arguments" => args}

  defp request_message(_protocol, id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp send_message(state, message) do
    with {:ok, encoded} <- Framing.encode(message, state.framing, state.max_frame_bytes) do
      if Port.command(state.port, encoded, [:nosuspend]),
        do: :ok,
        else: {:error, :protocol_backpressure}
    end
  rescue
    ArgumentError -> {:error, :protocol_closed}
  end

  defp take_event(events, name, selector) do
    case Enum.find_index(events, &event_matches?(&1, name, selector)) do
      nil ->
        :none

      index ->
        {event, remaining} = List.pop_at(events, index)
        {:ok, event, remaining}
    end
  end

  defp event_matches?(message, name, selector) do
    payload = event_fields(message)

    event_name(message) == name and
      Enum.all?(selector, fn {key, value} -> Map.get(payload, key) == value end)
  end

  defp event_name(%{"method" => name}), do: name
  defp event_name(%{"type" => "event", "event" => name}), do: name
  defp event_name(_), do: nil

  defp event_fields(message) do
    case Map.get(message, "params", Map.get(message, "body")) do
      fields when is_map(fields) -> fields
      _absent_or_non_object -> %{}
    end
  end

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_id, pending} ->
      Process.cancel_timer(pending.timer)
      if pending.from, do: GenServer.reply(pending.from, {:error, reason})
    end)

    Enum.each(state.response_waiters, fn {_id, waiter} ->
      release_response_waiter(waiter)
      GenServer.reply(waiter.from, {:error, reason})
    end)

    Enum.each(state.waiters, fn waiter ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, reason})
    end)

    %{state | pending: %{}, waiters: [], response_waiters: %{}}
  end

  defp owned?(state, session, root),
    do: state.identity.session_id == session and state.identity.workspace == root

  defp public_identity(state), do: Map.put(state.identity, :dropped_events, state.dropped_events)
  defp capability(:dap), do: :debug
  defp capability(protocol), do: protocol
  defp resolve_executable(nil), do: nil

  defp resolve_executable(executable) when is_binary(executable),
    do: System.find_executable(executable)

  defp resolve_executable(_), do: nil

  defp validate_options(opts) do
    strings = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    valid_args = is_list(strings) and Enum.all?(strings, &valid_protocol_string?/1)
    valid_env = is_list(env) and Enum.all?(env, &valid_environment_entry?/1)

    valid_limits =
      Enum.all?(
        [
          Keyword.get(opts, :max_frame_bytes, @default_frame_bytes),
          Keyword.get(opts, :timeout_ms, @default_timeout),
          Keyword.get(opts, :pending_timeout_ms, @default_pending_timeout)
        ],
        &(is_integer(&1) and &1 > 0)
      )

    valid_owner = is_pid(Keyword.get(opts, :owner))

    if valid_args and valid_env and valid_limits and valid_owner,
      do: :ok,
      else: {:error, :invalid_protocol_configuration}
  end

  defp valid_protocol_string?(value),
    do: is_binary(value) and not String.contains?(value, <<0>>)

  defp valid_environment_entry?({key, value}) do
    valid_protocol_string?(key) and key != "" and not String.contains?(key, "=") and
      (is_nil(value) or valid_protocol_string?(value))
  end

  defp valid_environment_entry?(_invalid), do: false

  defp launch(setsid, executable, cwd, opts) do
    env =
      Enum.map(Keyword.get(opts, :env, []), fn {key, value} ->
        {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
      end)

    port =
      Port.open({:spawn_executable, String.to_charlist(setsid)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :eof,
        :hide,
        {:args, ["--fork", "--wait", "--", executable | Keyword.get(opts, :args, [])]},
        {:cd, String.to_charlist(cwd)},
        {:env, env}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    case capture_leader(pid, System.monotonic_time(:millisecond) + 2_000) do
      {:ok, leader, identity} ->
        {:ok, port, leader, identity}

      {:error, reason} ->
        Port.close(port)
        {:error, reason}
    end
  rescue
    error -> {:error, {:protocol_launch_failed, Exception.message(error)}}
  end

  defp capture_leader(launcher, deadline) do
    case OhMyJido.Process.capture_identity(launcher) do
      {:ok, identity} -> capture_child(launcher, identity.start, deadline)
      {:error, reason} -> {:error, {:protocol_identity_unavailable, reason}}
    end
  end

  defp capture_child(launcher, start, deadline) do
    case child_identity(launcher, start) do
      {:ok, child, identity} ->
        {:ok, child, identity}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            1 -> capture_child(launcher, start, deadline)
          end
        else
          {:error, {:protocol_identity_unavailable, reason}}
        end
    end
  end

  defp child_identity(launcher, start) do
    with {:ok, %{start: ^start}} <- OhMyJido.Process.capture_identity(launcher),
         {:ok, children} <- File.read("/proc/#{launcher}/task/#{launcher}/children"),
         [text] <- String.split(children),
         {child, ""} when child > 1 <- Integer.parse(text),
         {:ok, identity} <- OhMyJido.Process.capture_identity(child),
         true <- identity.parent == Integer.to_string(launcher),
         true <- identity.group == Integer.to_string(child) and identity.session == identity.group,
         {:ok, %{start: ^start}} <- OhMyJido.Process.capture_identity(launcher) do
      {:ok, child, identity}
    else
      {:error, reason} -> {:error, reason}
      _unbound -> {:error, :protocol_child_not_ready}
    end
  end

  defp watchdog(owner, pid, identity) do
    Task.start(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, ^owner, _reason} ->
          OhMyJido.Process.terminate_group(pid, identity)
      end
    end)
  end
end
