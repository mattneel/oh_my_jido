defmodule OhMyJido.Intelligence.TextEdits do
  @moduledoc """
  Converts LSP UTF-16 workspace edits into snapshot-guarded file writes.

  Resource creation, removal and rename commands are not granted. Every edited
  document requires a caller snapshot when applying; preview does not mutate.
  A multi-document conflict reports the already-applied paths explicitly rather
  than silently replaying or claiming transactional success.
  """

  alias OhMyJido.{Files, Workspace}

  @max_documents 32
  @max_edits 1_000

  @spec plan(map(), map(), map()) :: {:ok, [map()]} | {:error, term()}
  def plan(context, workspace_edit, snapshots) do
    with {:ok, documents} <- documents(workspace_edit),
         true <- map_size(documents) <= @max_documents do
      Enum.reduce_while(
        Enum.sort(documents),
        {:ok, []},
        &plan_document(context, &1, snapshots, &2)
      )
      |> case do
        {:ok, plans} -> {:ok, Enum.reverse(plans)}
        error -> error
      end
    else
      false -> {:error, :lsp_document_limit}
      {:error, _} = error -> error
    end
  end

  defp plan_document(context, {uri, %{edits: edits, version: version}}, snapshots, {:ok, plans}) do
    with {:ok, path} <- uri_path(context, uri),
         {:ok, file} <- Files.read_bytes(context, path),
         false <- file.binary,
         {:ok, content} <- transform(file.content, edits) do
      entry = %{
        path: path,
        uri: uri,
        version: version,
        snapshot: file.snapshot,
        expected_snapshot: Map.get(snapshots, path),
        content: content,
        edits: edits
      }

      {:cont, {:ok, [entry | plans]}}
    else
      true -> {:halt, {:error, :lsp_binary_document}}
      {:error, _} = error -> {:halt, error}
    end
  end

  @spec apply(map(), [map()]) :: {:ok, [map()]} | {:error, term()}
  @spec apply(map(), [map()], map()) :: {:ok, [map()]} | {:error, term()}
  def apply(context, plans, document_versions \\ %{}) do
    with :ok <- versions_current(plans, document_versions),
         :ok <- snapshots_present(plans),
         :ok <- snapshots_current(plans) do
      Enum.reduce_while(plans, {:ok, []}, &apply_document(context, &1, &2))
      |> case do
        {:ok, applied} -> {:ok, Enum.reverse(applied)}
        error -> error
      end
    end
  end

  defp apply_document(context, plan, {:ok, applied}) do
    case Files.write(context, plan.path, plan.content, plan.expected_snapshot) do
      {:ok, result} ->
        {:cont, {:ok, [Map.take(result, [:path, :snapshot, :bytes]) | applied]}}

      {:error, reason} ->
        {:halt,
         {:error,
          %{
            reason: :workspace_edit_conflict,
            failed_path: plan.path,
            applied: Enum.reverse(applied),
            failure: reason
          }}}
    end
  end

  @spec uri(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def uri(context, path) do
    with {:ok, absolute} <- Workspace.resolve(context, path) do
      {:ok, "file://" <> URI.encode(absolute, &(&1 == ?/ or URI.char_unreserved?(&1)))}
    end
  end

  @spec uri_path(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def uri_path(context, uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", host: host, path: path, query: nil, fragment: nil}
      when host in [nil, "", "localhost"] and is_binary(path) ->
        with {:ok, absolute} <- Workspace.resolve(context, URI.decode(path)) do
          {:ok, Workspace.relative(context, absolute)}
        end

      _ ->
        {:error, :lsp_uri_not_granted}
    end
  end

  def uri_path(_context, _uri), do: {:error, :lsp_uri_not_granted}

  @spec transform(String.t(), [map()]) :: {:ok, String.t()} | {:error, term()}
  def transform(source, edits) when is_list(edits) and length(edits) <= @max_edits do
    with {:ok, located} <- locate_edits(source, edits) do
      located
      |> Enum.reverse()
      |> Enum.sort_by(& &1.start)
      |> Enum.reduce_while({:ok, [], 0}, &splice_edit(source, &1, &2))
      |> case do
        {:ok, chunks, offset} ->
          {:ok,
           IO.iodata_to_binary(
             Enum.reverse([binary_part(source, offset, byte_size(source) - offset) | chunks])
           )}

        error ->
          error
      end
    end
  end

  def transform(_source, _edits), do: {:error, :lsp_edit_limit}

  defp splice_edit(_source, edit, {:ok, _chunks, offset}) when edit.start < offset,
    do: {:halt, {:error, :lsp_overlapping_edits}}

  defp splice_edit(source, edit, {:ok, chunks, offset}) do
    unchanged = binary_part(source, offset, edit.start - offset)
    {:cont, {:ok, [edit.text, unchanged | chunks], edit.end}}
  end

  defp documents(%{"changes" => changes} = edit) when is_map(changes) do
    if Map.has_key?(edit, "documentChanges"),
      do: {:error, :ambiguous_workspace_edit},
      else: {:ok, Map.new(changes, fn {uri, edits} -> {uri, %{edits: edits, version: nil}} end)}
  end

  defp documents(%{"documentChanges" => changes}) when is_list(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn
      %{"textDocument" => %{"uri" => uri, "version" => version}, "edits" => edits},
      {:ok, documents}
      when is_binary(uri) and is_list(edits) and (is_integer(version) or is_nil(version)) ->
        if Map.has_key?(documents, uri),
          do: {:halt, {:error, :lsp_duplicate_document}},
          else: {:cont, {:ok, Map.put(documents, uri, %{edits: edits, version: version})}}

      _operation, _acc ->
        {:halt, {:error, :lsp_resource_operation_not_granted}}
    end)
  end

  defp documents(%{} = edit) when map_size(edit) == 0, do: {:ok, %{}}
  defp documents(_edit), do: {:error, :invalid_workspace_edit}

  defp locate_edits(source, edits) do
    Enum.reduce_while(edits, {:ok, []}, fn
      %{"range" => %{"start" => start, "end" => ending}, "newText" => text}, {:ok, located}
      when is_binary(text) ->
        with true <- String.valid?(text) and not String.contains?(text, <<0>>),
             {:ok, start_byte} <- byte_offset(source, start),
             {:ok, end_byte} <- byte_offset(source, ending),
             true <- end_byte >= start_byte do
          {:cont, {:ok, [%{start: start_byte, end: end_byte, text: text} | located]}}
        else
          false -> {:halt, {:error, :invalid_lsp_edit}}
          {:error, _} = error -> {:halt, error}
        end

      _edit, _acc ->
        {:halt, {:error, :invalid_lsp_edit}}
    end)
  end

  defp byte_offset(source, %{"line" => line, "character" => character})
       when is_integer(line) and line >= 0 and is_integer(character) and character >= 0 do
    with {:ok, offset, text} <- line_at(source, line, 0),
         {:ok, column} <- utf16_column(text, character, 0) do
      {:ok, offset + column}
    end
  end

  defp byte_offset(_source, _position), do: {:error, :invalid_lsp_position}

  defp line_at(source, 0, offset) do
    line =
      case :binary.match(source, ["\r", "\n"]) do
        {index, 1} -> binary_part(source, 0, index)
        :nomatch -> source
      end

    {:ok, offset, line}
  end

  defp line_at(source, line, offset) do
    case :binary.match(source, ["\r", "\n"]) do
      {index, 1} ->
        consumed = index + newline_size(source, index)

        line_at(
          binary_part(source, consumed, byte_size(source) - consumed),
          line - 1,
          offset + consumed
        )

      :nomatch ->
        {:error, :lsp_position_out_of_bounds}
    end
  end

  defp newline_size(source, index) do
    if :binary.at(source, index) == 13 and index + 1 < byte_size(source) and
         :binary.at(source, index + 1) == 10, do: 2, else: 1
  end

  defp utf16_column(_text, 0, bytes), do: {:ok, bytes}

  defp utf16_column(<<codepoint::utf8, rest::binary>>, units, bytes) do
    width = if codepoint > 0xFFFF, do: 2, else: 1

    if width <= units,
      do: utf16_column(rest, units - width, bytes + byte_size(<<codepoint::utf8>>)),
      else: {:error, :lsp_surrogate_split}
  end

  defp utf16_column(_text, _units, _bytes), do: {:error, :lsp_position_out_of_bounds}

  defp versions_current(plans, document_versions) do
    case Enum.find(
           plans,
           &(not is_nil(&1.version) and Map.get(document_versions, &1.uri) != &1.version)
         ) do
      nil ->
        :ok

      plan ->
        {:error,
         %{
           reason: :lsp_document_version_stale,
           path: plan.path,
           version: plan.version,
           document_version: Map.get(document_versions, plan.uri)
         }}
    end
  end

  defp snapshots_present(plans) do
    if Enum.all?(plans, &is_binary(&1.expected_snapshot)),
      do: :ok,
      else: {:error, :lsp_snapshot_required}
  end

  defp snapshots_current(plans) do
    case Enum.find(plans, &(&1.snapshot != &1.expected_snapshot)) do
      nil -> :ok
      plan -> {:error, %{reason: :stale_snapshot, path: plan.path, snapshot: plan.snapshot}}
    end
  end
end
