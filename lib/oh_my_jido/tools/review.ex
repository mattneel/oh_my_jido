defmodule OhMyJido.Tools.Review do
  @moduledoc "Risk review anchored to actual workspace Git diffs, not a submitted diff string."

  use Jido.Action,
    name: "review",
    description:
      "Inspect actual tracked Git changes for possible secrets, dynamic execution and destructive effects",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["diff"]) |> Zoi.default("diff"),
          source: Zoi.enum(["git", "host"]) |> Zoi.default("git"),
          staged: Zoi.boolean() |> Zoi.default(false),
          paths:
            Zoi.list(Zoi.string() |> Zoi.min(1) |> Zoi.max(4096))
            |> Zoi.max(20)
            |> Zoi.default([]),
          enrich: Zoi.boolean() |> Zoi.default(false),
          timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.max(30_000) |> Zoi.default(15_000),
          max_diff_bytes:
            Zoi.integer() |> Zoi.min(256) |> Zoi.max(262_144) |> Zoi.default(65_536),
          max_findings: Zoi.integer() |> Zoi.min(1) |> Zoi.max(100) |> Zoi.default(50)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Extensions.Review}

  def capability, do: :review

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, context} <- Context.fetch(execution_context) do
      Review.perform(context, params)
    end
  end
end
