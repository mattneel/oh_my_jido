# Added and modified by Oh-My-Jido contributors, 2026-10-13: opt-in private
# callback diagnostics and payload-free directive telemetry.
# Apache License 2.0; see LICENSE and UPSTREAM.json in this package.
defmodule Jido.AgentServer.PrivateDiagnostics do
  @moduledoc false

  require Logger

  alias Jido.Observe
  alias Jido.Tracing.Context, as: TraceContext

  def enabled?(%{parent: %{meta: %{private_diagnostics: true}}}), do: true

  def enabled?(%{agent_module: module}) when is_atom(module) do
    function_exported?(module, :private_diagnostics?, 0) and module.private_diagnostics?() == true
  end

  def enabled?(_state), do: false

  def child_metadata(meta, state) do
    if enabled?(state), do: Map.put(meta, :private_diagnostics, true), else: meta
  end

  def format(status) do
    state = Map.get(status, :state)

    if enabled?(state) do
      summary = Map.take(state, [:id, :agent_module, :status, :processing, :error_count])
      Map.merge(status, %{state: summary, message: :private, log: [], reason: :private_agent_stopped})
    else
      status
    end
  end

  def directive_metadata(state, directive, signal, directive_type) do
    metadata = %{
      agent_id: state.id,
      agent_module: state.agent_module,
      directive_type: directive_type,
      signal_type: signal.type,
      jido_instance: state.jido,
      jido_partition: state.partition
    }

    if enabled?(state) do
      Map.put(metadata, :signal_id, signal.id)
    else
      metadata
      |> Map.put(:directive, directive)
      |> Map.merge(TraceContext.to_telemetry_metadata())
    end
  end

  def emit_directive_event(state, signal, event, measurements, metadata) do
    if enabled?(state) do
      # Observe enriches events from the complete process trace context, including
      # free-form tracestate. Keep that context for execution, never for diagnostics.
      trace = TraceContext.get()
      TraceContext.clear()

      try do
        Observe.emit_event(event, measurements, metadata)
      after
        TraceContext.clear()

        if trace do
          TraceContext.set_from_signal(%{signal | extensions: %{"correlation" => trace}})
        end
      end
    else
      Observe.emit_event(event, measurements, metadata)
    end
  end

  def exception_metadata(state, kind, reason) do
    if enabled?(state) do
      %{kind: kind, error_type: :private_agent_failure, retryable?: false}
    else
      Jido.Observe.exception_metadata(kind, reason)
    end
  end

  def failed(type, state, kind, reason, stacktrace) do
    if enabled?(state) do
      report(state, type, kind, stacktrace)

      case type do
        :call -> {:stop, {:shutdown, :private_callback_failed}, {:error, :private_callback_failed}, state}
        :terminate -> :ok
        :async -> {:stop, {:shutdown, :private_callback_failed}, state}
      end
    else
      :erlang.raise(kind, reason, stacktrace)
    end
  end

  def complete(type, state, result) do
    if enabled?(state) do
      private_result(type, state, result)
    else
      result
    end
  end

  defp private_result(:terminate, _state, result), do: result
  defp private_result(:call, _state, {:reply, _reply, _next_state} = result), do: result
  defp private_result(:call, _state, {:reply, _reply, _next_state, timeout} = result)
       when timeout in [:infinity, :hibernate] or (is_integer(timeout) and timeout >= 0), do: result
  defp private_result(:call, _state, {:reply, _reply, _next_state, {:continue, _message}} = result), do: result
  defp private_result(_type, _state, {:noreply, _next_state} = result), do: result
  defp private_result(_type, _state, {:noreply, _next_state, timeout} = result)
       when timeout in [:infinity, :hibernate] or (is_integer(timeout) and timeout >= 0), do: result
  defp private_result(_type, _state, {:noreply, _next_state, {:continue, _message}} = result), do: result
  defp private_result(_type, _state, {:stop, reason, next_state}), do: {:stop, stop_reason(reason), next_state}
  defp private_result(:call, _state, {:stop, reason, reply, next_state}), do: {:stop, stop_reason(reason), reply, next_state}
  defp private_result(type, state, _invalid), do: failed(type, state, :error, :invalid_callback_return, [])

  defp stop_reason(reason) when reason in [:normal, :shutdown], do: reason
  defp stop_reason({:shutdown, reason}) when is_atom(reason), do: {:shutdown, reason}
  defp stop_reason(_reason), do: {:shutdown, :private_agent_stopped}

  defp report(state, type, kind, stacktrace) do
    frames = Enum.map(stacktrace, fn
      {module, function, arguments, _location} when is_list(arguments) -> {module, function, length(arguments)}
      {module, function, arity, _location} when is_integer(arity) -> {module, function, arity}
      _frame -> :unknown_frame
    end)

    Logger.error("Private AgentServer callback failed",
      agent_id: state.id,
      callback: type,
      failure_kind: kind,
      stack_frames: frames
    )
  end
end
