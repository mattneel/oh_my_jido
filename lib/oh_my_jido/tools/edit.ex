defmodule OhMyJido.Tools.Edit do
  @moduledoc "Exact, snapshot-guarded edits that preserve unrelated text and file permissions."

  use Jido.Action,
    name: "edit",
    description:
      "Apply exact nonoverlapping replacements against one original SHA256 snapshot. Ambiguous targets require an explicit one-based occurrence. Stale snapshots never overwrite another writer.",
    category: "filesystem",
    schema:
      Zoi.object(
        %{
          path: Zoi.string(description: "Workspace-relative file path"),
          snapshot: Zoi.string(description: "Complete SHA256 snapshot returned by read"),
          edits:
            Zoi.list(
              Zoi.object(
                %{
                  old: Zoi.string(description: "Exact nonempty bytes to replace") |> Zoi.min(1),
                  new: Zoi.string(description: "Exact replacement bytes; may be empty"),
                  occurrence:
                    Zoi.integer(description: "Explicit occurrence when the target is repeated")
                    |> Zoi.min(1)
                    |> Zoi.max(10_000)
                    |> Zoi.optional()
                },
                coerce: true
              )
            )
            |> Zoi.min(1)
            |> Zoi.max(100)
        },
        coerce: true
      )

  alias OhMyJido.Files

  @spec capability() :: :edit
  def capability, do: :edit

  @impl true
  def run(params, context) do
    Files.edit(
      context,
      Map.get(params, :path),
      Map.get(params, :snapshot),
      Map.get(params, :edits)
    )
  end
end
