defmodule OhMyJido.Tools.List do
  @moduledoc "Bounded stable-path glob listing with workspace ignore rules."

  use Jido.Action,
    name: "list",
    description:
      "List repository file paths with ripgrep glob/ignore rules. Results are sorted and workspace-relative; symlink escapes and Git internals are excluded, and output limits are explicit.",
    category: "filesystem",
    schema:
      Zoi.object(
        %{
          path:
            Zoi.string(description: "File or directory within the workspace") |> Zoi.default("."),
          glob:
            Zoi.string(description: "Relative ripgrep glob, for example **/*.{ex,exs}")
            |> Zoi.default("**/*"),
          hidden:
            Zoi.boolean(description: "Include hidden paths, never Git internals")
            |> Zoi.default(false),
          ignore: Zoi.boolean(description: "Respect workspace ignore rules") |> Zoi.default(true),
          max_results: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
          max_bytes:
            Zoi.integer(description: "Maximum JSON bytes of retained entries")
            |> Zoi.min(1)
            |> Zoi.optional()
        },
        coerce: true
      )

  alias OhMyJido.Search

  @spec capability() :: :read
  def capability, do: :read

  @impl true
  def run(params, context) do
    options = Map.to_list(Map.take(params, [:glob, :hidden, :ignore, :max_results, :max_bytes]))
    Search.files(context, Map.get(params, :path, "."), options)
  end
end
