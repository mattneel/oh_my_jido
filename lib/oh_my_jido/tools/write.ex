defmodule OhMyJido.Tools.Write do
  @moduledoc "Atomically creates or replaces one confined file with a mandatory snapshot guard."

  use Jido.Action,
    name: "write",
    description:
      "Atomically write UTF-8 content. Supply the read's complete SHA256 snapshot to replace a file, or the literal missing to create without overwriting.",
    category: "filesystem",
    schema:
      Zoi.object(
        %{
          path:
            Zoi.string(
              description: "Workspace-relative file path with existing parent directories"
            ),
          content:
            Zoi.string(description: "Exact replacement content; newline bytes are not normalized"),
          snapshot: Zoi.string(description: "Whole-file SHA256 snapshot, or missing for creation")
        },
        coerce: true
      )

  alias OhMyJido.Files

  @spec capability() :: :edit
  def capability, do: :edit

  @impl true
  def run(params, context) do
    Files.write(
      context,
      Map.get(params, :path),
      Map.get(params, :content),
      Map.get(params, :snapshot)
    )
  end
end
