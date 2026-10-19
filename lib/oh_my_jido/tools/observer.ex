defmodule OhMyJido.Tools.Observer do
  @moduledoc "Headless, bounded live OTP observations through a trusted host target."

  use Jido.Action,
    name: "observer",
    description:
      "Inspect a configured live Elixir application's OTP metrics, applications, process metadata, supervision tree and ETS metadata. Read-only; never reads process state, dictionaries, messages or table contents.",
    schema:
      Zoi.object(
        %{
          operation:
            Zoi.enum([
              "overview",
              "applications",
              "processes",
              "process",
              "supervision",
              "ets",
              "table"
            ]),
          pid: Zoi.string() |> Zoi.max(64) |> Zoi.optional(),
          table: Zoi.string() |> Zoi.max(256) |> Zoi.optional(),
          root: Zoi.string() |> Zoi.max(256) |> Zoi.optional(),
          limit: Zoi.integer() |> Zoi.min(1) |> Zoi.max(200) |> Zoi.default(50),
          offset: Zoi.integer() |> Zoi.min(0) |> Zoi.max(100_000) |> Zoi.default(0),
          depth: Zoi.integer() |> Zoi.min(1) |> Zoi.max(5) |> Zoi.default(3)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Host, Tool}

  @operations Map.new(
                ~w(overview applications processes process supervision ets table)a,
                &{Atom.to_string(&1), &1}
              )

  @doc false
  def capability, do: :observe

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, params} <- Jido.Action.Schema.validate(schema(), params),
         {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, :observe, Map.take(params, [:operation, :root, :pid])),
         {:ok, operation} <- Map.fetch(@operations, params.operation),
         request = Map.put(params, :operation, operation),
         {:ok, result} <- Host.call(context, :invoke, [:observer, request]),
         :ok <- OhMyJido.Intelligence.Observer.bounded(context, result) do
      {:ok, result}
    else
      :error -> {:error, :unsupported_observer_operation}
      error -> error
    end
  end
end
