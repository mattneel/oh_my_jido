# Modified by Oh-My-Jido contributors, 2026-10-13: metadata-only diagnostics and
# opt-in safe metadata collection failures. Original ReqLLM 1.28.0 source remains
# under Apache License 2.0; see LICENSE and UPSTREAM.json in this package.
defmodule ReqLLM.StreamResponse.MetadataHandle do
  @moduledoc """
  Asynchronous metadata cache that allows multiple awaiters to share the same result.

  The handle starts a background process that runs the supplied fetch fun exactly once.
  Callers can await the metadata multiple times without causing repeated fetches or
  task mailbox exhaustion. Call `stop/1` when the cached metadata is no longer needed.
  """

  use GenServer

  require Logger
  alias ReqLLM.Streaming.Failure

  @type t :: pid()

  @spec start_link((-> map()), {module() | (term(), LLMDB.Model.t() -> term()), LLMDB.Model.t()} | nil) ::
          {:ok, t()} | {:error, term()}
  def start_link(fetch_fun, error_context \\ nil) when is_function(fetch_fun, 0) do
    GenServer.start_link(__MODULE__, {fetch_fun, error_context})
  end

  @spec await(t(), timeout()) :: map()
  def await(handle, timeout \\ :infinity) when is_pid(handle) do
    case GenServer.call(handle, :await, timeout) do
      {:ok, metadata} -> metadata
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Stops a metadata handle and any in-progress metadata collection.

  This operation is idempotent and returns `:ok` when the handle has already stopped.
  """
  @spec stop(t()) :: :ok
  def stop(handle) when is_pid(handle) do
    monitor_ref = Process.monitor(handle)
    GenServer.cast(handle, :stop)

    receive do
      {:DOWN, ^monitor_ref, :process, ^handle, _reason} -> :ok
    end
  end

  @impl true
  def init({fetch_fun, error_context}) do
    state = %{fetch_fun: fetch_fun, error_context: error_context, metadata: :pending, waiters: [], worker: nil}
    {:ok, state, {:continue, :collect_metadata}}
  end

  @impl GenServer
  def handle_continue(message, state) do
    dispatch_continue(message, state)
  rescue
    error -> stop_callback_failure(:async, state, :error, error, __STACKTRACE__)
  catch
    kind, reason -> stop_callback_failure(:async, state, kind, reason, __STACKTRACE__)
  end

  @impl GenServer
  def handle_call(message, from, state) do
    dispatch_call(message, from, state)
  rescue
    error -> stop_callback_failure(:call, state, :error, error, __STACKTRACE__)
  catch
    kind, reason -> stop_callback_failure(:call, state, kind, reason, __STACKTRACE__)
  end

  @impl GenServer
  def handle_cast(message, state) do
    dispatch_cast(message, state)
  rescue
    error -> stop_callback_failure(:async, state, :error, error, __STACKTRACE__)
  catch
    kind, reason -> stop_callback_failure(:async, state, kind, reason, __STACKTRACE__)
  end

  @impl GenServer
  def handle_info(message, state) do
    dispatch_info(message, state)
  rescue
    error -> stop_callback_failure(:async, state, :error, error, __STACKTRACE__)
  catch
    kind, reason -> stop_callback_failure(:async, state, kind, reason, __STACKTRACE__)
  end

  # format_status cannot redact OTP's independent original stack/queue report.
  defp stop_callback_failure(type, state, kind, reason, stacktrace) do
    if Failure.normalizer?(state.error_context) do
      error = Failure.normalize(reason, state.error_context)
      Failure.log(error)
      worker = state.worker
      state = metadata_ready(state, %{error: error, finish_reason: :error})
      state = %{state | worker: worker}

      case type do
        :call -> {:stop, {:shutdown, :metadata_callback_failed}, {:error, error}, state}
        :async -> {:stop, {:shutdown, :metadata_callback_failed}, state}
      end
    else
      :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp dispatch_continue(:collect_metadata, %{fetch_fun: fetch_fun} = state) do
    parent = self()
    error_context = state.error_context

    worker =
      :erlang.spawn_opt(
        fn ->
          send(parent, {:metadata_collected, self(), collect_metadata(fetch_fun, error_context)})
        end,
        [:link, :monitor]
      )

    {:noreply, %{state | fetch_fun: nil, worker: worker}}
  end

  defp dispatch_call(:await, _from, %{metadata: {:ready, metadata}} = state) do
    {:reply, {:ok, metadata}, state}
  end

  defp dispatch_call(:await, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  defp dispatch_cast(:stop, state) do
    {:stop, :normal, state}
  end

  defp dispatch_info(
         {:metadata_collected, worker_pid, metadata},
         %{worker: {worker_pid, monitor_ref}} = state
       ) do
    Process.demonitor(monitor_ref, [:flush])
    {:noreply, metadata_ready(state, metadata)}
  end

  defp dispatch_info(
         {:DOWN, monitor_ref, :process, worker_pid, _reason},
         %{worker: {worker_pid, monitor_ref}} = state
       ) do
    Logger.warning("Metadata collection exited")
    {:noreply, metadata_ready(state, metadata_failure(state.error_context))}
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state, %{metadata_ready?: match?({:ready, _}, state.metadata), waiting_callers: length(state.waiters), collecting?: state.worker != nil}}
      {:message, _message} -> {:message, :redacted}
      {:reason, _reason} -> {:reason, :redacted}
      {:log, _log} -> {:log, []}
      field -> field
    end)
  end

  @impl true
  def terminate(_reason, %{worker: {worker_pid, monitor_ref}}) do
    Process.unlink(worker_pid)
    Process.demonitor(monitor_ref, [:flush])
    Process.exit(worker_pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp collect_metadata(fetch_fun, error_context) do
    fetch_fun.()
  rescue
    _error ->
      Logger.warning("Metadata collection failed")
      metadata_failure(error_context)
  catch
    _kind, _reason ->
      Logger.warning("Metadata collection exited")
      metadata_failure(error_context)
  end

  defp metadata_failure(error_context) do
    if Failure.normalizer?(error_context) do
      error = ReqLLM.Error.API.Stream.exception(reason: "Metadata collection failed")
      %{error: Failure.normalize(error, error_context), finish_reason: :error}
    else
      %{}
    end
  end

  defp metadata_ready(state, metadata) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, metadata}))
    %{state | metadata: {:ready, metadata}, waiters: [], worker: nil}
  end
end
