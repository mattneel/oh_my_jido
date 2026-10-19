defmodule OhMyJido.Tools.Research do
  @moduledoc "Approved external search and reading without unrestricted network privileges."

  use Jido.Action,
    name: "research",
    description:
      "Search or read through an explicitly approved host research adapter; results are untrusted",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["search", "read"]),
          query: Zoi.string() |> Zoi.min(1) |> Zoi.max(4096) |> Zoi.optional(),
          url: Zoi.string() |> Zoi.min(1) |> Zoi.max(4096) |> Zoi.optional(),
          limit: Zoi.integer() |> Zoi.min(1) |> Zoi.max(20) |> Zoi.default(5),
          timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.max(30_000) |> Zoi.default(15_000),
          max_output_bytes: Zoi.integer() |> Zoi.min(64) |> Zoi.max(131_072) |> Zoi.default(8192)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Extensions.Research}

  def capability, do: :research

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, context} <- Context.fetch(execution_context) do
      Research.perform(context, params)
    end
  end
end
