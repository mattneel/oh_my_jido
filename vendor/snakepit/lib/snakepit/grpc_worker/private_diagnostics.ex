# Added by Oh-My-Jido contributors, 2026-10-16: opt-in native worker
# diagnostics without private configuration, RPC payloads, or Python output.
# MIT License; see LICENSE and UPSTREAM.json in this package.
# Updated 2026-10-17: keep private state and native RPC payloads opaque in
# OTP's raw sys-debug history, which is outside format_status/1's result.
defmodule Snakepit.GRPCWorker.PrivateDiagnostics do
  @moduledoc false

  alias Snakepit.Logger, as: SLog
  alias Snakepit.Pool.Registry, as: PoolRegistry

  @context_key {__MODULE__, :enabled}
  @safe_reasons [
    nil,
    :normal,
    :shutdown,
    :killed,
    :noproc,
    :timeout,
    :unavailable,
    :internal,
    :invalid_argument,
    :not_found,
    :not_connected,
    :private_rpc_failure,
    :private_callback_failed,
    :private_worker_failure
  ]

  # Only the trusted native worker configuration can opt in. RPC options and
  # request arguments never set this process-local diagnostic context.
  def private_config?(%{private_diagnostics: true}), do: true
  def private_config?(_config), do: false

  def private_options?(opts) when is_list(opts),
    do: private_config?(Keyword.get(opts, :worker_config, %{}))

  def private_options?(_opts), do: false

  def configure(true) do
    Process.put(@context_key, true)
    :ok
  end

  def configure(false) do
    Process.delete(@context_key)
    :ok
  end

  def enabled?, do: Process.get(@context_key, false) == true

  # Supervisor offender MFAs must not retain an inspectable copy of private
  # options. A native anonymous initializer keeps the exact restart arguments
  # without exposing its captured environment through ordinary OTP reports.
  def opaque_options(opts) do
    if private_options?(opts), do: {:private_diagnostics, fn -> opts end}, else: opts
  end

  def unwrap_options({:private_diagnostics, initializer}) when is_function(initializer, 0),
    do: initializer.()

  def unwrap_options(opts), do: opts

  def registry_metadata(metadata, opts) do
    if private_options?(opts), do: Map.put(metadata, :private_diagnostics, true), else: metadata
  end

  # Native OTP stores incoming messages and callback states in its own debug
  # history before format_status/1 can run. Protect those values at the native
  # API boundary rather than disabling debugging or filtering global logs.
  def request(worker, message) do
    if private_worker?(worker),
      do: {:private_worker_message, fn -> message end},
      else: message
  end

  def internal_message(message) do
    if enabled?(), do: {:private_worker_message, fn -> message end}, else: message
  end

  def unwrap_message({:private_worker_message, initializer} = message)
      when is_function(initializer, 0) do
    if enabled?(), do: initializer.(), else: message
  end

  def unwrap_message(message), do: message

  def unwrap_state({:private_worker_state, _id, initializer}) when is_function(initializer, 0),
    do: initializer.()

  def unwrap_state(state), do: state

  defp store_state({:private_worker_state, _id, initializer} = state)
       when is_function(initializer, 0),
       do: state

  defp store_state(state),
    do: {:private_worker_state, worker_id(state), fn -> state end}

  defp private_worker?(worker) when is_pid(worker) do
    with {:ok, id} <- PoolRegistry.get_worker_id_by_pid(worker),
         {:ok, metadata} <- PoolRegistry.get_worker_metadata(id) do
      private_config?(metadata)
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp private_worker?(worker) do
    case GenServer.whereis(worker) do
      pid when is_pid(pid) -> private_worker?(pid)
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def format_status(status) do
    state = status |> Map.get(:state) |> unwrap_state()

    if enabled?() or private_state?(state) do
      Map.merge(status, %{
        state: worker_summary(state),
        message: shape(Map.get(status, :message)),
        log: [],
        reason: safe_reason(Map.get(status, :reason))
      })
    else
      status
    end
  end

  def diagnostic(value), do: if(enabled?(), do: shape(value), else: value)
  def inspect_term(value), do: inspect(diagnostic(value))
  def reason(value), do: if(enabled?(), do: safe_reason(value), else: value)
  def command_name(value), do: if(enabled?(), do: "private_rpc", else: value)

  def output(value) when is_binary(value) do
    if enabled?(), do: "<private output: #{byte_size(value)} bytes>", else: value
  end

  def describe(value) do
    if enabled?(), do: inspect(shape(value)), else: Snakepit.Logger.Redaction.describe(value)
  end

  def exception_message(error) do
    if enabled?(), do: "Private gRPC request failed", else: Exception.message(error)
  end

  def stacktrace(trace), do: if(enabled?(), do: safe_stacktrace(trace), else: trace)

  def rpc(fun) when is_function(fun, 0) do
    if enabled?() do
      try do
        case fun.() do
          {:error, error} -> {:error, safe_reason(error)}
          result -> result
        end
      catch
        kind, _reason ->
          report(:rpc, nil, kind, __STACKTRACE__)
          {:error, :private_rpc_failure}
      end
    else
      fun.()
    end
  end

  def task_result({reply, stat_result} = result) do
    if enabled?() do
      case reply do
        {:error, error} -> {{:error, safe_reason(error)}, stat_result}
        _ -> result
      end
    else
      result
    end
  end

  def complete(type, state, result) do
    if enabled?(), do: private_result(type, state, result), else: result
  end

  def failed(type, state, kind, reason, trace) do
    if enabled?() do
      report(type, state, kind, trace)

      case type do
        :init ->
          {:stop, :private_callback_failed}

        :call ->
          {:stop, :private_callback_failed, {:error, :private_callback_failed},
           store_state(state)}

        :terminate ->
          :ok

        :async ->
          {:stop, :private_callback_failed, store_state(state)}
      end
    else
      :erlang.raise(kind, reason, trace)
    end
  end

  defp private_state?(%{worker_config: config}), do: private_config?(config)
  defp private_state?(_state), do: false

  defp worker_summary(state) when is_map(state) do
    state
    |> Map.take([:id, :session_id, :adapter, :pool_name, :port, :process_pid, :shutting_down])
    |> Map.put(:status, worker_status(state))
    |> Map.put(:stats, Map.take(Map.get(state, :stats, %{}), [:requests, :errors, :start_time]))
    |> Map.put(:pending_rpc_calls, map_size(Map.get(state, :pending_rpc_calls, %{})))
    |> Map.put(:queued_rpc_calls, :queue.len(Map.get(state, :rpc_request_queue, :queue.new())))
  end

  defp worker_summary(_state), do: %{status: :initializing}

  defp worker_status(%{shutting_down: true}), do: :stopping
  defp worker_status(%{connection: nil}), do: :starting
  defp worker_status(_state), do: :ready

  defp private_result(:init, _state, {:ok, state}), do: {:ok, store_state(state)}

  defp private_result(:init, _state, {:ok, state, extra})
       when extra in [:infinity, :hibernate] or (is_integer(extra) and extra >= 0),
       do: {:ok, store_state(state), extra}

  defp private_result(:init, _state, {:ok, state, {:continue, message}}),
    do: {:ok, store_state(state), {:continue, message}}

  defp private_result(:init, _state, {:stop, reason}), do: {:stop, safe_reason(reason)}
  defp private_result(:init, _state, :ignore), do: :ignore
  defp private_result(:terminate, _state, result), do: result

  defp private_result(:call, _state, {:reply, reply, state}),
    do: {:reply, reply, store_state(state)}

  defp private_result(:call, _state, {:reply, reply, state, extra})
       when extra in [:infinity, :hibernate] or (is_integer(extra) and extra >= 0),
       do: {:reply, reply, store_state(state), extra}

  defp private_result(:call, _state, {:reply, reply, state, {:continue, message}}),
    do: {:reply, reply, store_state(state), {:continue, message}}

  defp private_result(_type, _state, {:noreply, state}), do: {:noreply, store_state(state)}

  defp private_result(_type, _state, {:noreply, state, extra})
       when extra in [:infinity, :hibernate] or (is_integer(extra) and extra >= 0),
       do: {:noreply, store_state(state), extra}

  defp private_result(_type, _state, {:noreply, state, {:continue, message}}),
    do: {:noreply, store_state(state), {:continue, message}}

  defp private_result(_type, _state, {:stop, reason, state}),
    do: {:stop, safe_reason(reason), store_state(state)}

  defp private_result(:call, _state, {:stop, reason, reply, state}),
    do: {:stop, safe_reason(reason), reply, store_state(state)}

  defp private_result(type, state, _invalid),
    do: failed(type, state, :error, :invalid_callback_return, [])

  defp safe_reason(reason) when reason in @safe_reasons, do: reason

  defp safe_reason({tag, status})
       when tag in [:grpc_server_exited, :grpc_server_exited_unexpectedly] and is_integer(status),
       do: {tag, status}

  defp safe_reason({:shutdown, _reason}), do: {:shutdown, :private_worker_failure}

  defp safe_reason({:external_process_died, reason}),
    do: {:external_process_died, safe_reason(reason)}

  defp safe_reason(_reason), do: :private_worker_failure

  # Do not use Redaction.describe/1 for private maps: its map keys, struct
  # names, atom values, and numeric values can themselves be private payloads.
  defp shape(value) when is_binary(value), do: %{type: :binary, bytes: byte_size(value)}
  defp shape(value) when is_map(value), do: %{type: :map, entries: map_size(value)}
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: %{type: :tuple, entries: tuple_size(value)}
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_number(value), do: :number
  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_reference(value), do: :reference
  defp shape(value) when is_port(value), do: :port
  defp shape(value) when is_function(value), do: :function
  defp shape(_value), do: :private

  defp safe_stacktrace(trace) do
    Enum.map(trace, fn
      {module, function, arguments, _location} when is_list(arguments) ->
        {module, function, length(arguments), []}

      {module, function, arity, _location} when is_integer(arity) ->
        {module, function, arity, []}

      _ ->
        {__MODULE__, :private_frame, 0, []}
    end)
  end

  defp report(type, state, kind, trace) do
    SLog.error(:grpc, "Private gRPC worker callback failed",
      worker_id: worker_id(state),
      callback: type,
      failure_kind: kind,
      stacktrace: safe_stacktrace(trace)
    )
  end

  defp worker_id({:private_worker_state, id, _initializer}), do: id
  defp worker_id(%{id: id}), do: id
  defp worker_id(_state), do: nil
end
