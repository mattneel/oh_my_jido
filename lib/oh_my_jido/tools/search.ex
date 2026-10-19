defmodule OhMyJido.Tools.Search do
  @moduledoc "Bounded literal or regex search with stable paths and ripgrep ignore rules."

  use Jido.Action,
    name: "search",
    description:
      "Search UTF-8 repository files with relative paths, one-based lines and byte columns. Respect gitignore/ignore rules, skip binary files and report every truncation. No shell or executable is supplied by the model.",
    category: "filesystem",
    schema:
      Zoi.object(
        %{
          pattern:
            Zoi.string(description: "Nonempty literal or regular expression") |> Zoi.min(1),
          path:
            Zoi.string(description: "File or directory within the workspace") |> Zoi.default("."),
          glob:
            Zoi.string(description: "Relative ripgrep glob, for example lib/**/*.ex")
            |> Zoi.default("**/*"),
          mode: Zoi.enum(["literal", "regex"]) |> Zoi.default("literal"),
          case_sensitive: Zoi.boolean() |> Zoi.default(true),
          hidden:
            Zoi.boolean(description: "Include hidden paths, never Git internals")
            |> Zoi.default(false),
          ignore: Zoi.boolean(description: "Respect workspace ignore rules") |> Zoi.default(true),
          max_results: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
          max_bytes:
            Zoi.integer(description: "Maximum JSON bytes of retained entries")
            |> Zoi.min(1)
            |> Zoi.optional(),
          max_line_bytes:
            Zoi.integer(description: "Maximum text bytes per result line")
            |> Zoi.min(1)
            |> Zoi.optional()
        },
        coerce: true
      )

  alias OhMyJido.Search, as: RepositorySearch

  @spec capability() :: :read
  def capability, do: :read

  @impl true
  def run(params, context) do
    options =
      Map.to_list(
        Map.take(params, [
          :path,
          :glob,
          :mode,
          :case_sensitive,
          :hidden,
          :ignore,
          :max_results,
          :max_bytes,
          :max_line_bytes
        ])
      )

    RepositorySearch.text(context, Map.get(params, :pattern), options)
  end
end
