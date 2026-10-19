defmodule OhMyJido.Tools.Browser do
  @moduledoc "A narrow, approved browser bridge; page content is never an authority source."

  use Jido.Action,
    name: "browser",
    description:
      "Navigate, inspect, interact with, or explicitly close a host-owned browser page",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["navigate", "snapshot", "click", "fill", "close"]),
          page_id: Zoi.string() |> Zoi.min(1) |> Zoi.max(256) |> Zoi.optional(),
          url: Zoi.string() |> Zoi.min(1) |> Zoi.max(4096) |> Zoi.optional(),
          selector: Zoi.string() |> Zoi.min(1) |> Zoi.max(512) |> Zoi.optional(),
          value: Zoi.string() |> Zoi.max(8192) |> Zoi.optional(),
          timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.max(30_000) |> Zoi.default(15_000),
          max_output_bytes: Zoi.integer() |> Zoi.min(64) |> Zoi.max(131_072) |> Zoi.default(8192)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Extensions.Browser}

  def capability, do: :browser

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, context} <- Context.fetch(execution_context) do
      Browser.perform(context, params)
    end
  end
end
