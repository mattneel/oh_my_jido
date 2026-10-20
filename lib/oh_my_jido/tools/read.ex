defmodule OhMyJido.Tools.Read do
  @moduledoc "A bounded, root-confined exact file read with a whole-file SHA256 snapshot."

  use Jido.Action,
    name: "read",
    description:
      "Read exact UTF-8 text or detect binary data. Inclusive line ranges retain original newline bytes; the SHA256 snapshot always covers the whole file.",
    schema:
      Zoi.object(
        %{
          path: Zoi.string(description: "Workspace-relative file path"),
          start_line:
            Zoi.integer(description: "First line, inclusive and one-based")
            |> Zoi.min(1)
            |> Zoi.optional(),
          end_line:
            Zoi.integer(description: "Last line, inclusive") |> Zoi.min(1) |> Zoi.optional(),
          max_bytes:
            Zoi.integer(description: "Maximum returned bytes, subject to host limits")
            |> Zoi.min(1)
            |> Zoi.optional()
        },
        coerce: true
      )

  alias OhMyJido.Files

  @doc "Returns the Action category."
  def category, do: "filesystem"

  @spec capability() :: :read
  def capability, do: :read

  @impl true
  def run(params, context) do
    Files.read(
      context,
      Map.get(params, :path),
      Map.to_list(Map.take(params, [:start_line, :end_line, :max_bytes]))
    )
  end
end
