defmodule OhMyJido.Tools.Eval do
  @moduledoc "One permission-checked Jido Action for all configured persistent Eval backends."
  use Jido.Action,
    name: "eval",
    description:
      "Execute a persistent Elixir, JavaScript or Python cell, or explicitly manage its kernel. Hard cancellation invalidates state until reset.",
    schema:
      Zoi.object(%{
        language: Zoi.enum(["elixir", "javascript", "python"]),
        operation:
          Zoi.enum(["execute", "open", "interrupt", "reset", "close"]) |> Zoi.default("execute"),
        source: Zoi.string() |> Zoi.default(""),
        timeout: Zoi.integer() |> Zoi.default(30_000),
        output_limit: Zoi.integer() |> Zoi.default(65_536),
        cell_id: Zoi.string() |> Zoi.optional()
      })

  alias OhMyJido.{Context, Eval, Runtime, Tool}

  def capability, do: :eval

  @impl true
  def run(params, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <-
           Tool.authorize(context, :eval, %{
             language: params.language,
             operation: params.operation
           }),
         server when is_pid(server) <- eval_server(context),
         {:ok, result} <- dispatch(server, context, language(params.language), params) do
      {:ok, Map.drop(result, [:worker, :controller, :last_used])}
    else
      nil -> {:error, :eval_unavailable}
      {:error, _reason} = error -> error
      _other -> {:error, :eval_unavailable}
    end
  end

  defp eval_server(%Context{metadata: %{eval: server}}), do: server

  defp eval_server(%Context{runtime: runtime}) when is_atom(runtime) and not is_nil(runtime),
    do: Runtime.eval(runtime)

  defp eval_server(_context), do: nil

  defp dispatch(server, context, language, %{operation: "execute"} = params) do
    opts = [
      timeout: params.timeout,
      output_limit: params.output_limit,
      cell_id: Map.get(params, :cell_id)
    ]

    Eval.execute(server, context, language, params.source, opts)
  end

  defp dispatch(server, context, language, %{operation: "open"}),
    do: Eval.open(server, context, language)

  defp dispatch(server, context, language, %{operation: "reset"}),
    do: Eval.reset(server, context, language)

  defp dispatch(server, context, language, %{operation: "interrupt"}) do
    with :ok <- Eval.interrupt(server, context.session_id, language),
         do: {:ok, %{status: :cancelled}}
  end

  defp dispatch(server, context, language, %{operation: "close"}) do
    with :ok <- Eval.close(server, context.session_id, language), do: {:ok, %{status: :closed}}
  end

  defp language("elixir"), do: :elixir
  defp language("javascript"), do: :javascript
  defp language("python"), do: :python
end
