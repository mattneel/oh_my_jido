defmodule OhMyJidoBrowser.EvalProbes do
  @moduledoc """
  Eval probes that need the browser's own kernels: JavaScript in the page and
  Python in Pyodide. They call the app runtime's Eval server directly.
  """

  alias OhMyJido.{Context, Eval, Runtime}

  @doc "Runs the Eval probes and returns one result map per probe."
  @spec run(String.t()) :: [map()]
  def run(root) do
    workspace = Path.join(root, "eval")
    File.mkdir_p!(workspace)
    server = Runtime.eval(OhMyJidoBrowser.Runtime)
    id = "eval-probes-#{System.unique_integer([:positive])}"

    {:ok, context} =
      Context.new(session_id: id, workspace: workspace, permissions: [:eval])

    try do
      [
        probe("E05", "Eval output", fn -> output(server, context) end),
        probe("E06", "Eval safety", fn -> safety(server, context, workspace) end)
      ]
    after
      Eval.close_session(server, id)
    end
  end

  defp output(server, context) do
    with {:ok, %{status: :ok, display: "3", stdout: "hello\n"}} <-
           Eval.execute(server, context, :javascript, "console.log('hello'); return 1 + 2;"),
         {:ok, %{status: :error, error: error}} <-
           Eval.execute(server, context, :javascript, "throw new Error('boom')"),
         true <- String.contains?(error, "boom"),
         {:ok, %{truncated: true}} <-
           Eval.execute(server, context, :javascript, "console.log('x'.repeat(5000))",
             output_limit: 1_000
           ),
         {:ok, %{status: :ok}} <- Eval.execute(server, context, :python, "answer = 41"),
         {:ok, %{status: :ok, display: "42", stdout: "ready\n"}} <-
           Eval.execute(server, context, :python, "print('ready')\nanswer + 1") do
      {:ok, "stdout, display values, errors, truncation and Python state across cells"}
    else
      other -> {:error, inspect(other)}
    end
  end

  defp safety(server, context, workspace) do
    {:ok, denied} = Context.new(session_id: "denied", workspace: workspace, permissions: [])

    with {:error, {:permission_denied, :eval}} <-
           Eval.execute(server, denied, :javascript, "1"),
         {:ok, %{status: :timeout, kernel_state: :invalidated, cleanup: :confirmed}} <-
           Eval.execute(server, context, :python, "while True:\n    pass", timeout: 1_000),
         {:error, {:kernel_invalidated, _reason}} <-
           Eval.execute(server, context, :python, "1"),
         {:ok, _info} <- Eval.reset(server, context, :python),
         {:ok, %{status: :ok, display: "2"}} <- Eval.execute(server, context, :python, "1 + 1") do
      {:ok, "permission check, hard timeout of a busy Python cell, invalidation and reset"}
    else
      other -> {:error, inspect(other)}
    end
  end

  defp probe(id, capability, fun) do
    started = System.monotonic_time(:millisecond)

    {status, detail} =
      try do
        case fun.() do
          {:ok, detail} -> {:passed, detail}
          {:error, detail} -> {:failed, detail}
        end
      rescue
        error -> {:failed, Exception.message(error)}
      catch
        kind, reason -> {:failed, inspect({kind, reason})}
      end

    %{
      id: id,
      capability: capability,
      status: status,
      detail: detail,
      ms: System.monotonic_time(:millisecond) - started
    }
  end
end
