# Added by Oh-My-Jido contributors, 2026-10-19: opt-in diagnostics for the
# native V3 gen_statem runtime. Apache-2.0; see LICENSE and UPSTREAM.json.
defmodule Jido.AgentServer.PrivateDiagnostics do
  @moduledoc false

  require Logger

  alias Jido.Tracing.Context, as: TraceContext
  alias Jido.Tracing.Trace

  @enabled_key {__MODULE__, :enabled}
  @native_errors [
    Jido.Error.ValidationError,
    Jido.Error.ExecutionError,
    Jido.Error.RoutingError,
    Jido.Error.TimeoutError,
    Jido.Error.CompensationError,
    Jido.Error.InternalError,
    Jido.Action.Error.InvalidInputError,
    Jido.Action.Error.ExecutionFailureError,
    Jido.Action.Error.TimeoutError,
    Jido.Action.Error.ConfigurationError,
    Jido.Action.Error.InternalError,
    Jido.Flow.Error.InvalidDefinitionError,
    Jido.Flow.Error.InvalidExecutionError,
    Jido.Flow.Error.ExecutionFailureError,
    Jido.Flow.Error.TimeoutError,
    Jido.Flow.Error.InternalError
  ]

  def enabled?(%{private_diagnostics: true}), do: true
  def enabled?(%{parent: %{meta: %{private_diagnostics: true}}}), do: true
  def enabled?(%{agent: agent}), do: enabled?(agent)
  def enabled?(%{module: module}), do: enabled?(module)
  def enabled?(%{agent_module: module}), do: enabled?(module)

  def enabled?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :private_diagnostics?, 0) and
      module.private_diagnostics?() == true
  end

  def enabled?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and enabled?(Map.new(opts))
  end

  def enabled?(_value), do: false

  def active? do
    Process.get(@enabled_key) == true or
      match?(%{private?: true}, Process.get({Jido.Exec.PrivateDiagnostics, :policy}))
  end

  def child_metadata(meta, data) do
    if enabled?(data), do: Map.put(meta, :private_diagnostics, true), else: meta
  end

  def exec_options(opts, data) do
    if enabled?(data) do
      Keyword.put(opts, :private_diagnostics, %{error: &__MODULE__.error/1, private?: true})
    else
      opts
    end
  end

  def child_spec(%{start: {module, function, args}} = spec, data) do
    if enabled?(data) do
      # Supervisor reports print MFA arguments, but not a function's environment.
      # Keep the original startup operation opaque without changing supervision.
      spec = Map.put_new(spec, :modules, [module])
      %{spec | start: {__MODULE__, :start_child, [fn -> apply(module, function, args) end]}}
    else
      spec
    end
  end

  def start_child(fun) do
    case fun.() do
      {:error, {:already_started, pid}} = result when is_pid(pid) -> result
      {:error, reason} -> {:error, error(reason)}
      result -> result
    end
  catch
    kind, _reason ->
      report(:start_child, kind, __STACKTRACE__)
      {:error, :private_callback_failed}
  end

  def format(status) do
    data = Map.get(status, :data, Map.get(status, :state))

    if enabled?(data) do
      summary =
        case data do
          %{agent: agent} ->
            %{
              agent_id: agent.id,
              agent_module: agent.module,
              state_version: data.state_version,
              error_count: data.error_count
            }

          _ ->
            Map.take(data, [:owner, :child_id, :private_diagnostics])
        end

      Map.new(status, fn
        {:data, _value} -> {:data, summary}
        {:state, value} when is_atom(value) -> {:state, value}
        {:state, _value} -> {:state, summary}
        {key, _value} when key in [:queue, :postponed, :timeouts, :log] -> {key, []}
        {:reason, _value} -> {:reason, :private_agent_stopped}
        {key, _value} -> {key, :private}
      end)
    else
      status
    end
  end

  def init({opts, _reply}, fun) do
    if enabled?(opts) do
      Process.put(@enabled_key, true)

      try do
        complete(fun.())
      catch
        kind, _reason ->
          report(:init, kind, __STACKTRACE__)
          {:stop, {:shutdown, :private_callback_failed}}
      after
        TraceContext.clear()
      end
    else
      fun.()
    end
  end

  def event(type, data, fun) do
    if enabled?(data) do
      Process.put(@enabled_key, true)
      restore_turn_trace(data)

      try do
        complete(fun.())
      catch
        kind, _reason ->
          report(:handle_event, kind, __STACKTRACE__)

          case type do
            {:call, from} ->
              {:stop_and_reply, {:shutdown, :private_callback_failed},
               [{:reply, from, {:error, :private_callback_failed}}], data}

            _ ->
              {:stop, {:shutdown, :private_callback_failed}, data}
          end
      after
        # sys:get_status also prints the process dictionary, outside format_status.
        # Keep the execution trace in ActiveTurn, not in the idle callback process.
        TraceContext.clear()
      end
    else
      fun.()
    end
  end

  def terminate(data, fun) do
    if enabled?(data) do
      try do
        fun.()
      catch
        kind, _reason ->
          report(:terminate, kind, __STACKTRACE__)
          exit({:shutdown, :private_callback_failed})
      after
        TraceContext.clear()
      end
    else
      fun.()
    end
  end

  def run(false, fun), do: fun.()

  def run(true, fun) do
    Process.put(@enabled_key, true)

    try do
      fun.() |> result() |> complete()
    catch
      kind, _reason ->
        report(:task, kind, __STACKTRACE__)
        exit({:shutdown, :private_callback_failed})
    after
      TraceContext.clear()
    end
  end

  def begin_turn(data, signal) do
    if enabled?(data) do
      # Preserve execution tracestate, but never attach it to an exported OTel span.
      diagnostic_signal =
        signal
        |> Jido.Signal.delete_context("tracestate")
        |> Jido.Signal.delete_context("jidocausationid")

      trace = TraceContext.begin_turn(diagnostic_signal)
      Map.merge(trace, Map.take(Trace.get(signal) || %{}, [:tracestate, :causation_id]))
    else
      TraceContext.begin_turn(signal)
    end
  end

  def telemetry_trace(data, trace) do
    if enabled?(data), do: Map.drop(trace, [:tracestate, :causation_id]), else: trace
  end

  def telemetry_metadata(data, metadata) do
    if enabled?(data) do
      Map.drop(metadata, [:tracestate, :causation_id, :cause_turn_id, :child_activation_id])
    else
      metadata
    end
  end

  def execution_span(data, span, trace) do
    if enabled?(data) do
      %{span | trace: Map.merge(span.trace || %{}, Map.take(trace, [:tracestate, :causation_id]))}
    else
      span
    end
  end

  def error(data, reason) do
    if enabled?(data), do: error(reason), else: reason
  end

  def error(reason) when is_atom(reason), do: reason

  def error({tag, reason})
      when tag in [
             :shutdown,
             :persistence_failed,
             :bootstrap_failed,
             :agent_error,
             :max_agent_errors
           ],
      do: {tag, error(reason)}

  def error({:child_spawn_indeterminate, _tag, node, _request, reason}) when is_atom(node),
    do: {:child_spawn_indeterminate, :private, node, :private, error(reason)}

  def error({:child_operation_indeterminate, kind, reason}) when is_atom(kind),
    do: {:child_operation_indeterminate, kind, error(reason)}

  def error(%{__struct__: module} = reason) when module in @native_errors do
    fields = [message: "Private agent operation failed", details: error_details(reason)]
    fresh = struct(module, fields)
    fresh = if Map.has_key?(fresh, :stacktrace), do: Map.put(fresh, :stacktrace, nil), else: fresh

    if Map.has_key?(fresh, :timeout) and is_integer(Map.get(reason, :timeout)) do
      Map.put(fresh, :timeout, max(reason.timeout, 0))
    else
      fresh
    end
  end

  def error(reason) do
    if safe_reason?(reason, 4) do
      reason
    else
      details = error_details(reason)

      retry =
        Map.get(
          details,
          :retry,
          Map.get(details, :retryable, Map.get(details, :retryable?, false))
        )

      Jido.Error.execution_error("Private agent operation failed",
        details: Map.put(details, :retry, retry)
      )
      |> Map.put(:stacktrace, nil)
    end
  end

  def result({:error, reason}), do: {:error, error(reason)}
  def result({:error, stage, reason}) when is_atom(stage), do: {:error, stage, error(reason)}
  def result(value), do: value

  # Preserve finite machine-readable control failures, never opaque payloads.
  defp safe_reason?(_value, depth) when depth < 0, do: false
  defp safe_reason?(value, _depth) when is_atom(value) or is_integer(value), do: true

  defp safe_reason?({module, function, arguments, _location}, _depth)
       when is_atom(module) and is_atom(function) and is_list(arguments),
       do: false

  # Exception structs are opaque terms, not Enumerable diagnostic maps.
  defp safe_reason?(%{__struct__: _module}, _depth), do: false

  defp safe_reason?(value, depth) when is_tuple(value) and tuple_size(value) <= 8,
    do: safe_tuple?(value, depth - 1, tuple_size(value))

  defp safe_reason?(value, depth) when is_list(value), do: safe_list?(value, depth - 1, 16)

  defp safe_reason?(value, depth) when is_map(value) and map_size(value) <= 16 do
    Enum.all?(value, fn
      {:stacktrace, trace} when not is_nil(trace) -> false
      {key, item} -> safe_reason?(key, depth - 1) and safe_reason?(item, depth - 1)
    end)
  end

  defp safe_reason?(_value, _depth), do: false

  defp safe_tuple?(_tuple, _depth, 0), do: true

  defp safe_tuple?(tuple, depth, index),
    do: safe_reason?(elem(tuple, index - 1), depth) and safe_tuple?(tuple, depth, index - 1)

  defp safe_list?([], _depth, _remaining), do: true

  defp safe_list?([item | rest], depth, remaining) when remaining > 0,
    do: safe_reason?(item, depth) and safe_list?(rest, depth, remaining - 1)

  defp safe_list?(_value, _depth, _remaining), do: false

  defp error_details(reason) do
    details = if is_map(reason), do: Map.get(reason, :details, %{}), else: %{}

    details =
      if is_map(details),
        do:
          Map.take(details, [
            :code,
            :status,
            :kind,
            :phase,
            :retry,
            :retryable,
            :retryable?,
            :reason
          ]),
        else: %{}

    Map.merge(
      details,
      if(is_map(reason), do: Map.take(reason, [:code, :status, :retryable]), else: %{})
    )
    |> Enum.reduce(%{}, fn
      {key, value}, acc
      when key in [:code, :kind, :phase] and is_atom(value) and not is_nil(value) ->
        Map.put(acc, key, value)

      {:status, value}, acc when is_integer(value) and value in 100..599 ->
        Map.put(acc, :status, value)

      {key, value}, acc when key in [:retry, :retryable, :retryable?] and is_boolean(value) ->
        Map.put(acc, key, value)

      {:reason, value}, acc ->
        if safe_reason?(value, 4), do: Map.put(acc, :reason, value), else: acc

      _field, acc ->
        acc
    end)
  end

  defp complete({:stop, reason}), do: {:stop, stop_reason(reason)}
  defp complete({:stop, reason, data}), do: {:stop, stop_reason(reason), data}

  defp complete({:stop_and_reply, reason, replies, data}),
    do: {:stop_and_reply, stop_reason(reason), reply_actions(replies), data}

  defp complete({:keep_state_and_data, actions}),
    do: {:keep_state_and_data, reply_actions(actions)}

  defp complete({:keep_state, data, actions}),
    do: {:keep_state, data, reply_actions(actions)}

  defp complete({:next_state, phase, data, actions}),
    do: {:next_state, phase, data, reply_actions(actions)}

  defp complete(value), do: value

  defp stop_reason(reason) when is_atom(reason), do: reason
  defp stop_reason({:shutdown, reason}), do: {:shutdown, error(reason)}
  defp stop_reason(reason), do: error(reason)

  defp reply_actions(actions) when is_list(actions), do: Enum.map(actions, &reply_actions/1)

  defp reply_actions({:reply, from, {:error, reason}}),
    do: {:reply, from, {:error, error(reason)}}

  defp reply_actions(action), do: action

  defp restore_turn_trace(%{active: %{span: %{trace: trace}}}), do: TraceContext.put(trace)
  defp restore_turn_trace(_data), do: :ok

  defp report(callback, kind, stacktrace) do
    frames =
      Enum.map(stacktrace, fn
        {module, function, arguments, _location} when is_list(arguments) ->
          {module, function, length(arguments)}

        {module, function, arity, _location} when is_integer(arity) ->
          {module, function, arity}

        _frame ->
          :unknown_frame
      end)

    Logger.error("Private AgentServer callback failed",
      callback: callback,
      failure_kind: kind,
      stack_frames: frames
    )
  end
end
