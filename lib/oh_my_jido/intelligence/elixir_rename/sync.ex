defmodule OhMyJido.Intelligence.ElixirRename.Sync do
  @moduledoc false

  alias OhMyJido.Intelligence.{Stdio, TextEdits}

  # Definitions must describe these exact bytes, not merely a buffer with an
  # unchanged version. Only real, confined inventory contents are synchronized;
  # no speculative rename, synthetic document, or filesystem write occurs here.
  def documents(context, server, inventory, opts) do
    with {:ok, rows} <- rows(context, inventory),
         {:ok, versions} <- Stdio.document_versions(server),
         {:ok, sources} <- Stdio.document_sources(server),
         :ok <- canonical_documents(context, rows, sources),
         {:ok, synchronized} <- synchronize(server, rows, versions, sources, opts),
         {:ok, versions} <- Stdio.document_versions(server),
         {:ok, sources} <- Stdio.document_sources(server),
         {:ok, inputs} <- checked_inputs(rows, versions, sources) do
      {:ok, versions, inputs, synchronized}
    end
  end

  def current(server, versions, inputs) do
    with {:ok, current_versions} <- Stdio.document_versions(server),
         true <- current_versions == versions,
         {:ok, sources} <- Stdio.document_sources(server) do
      Enum.reduce_while(inputs, :ok, &current_input(&1, &2, sources))
    else
      false -> {:error, :elixir_rename_server_documents_changed}
      {:error, _} = error -> error
    end
  end

  defp current_input({uri, expected}, :ok, sources) do
    if Map.get(sources, uri) == expected,
      do: {:cont, :ok},
      else: {:halt, {:error, {:elixir_rename_server_source_changed, uri}}}
  end

  defp rows(context, inventory) do
    inventory
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {_path, source}, {:ok, acc} ->
      case TextEdits.uri(context, source.path) do
        {:ok, uri} -> {:cont, {:ok, [{uri, source} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp canonical_documents(context, rows, sources) do
    canonical = Map.new(rows, fn {uri, source} -> {source.path, uri} end)

    Enum.reduce_while(sources, :ok, &canonical_document(&1, &2, context, canonical))
  end

  defp canonical_document({uri, _source}, :ok, context, canonical) do
    case TextEdits.uri_path(context, uri) do
      {:ok, path} ->
        if Map.has_key?(canonical, path) and canonical[path] != uri,
          do: {:halt, {:error, {:elixir_rename_ambiguous_native_document_uri, uri}}},
          else: {:cont, :ok}

      {:error, _} ->
        {:cont, :ok}
    end
  end

  defp synchronize(server, rows, versions, sources, opts) do
    rows
    |> Enum.reduce_while(
      {:ok, []},
      &synchronize_document(&1, &2, server, versions, sources, opts)
    )
    |> case do
      {:ok, synchronized} -> {:ok, Enum.reverse(synchronized)}
      error -> error
    end
  end

  defp synchronize_document({uri, source}, {:ok, synchronized}, server, versions, sources, opts) do
    case synchronization(Map.fetch(versions, uri), Map.fetch(sources, uri), source.snapshot) do
      {:ok, :current} ->
        {:cont, {:ok, synchronized}}

      {:ok, operation} ->
        with {:ok, version} <- Stdio.document_version(server, uri, operation),
             :ok <- notify(server, uri, version, source.content, operation, opts) do
          evidence = %{
            path: source.path,
            snapshot: source.snapshot,
            version: version,
            operation: operation
          }

          {:cont, {:ok, [evidence | synchronized]}}
        else
          {:error, _} = error -> {:halt, error}
        end

      {:error, reason} ->
        {:halt, {:error, {reason, source.path}}}
    end
  end

  defp synchronization(:error, :error, _snapshot), do: {:ok, :open}

  defp synchronization({:ok, version}, {:ok, %{version: version, snapshot: snapshot}}, snapshot)
       when is_integer(version) and version > 0,
       do: {:ok, :current}

  defp synchronization({:ok, version}, {:ok, %{version: version, snapshot: _snapshot}}, _expected)
       when is_integer(version) and version > 0,
       do: {:ok, :change}

  defp synchronization({:ok, _version}, {:ok, _source}, _snapshot),
    do: {:error, :elixir_rename_native_document_sync_in_progress}

  defp synchronization(_version, _source, _snapshot),
    do: {:error, :elixir_rename_untracked_native_document}

  defp notify(server, uri, version, content, :open, opts) do
    Stdio.notify(server, "textDocument/didOpen", %{
      "textDocument" => %{
        "uri" => uri,
        "version" => version,
        "languageId" => Keyword.get(opts, :language_id, "elixir"),
        "text" => content
      }
    })
  end

  defp notify(server, uri, version, content, :change, _opts) do
    Stdio.notify(server, "textDocument/didChange", %{
      "textDocument" => %{"uri" => uri, "version" => version},
      "contentChanges" => [%{"text" => content}]
    })
  end

  defp checked_inputs(rows, versions, sources) do
    Enum.reduce_while(rows, {:ok, %{}}, &checked_input(&1, &2, versions, sources))
  end

  defp checked_input({uri, source}, {:ok, acc}, versions, sources) do
    case Map.fetch(sources, uri) do
      {:ok, %{version: version, snapshot: snapshot} = input}
      when is_integer(version) and version > 0 and snapshot == source.snapshot ->
        if versions[uri] == version,
          do: {:cont, {:ok, Map.put(acc, uri, input)}},
          else: {:halt, {:error, {:elixir_rename_native_document_sync_in_progress, source.path}}}

      _ ->
        {:halt, {:error, {:elixir_rename_native_source_not_synchronized, source.path}}}
    end
  end
end
