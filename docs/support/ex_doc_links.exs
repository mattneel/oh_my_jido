# Loaded only by the `mix docs` alias in mix.exs; not part of the library.
#
# The guides use GitHub-relative links. ExDoc resolves `.md` links by file
# name alone, so links to the several README.md files collide, and links to
# repository files that are not ExDoc pages break. This Markdown processor
# rewrites relative links in extras before ExDoc sees them:
#
#   * a link to another ExDoc page becomes that page's HTML file, with the
#     GitHub heading anchor translated to ExDoc's heading id;
#   * a link to any other repository path becomes a GitHub URL on the branch
#     the docs describe.
#
# Everything else is delegated to ExDoc's default Earmark processor.
defmodule OhMyJido.ExDocLinks do
  @moduledoc false

  alias ExDoc.Markdown.Earmark

  def available?, do: Earmark.available?()

  def to_ast(text, options) do
    {config, options} = Keyword.split(options, [:extras, :source_url, :source_ref])
    ast = Earmark.to_ast(text, options)

    case Keyword.fetch(options, :file) do
      {:ok, file} when is_binary(file) ->
        if Path.extname(file) == ".md", do: rewrite(ast, file, config), else: ast

      _other ->
        ast
    end
  end

  defp rewrite(ast, file, config) do
    root = File.cwd!()
    pages = pages(root, config)
    source = Path.expand(file, root)
    walk(ast, &rewrite_link(&1, source, root, pages, config))
  end

  defp walk(nodes, fun) when is_list(nodes), do: Enum.map(nodes, &walk(&1, fun))

  defp walk({:a, attrs, children, meta}, fun),
    do: {:a, fun.(attrs), walk(children, fun), meta}

  defp walk({tag, attrs, children, meta}, fun), do: {tag, attrs, walk(children, fun), meta}
  defp walk(other, _fun), do: other

  defp rewrite_link(attrs, source, root, pages, config) do
    case Keyword.fetch(attrs, :href) do
      {:ok, href} -> Keyword.put(attrs, :href, target(href, source, root, pages, config))
      :error -> attrs
    end
  end

  defp target("#" <> fragment, source, _root, pages, _config) do
    case Map.fetch(pages, source) do
      {:ok, {_filename, anchors}} -> fragment_suffix(anchors, fragment)
      :error -> "#" <> fragment
    end
  end

  defp target(href, source, root, pages, config) do
    uri = URI.parse(href)

    if uri.scheme || uri.host || uri.path in [nil, ""] do
      href
    else
      path = Path.expand(URI.decode(uri.path), Path.dirname(source))
      relative = Path.relative_to(path, root)

      cond do
        Path.type(relative) == :absolute or String.starts_with?(relative, "../") ->
          href

        match?({:ok, _page}, Map.fetch(pages, path)) ->
          {filename, anchors} = Map.fetch!(pages, path)
          filename <> ".html" <> fragment_suffix(anchors, uri.fragment)

        true ->
          kind = if File.dir?(path), do: "tree", else: "blob"
          fragment = if uri.fragment, do: "#" <> uri.fragment, else: ""
          "#{config[:source_url]}/#{kind}/#{config[:source_ref]}/#{relative}#{fragment}"
      end
    end
  end

  defp fragment_suffix(_anchors, nil), do: ""

  defp fragment_suffix(anchors, fragment) do
    case Map.fetch(anchors, fragment) do
      {:ok, id} -> "#" <> id
      :error -> ""
    end
  end

  # Maps each ExDoc extra's absolute path to its HTML file name and a table
  # from GitHub heading anchors to ExDoc heading ids (ExDoc ids h2/h3 only).
  defp pages(root, config) do
    key = {__MODULE__, root, config[:extras]}

    case Process.get(key) do
      nil ->
        pages =
          Map.new(config[:extras], fn {input, opts} ->
            input = to_string(input)
            path = Path.expand(input, root)

            filename =
              opts[:filename] ||
                input |> Path.basename() |> Path.rootname() |> ExDoc.Utils.text_to_id()

            {path, {filename, anchors(path)}}
          end)

        Process.put(key, pages)
        pages

      pages ->
        pages
    end
  end

  defp anchors(path) do
    if Path.extname(path) == ".md" and File.regular?(path) do
      path
      |> File.read!()
      |> Earmark.to_ast(file: path, line: 1)
      |> headings()
      |> Enum.reduce({%{}, %{}, %{}}, fn {tag, text}, {anchors, github_seen, exdoc_seen} ->
        {github, github_seen} = numbered(github_anchor(text), github_seen)

        if tag in [:h2, :h3] do
          {exdoc, exdoc_seen} = numbered(ExDoc.Utils.text_to_id(text), exdoc_seen)
          {Map.put(anchors, github, exdoc), github_seen, exdoc_seen}
        else
          {anchors, github_seen, exdoc_seen}
        end
      end)
      |> elem(0)
    else
      %{}
    end
  end

  defp headings(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &headings/1)

  defp headings({tag, _attrs, children, _meta}) when tag in [:h1, :h2, :h3, :h4, :h5, :h6],
    do: [{tag, ExDoc.DocAST.text(children)}]

  defp headings({_tag, _attrs, children, _meta}), do: headings(children)
  defp headings(_other), do: []

  defp numbered(base, seen) do
    count = Map.get(seen, base, 0)
    id = if count == 0, do: base, else: "#{base}-#{count}"
    {id, Map.put(seen, base, count + 1)}
  end

  # GitHub's heading anchor: lowercase, drop punctuation except hyphens and
  # underscores, and turn each whitespace character into a hyphen.
  defp github_anchor(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\p{M}\s_-]/u, "")
    |> String.replace(~r/\s/u, "-")
  end
end
