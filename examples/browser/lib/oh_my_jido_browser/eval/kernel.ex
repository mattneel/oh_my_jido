defmodule OhMyJidoBrowser.Eval.Kernel do
  @moduledoc """
  Shared implementation of the browser Eval backends.

  A language module supplies the page functions that open, run and close its
  kernels (exported by `public/eval.js` as `window.ohMyJidoEval`). Each kernel
  has an `OhMyJidoBrowser.Eval.Worker` that the Eval controller monitors.
  """

  alias OhMyJidoBrowser.Eval.Worker
  alias Popcorn.JS

  @type functions :: %{open: String.t(), run: String.t(), close: String.t()}

  @doc "Opens a page-side kernel and its worker."
  @spec open(functions(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(functions, opts) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    boot_timeout = Keyword.get(opts, :boot_timeout, 60_000)

    {:ok, worker} =
      Worker.start_link(bridge: Keyword.fetch!(opts, :bridge), id: id, close: functions.close)

    case JS.run(functions.open, %{id: id, worker: worker}, timeout: boot_timeout) do
      {:ok, true} ->
        {:ok, %{id: id, worker: worker, functions: functions, opts: opts}}

      {:ok, other} ->
        stop(worker)
        {:error, {:backend_unavailable, Keyword.get(opts, :language), other}}

      {:error, reason} ->
        stop(worker)
        {:error, {:backend_unavailable, Keyword.get(opts, :language), reason}}
    end
  end

  @doc "Runs one cell and maps the page result to an Eval backend result."
  @spec execute(map(), map()) :: {:ok, map()} | {:error, term()}
  def execute(handle, request) do
    :ok = Worker.activate(handle.worker, request)

    case JS.run(
           handle.functions.run,
           %{id: handle.id, source: request.source, worker: handle.worker},
           timeout: request.timeout
         ) do
      {:ok, %{"status" => "ok"} = result} ->
        {:ok, %{status: :ok, display: Map.get(result, "display", "")}}

      {:ok, %{"status" => "error"} = result} ->
        {:ok, %{status: :error, display: "", error: Map.get(result, "error", "error")}}

      {:error, :timeout} ->
        {:ok, %{status: :timeout}}

      {:error, reason} ->
        {:error, {:browser_kernel_failed, reason}}
    end
  end

  @doc "Closes the page-side kernel and stops its worker."
  @spec close(map()) :: :ok
  def close(handle) do
    stop(handle.worker)
    :ok
  end

  @doc "Replaces the kernel with a fresh one; the next generation starts empty."
  @spec reset(map()) :: {:ok, map()} | {:error, term()}
  def reset(handle) do
    :ok = close(handle)
    open(handle.functions, Keyword.update(handle.opts, :generation, 1, &(&1 + 1)))
  end

  defp stop(worker) do
    if Process.alive?(worker), do: GenServer.stop(worker, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
