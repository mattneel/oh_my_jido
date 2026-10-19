defmodule OhMyJido.Tools.Artifact do
  @moduledoc "Confined image and generated-artifact inputs interpreted by approved host callbacks."

  use Jido.Action,
    name: "artifact",
    description:
      "Inspect a local artifact or read text through a confined, approved host adapter",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["inspect", "read_text"]),
          path: Zoi.string() |> Zoi.min(1) |> Zoi.max(4096),
          kind: Zoi.enum(["auto", "image", "text", "binary"]) |> Zoi.default("auto"),
          max_input_bytes:
            Zoi.integer() |> Zoi.min(1) |> Zoi.max(33_554_432) |> Zoi.default(8_388_608),
          max_output_bytes: Zoi.integer() |> Zoi.min(64) |> Zoi.max(131_072) |> Zoi.default(8192)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Extensions.Artifact}

  def capability, do: :artifact

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, context} <- Context.fetch(execution_context) do
      Artifact.perform(context, params)
    end
  end
end
