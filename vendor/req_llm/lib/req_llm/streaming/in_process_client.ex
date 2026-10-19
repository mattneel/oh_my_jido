# Modified by Oh-My-Jido contributors, 2026-10-13: normalize model-bound attach,
# enumeration and cancellation failures before native diagnostics and propagation.
# Original ReqLLM 1.28.0: Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule ReqLLM.Streaming.InProcessClient do
  @moduledoc false

  alias ReqLLM.Provider.InProcessStream
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamServer
  alias ReqLLM.Streaming.Failure

  require Logger

  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid()) ::
          {:ok, pid(), (-> any()) | nil} | {:error, term()}
  def start_stream(provider_mod, model, context, opts, stream_server_pid) do
    start_stream(
      provider_mod,
      model,
      context,
      opts,
      stream_server_pid,
      ReqLLM.TaskSupervisor
    )
  end

  @doc false
  @spec start_stream(module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), pid(), term()) ::
          {:ok, pid(), (-> any()) | nil} | {:error, term()}
  def start_stream(provider_mod, model, context, opts, stream_server_pid, task_supervisor) do
    error_context = Failure.error_context(provider_mod, model, opts)

    with :ok <- validate_callback(provider_mod),
         {:ok, stream_result} <- provider_mod.attach_in_process_stream(model, context, opts),
         {:ok, stream, cancel} <- normalize_stream(stream_result) do
      start_streaming_task(stream, stream_server_pid, task_supervisor, cancel, error_context)
    else
      {:error, reason, cancel} ->
        cancel_stream(cancel, error_context)
        Failure.build_failure(reason, :provider_build_failed, error_context)

      {:error, reason} ->
        Failure.build_failure(reason, :provider_build_failed, error_context)
    end
  rescue
    error ->
      Failure.build_failure(error, :build_stream_failed, Failure.error_context(provider_mod, model, opts))
  catch
    kind, reason ->
      error_context = Failure.error_context(provider_mod, model, opts)

      if Failure.normalizer?(error_context),
        do: Failure.build_failure({kind, reason}, :build_stream_failed, error_context),
        else: :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc false
  @spec cancel_stream((-> any()) | nil) :: :ok
  @spec cancel_stream((-> any()) | nil, term()) :: :ok
  def cancel_stream(cancel, error_context \\ nil)
  def cancel_stream(nil, _error_context), do: :ok

  def cancel_stream(cancel, error_context) when is_function(cancel, 0) do
    {:ok, _pid} = Task.start(fn -> run_cancel_callback(cancel, error_context) end)
    :ok
  end

  defp start_streaming_task(stream, stream_server_pid, task_supervisor, cancel, error_context) do
    case Task.Supervisor.async(task_supervisor, fn ->
           run_stream(stream, stream_server_pid, error_context)
         end) do
      %Task{pid: task_pid} ->
        {:ok, task_pid, bind_cancel(cancel, error_context)}
    end
  rescue
    error ->
      cancel_stream(cancel, error_context)
      Failure.build_failure(error, :task_start_failed, error_context)
  catch
    kind, reason ->
      cancel_stream(cancel, error_context)
      Failure.build_failure({kind, reason}, :task_start_failed, error_context)
  end

  @doc false
  @spec run_stream(Enumerable.t(), pid()) :: :ok | {:error, term()}
  @spec run_stream(Enumerable.t(), pid(), term()) :: :ok | {:error, term()}
  def run_stream(stream, stream_server_pid, error_context \\ nil) do
    result =
      Enum.reduce_while(stream, :open, fn
        %StreamChunk{} = chunk, _state ->
          :ok = safe_stream_event(stream_server_pid, {:chunk, chunk})

          if terminal_chunk?(chunk) do
            {:halt, :terminal}
          else
            {:cont, :open}
          end

        {:error, reason}, _state ->
          failure = forward_stream_failure(stream_server_pid, reason, error_context)
          {:halt, failure}

        value, _state ->
          failure =
            forward_stream_failure(
              stream_server_pid,
              {:invalid_in_process_stream_item, value},
              error_context
            )
          {:halt, failure}
      end)

    case result do
      :open ->
        :ok = safe_stream_event(stream_server_pid, :done)
        :ok

      :terminal ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      forward_stream_failure(stream_server_pid, error, error_context)
  catch
    kind, reason ->
      forward_stream_failure(stream_server_pid, {kind, reason}, error_context)
  end

  defp validate_callback(provider_mod) do
    if function_exported?(provider_mod, :attach_in_process_stream, 3) do
      :ok
    else
      {:error, {:missing_callback, :attach_in_process_stream, 3}}
    end
  end

  defp normalize_stream(%InProcessStream{stream: stream, cancel: cancel}) do
    with :ok <- validate_cancel(cancel) do
      case validate_enumerable(stream) do
        :ok -> {:ok, stream, cancel}
        {:error, reason} -> {:error, reason, cancel}
      end
    end
  end

  defp normalize_stream(stream) do
    case validate_enumerable(stream) do
      :ok -> {:ok, stream, nil}
      {:error, _reason} = error -> error
    end
  end

  defp validate_enumerable(stream) do
    if Enumerable.impl_for(stream) do
      :ok
    else
      {:error, {:invalid_in_process_stream, stream}}
    end
  end

  defp validate_cancel(nil), do: :ok
  defp validate_cancel(cancel) when is_function(cancel, 0), do: :ok
  defp validate_cancel(cancel), do: {:error, {:invalid_cancel_callback, cancel}}

  defp forward_stream_failure(stream_server_pid, reason, error_context) do
    reason = Failure.normalize(reason, error_context)
    :ok = safe_stream_event(stream_server_pid, {:error, reason})
    {:error, reason}
  end

  defp bind_cancel(nil, _error_context), do: nil

  defp bind_cancel(cancel, error_context) do
    if Failure.normalizer?(error_context),
      do: fn -> run_cancel_callback(cancel, error_context) end,
      else: cancel
  end

  defp run_cancel_callback(cancel, error_context) do
    case cancel.() do
      {:error, reason} -> log_cancel_error(reason, error_context)
      _result -> :ok
    end
  rescue
    error -> log_cancel_error(error, error_context)
  catch
    kind, reason -> log_cancel_error({kind, reason}, error_context)
  end

  defp log_cancel_error(reason, error_context) do
    reason = Failure.normalize(reason, error_context)
    Logger.warning("In-process stream cancellation failed: kind=#{Failure.diagnostic_kind(reason)}")
  end

  defp safe_stream_event(stream_server_pid, event) do
    StreamServer.in_process_event(stream_server_pid, event)
  catch
    :exit, _reason -> :ok
  end

  defp terminal_chunk?(%StreamChunk{type: :meta, metadata: metadata})
       when is_map(metadata) do
    Map.get(metadata, :terminal?) == true or Map.get(metadata, "terminal?") == true
  end

  defp terminal_chunk?(_chunk), do: false
end
