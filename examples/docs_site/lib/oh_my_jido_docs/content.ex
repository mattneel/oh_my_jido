defmodule OhMyJidoDocs.Content do
  @moduledoc "Safe source-backed Markdown and compare-and-swap publication of immutable snapshots."

  @max_pages 128
  @max_page_bytes 262_144
  @max_total_bytes 4_194_304
  @max_entries 1_024
  @slug ~r/\A[a-z0-9]+(?:[-\/][a-z0-9]+)*\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  @doc "Initializes the editor's publication store from trusted packaged documentation once."
  def bootstrap! do
    if editor?() and is_nil(current_digest()) do
      case publish_directory(packaged_root(), nil) do
        {:ok, _digest} -> :ok
        {:error, :publication_conflict} -> :ok
        {:error, reason} -> raise "Cannot initialize documentation: #{inspect(reason)}"
      end
    else
      :ok
    end
  end

  @doc "Lists the current public pages; draft workspaces are never used as public roots."
  def list_pages do
    case current_files() do
      {:ok, files} ->
        Enum.map(files, fn {path, body} -> %{slug: slug(path), title: title(body, slug(path))} end)

      _ ->
        []
    end
  end

  @doc "Reads and safely renders a published Markdown page, without HEEx evaluation."
  def get_page(slug) when is_binary(slug) do
    with true <- Regex.match?(@slug, slug),
         {:ok, files} <- current_files(),
         {path, body} <- Enum.find(files, fn {path, _body} -> slug(path) == slug end),
         {:ok, html} <-
           MDEx.to_html(body,
             extension: [table: true, strikethrough: true, autolink: true],
             render: [unsafe: false],
             sanitize: MDEx.Document.default_sanitize_options(),
             syntax_highlight: nil
           ) do
      {:ok, %{slug: slug(path), title: title(body, slug), body: body, html: html}}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_page(_slug), do: {:error, :not_found}

  @doc "Returns the current immutable content digest, or nil before first publication."
  def current_digest do
    if editor?() do
      case read_marker(store()) do
        {:ok, digest} -> digest
        :missing -> nil
        {:error, reason} -> raise "Invalid publication pointer: #{inspect(reason)}"
      end
    else
      case inventory(packaged_root()) do
        {:ok, files} -> digest(files)
        {:error, _reason} -> nil
      end
    end
  end

  @doc """
  Publishes exact Markdown bytes only if the authoritative public digest still matches.

  The optional commit authorization runs under the publication lock, after snapshot
  persistence and immediately before replacing the public pointer.
  """
  def publish_directory(source, expected_digest, authorize_commit \\ fn -> :ok end)
      when is_function(authorize_commit, 0) do
    if editor?() do
      publish_source(source, expected_digest, authorize_commit)
    else
      {:error, :editor_disabled}
    end
  end

  defp publish_source(source, expected_digest, authorize_commit) do
    with {:ok, files} <- inventory(source),
         true <- files != [] do
      root = store()

      :global.trans({{__MODULE__, root}, self()}, fn ->
        publish(root, files, expected_digest, authorize_commit)
      end)
    else
      false -> {:error, :empty_documentation}
      {:error, _reason} = error -> error
    end
  end

  defp publish(root, files, expected_digest, authorize_commit) do
    with true <- current_digest() == expected_digest,
         :ok <- File.mkdir_p(Path.join(root, "snapshots")),
         next = digest(files),
         :ok <- persist_snapshot(root, next, files),
         :ok <- authorize_commit.(),
         :ok <- replace_marker(root, next) do
      {:ok, next}
    else
      false -> {:error, :publication_conflict}
      {:error, _reason} = error -> error
    end
  end

  defp current_files do
    if editor?() do
      with {:ok, value} <- read_marker(store()),
           {:ok, files} <- inventory(Path.join([store(), "snapshots", value])),
           true <- digest(files) == value do
        {:ok, files}
      else
        false -> {:error, :snapshot_modified}
        error -> error
      end
    else
      inventory(packaged_root())
    end
  end

  defp persist_snapshot(root, digest, files) do
    destination = Path.join([root, "snapshots", digest])
    temporary = Path.join([root, "snapshots", ".incoming-" <> random_id()])

    case File.lstat(destination) do
      {:ok, %File.Stat{type: :directory}} -> verify_snapshot(destination, files)
      {:error, :enoent} -> write_snapshot(temporary, destination, files)
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp verify_snapshot(destination, files) do
    case inventory(destination) do
      {:ok, ^files} -> :ok
      _ -> {:error, :snapshot_modified}
    end
  end

  defp write_snapshot(temporary, destination, files) do
    with :ok <- File.mkdir(temporary),
         :ok <- write_files(temporary, files) do
      File.rename(temporary, destination)
    end
  after
    File.rm_rf(temporary)
  end

  defp write_files(root, files) do
    Enum.reduce_while(files, :ok, fn {path, body}, :ok ->
      full = Path.join(root, path)

      with :ok <- File.mkdir_p(Path.dirname(full)), :ok <- File.write(full, body, [:exclusive]) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp replace_marker(root, digest) do
    temporary = Path.join(root, ".current-" <> random_id())

    try do
      with :ok <- File.write(temporary, Jason.encode!(%{digest: digest}), [:exclusive]) do
        File.rename(temporary, Path.join(root, "current.json"))
      end
    after
      File.rm(temporary)
    end
  end

  defp read_marker(root) do
    path = Path.join(root, "current.json")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= 128 <- File.lstat(path),
         {:ok, bytes} <- read_limited(path, 128),
         {:ok, %{"digest" => digest}} when is_binary(digest) <- Jason.decode(bytes),
         true <- Regex.match?(@digest, digest) do
      {:ok, digest}
    else
      {:error, :enoent} -> :missing
      _ -> {:error, :invalid_publication_pointer}
    end
  end

  defp inventory(root) when is_binary(root) do
    state = %{files: [], bytes: 0, count: 0, entries: 0}

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, result} <- walk(root, "", state, 0) do
      {:ok, Enum.sort(result.files)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_document_root}
    end
  end

  defp inventory(_root), do: {:error, :invalid_document_root}

  defp walk(root, relative, state, depth) do
    with {:ok, names} <- File.ls(Path.join(root, relative)),
         true <- length(names) <= @max_entries - state.entries do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, state}, &walk_entry(root, relative, &1, &2, depth))
    else
      false -> {:error, :document_entry_limit}
      error -> error
    end
  end

  defp walk_entry(root, relative, name, {:ok, state}, depth) do
    path = if relative == "", do: name, else: relative <> "/" <> name

    case collect(root, path, state, depth) do
      {:ok, next} -> {:cont, {:ok, next}}
      error -> {:halt, error}
    end
  end

  defp collect(_root, _path, %{entries: entries}, _depth) when entries >= @max_entries,
    do: {:error, :document_entry_limit}

  defp collect(root, path, state, depth) do
    with {:ok, stat} <- File.lstat(Path.join(root, path)) do
      collect_entry(stat, root, path, %{state | entries: state.entries + 1}, depth)
    end
  end

  defp collect_entry(%File.Stat{type: :directory}, root, path, state, depth) when depth < 8,
    do: walk(root, path, state, depth + 1)

  defp collect_entry(%File.Stat{type: :directory}, _root, _path, _state, _depth),
    do: {:error, :document_depth_limit}

  defp collect_entry(%File.Stat{type: :regular, size: size}, root, path, state, _depth)
       when state.count < @max_pages and size <= @max_page_bytes and
              state.bytes + size <= @max_total_bytes do
    limit = min(@max_page_bytes, @max_total_bytes - state.bytes)

    with true <- Path.extname(path) == ".md" and Regex.match?(@slug, slug(path)),
         {:ok, body} <- read_limited(Path.join(root, path), limit),
         true <- String.valid?(body) do
      {:ok,
       %{
         state
         | files: [{path, body} | state.files],
           bytes: state.bytes + byte_size(body),
           count: state.count + 1
       }}
    else
      false -> {:error, :invalid_document}
      error -> error
    end
  end

  defp collect_entry(_stat, _root, _path, _state, _depth), do: {:error, :unsafe_document_entry}

  defp read_limited(path, limit) do
    with {:ok, file} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        case :file.read(file, limit + 1) do
          {:ok, bytes} when byte_size(bytes) <= limit -> {:ok, bytes}
          {:ok, _excess} -> {:error, :document_size_limit}
          :eof -> {:ok, <<>>}
          error -> error
        end
      after
        :file.close(file)
      end
    end
  end

  defp slug(path), do: Path.rootname(path, ".md")

  defp title(body, fallback) do
    case Regex.run(~r/^#\s+(.+)$/m, body, capture: :all_but_first) do
      [title] -> title
      _ -> fallback
    end
  end

  defp digest(files) do
    Enum.map(files, fn {path, body} -> [path, 0, :crypto.hash(:sha256, body), 0] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp packaged_root do
    Application.get_env(:oh_my_jido_docs, :static_docs_root) ||
      Path.join(to_string(:code.priv_dir(:oh_my_jido_docs)), "docs")
  end

  defp store, do: Application.fetch_env!(:oh_my_jido_docs, :published_root)
  defp editor?, do: Application.get_env(:oh_my_jido_docs, :editor_enabled, false)
  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
