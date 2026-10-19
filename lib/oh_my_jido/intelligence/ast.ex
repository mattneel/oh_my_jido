defmodule OhMyJido.Intelligence.AST do
  @moduledoc """
  Structural work over complete, bounded workspace snapshots.

  Elixir patterns use ExAST captures, not text matching. Only selected source
  ranges are patched; no whole-file formatting or ExAST filesystem writes occur.
  Publication always passes through `OhMyJido.Files.write/5` and its edit policy.

  Other languages use only the host's `:ast` binding. Its `:search` response must
  contain the request's `path`, `snapshot`, `matches` and `truncated` fields.
  Its `:plan_replace` response must contain the same identity and `replacements`
  containing `range` and replacement source. Adapters plan; they must not write.
  Ranges have one-based lines and grapheme columns with an exclusive end.
  Returned source fragments are extracted locally, never trusted from adapters.
  """

  alias ExAST.Rewriter.{Plan, Replacement}
  alias OhMyJido.{Context, Files, Host, Tool}

  @default_file_bytes 1_048_576
  @default_result_bytes 65_536
  @maximum_results 1000

  @spec execute(Context.t() | map(), map()) :: {:ok, map()} | {:error, term()}
  def execute(execution_context, params) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- request_required(params),
         {:ok, limits} <- limits(context, params),
         :ok <- Tool.authorize(context, :ast, %{operation: params.operation, path: params.path}),
         {:ok, file} <- Files.read_bytes(context, params.path, max_file_bytes: limits.file_bytes),
         :ok <- text_source(file),
         :ok <- snapshot_guard(file, Map.get(params, :snapshot)) do
      language = language(params, file.path)
      lines = source_lines(file.content)
      perform(context, params, file, lines, language, limits)
    end
    |> normalize()
  end

  defp request_required(%{operation: operation, path: path, pattern: pattern} = params)
       when operation in ["search", "replace"] and is_binary(path) and is_binary(pattern) do
    with :ok <- request_path(path),
         :ok <- request_pattern(pattern) do
      replacement_required(operation, params)
    end
  end

  defp request_required(_params), do: failure(:invalid_ast_request)

  defp request_path(path) do
    if path == "" or byte_size(path) > 4096, do: failure(:invalid_path), else: :ok
  end

  defp request_pattern(pattern) do
    if pattern == "" or byte_size(pattern) > 8192, do: failure(:ast_pattern_limit), else: :ok
  end

  defp replacement_required("search", _params), do: :ok

  defp replacement_required("replace", params) do
    with :ok <- snapshot_required(Map.get(params, :snapshot)),
         :ok <- count_required(Map.get(params, :expected_count)) do
      replacement_source(Map.get(params, :replacement))
    end
  end

  defp snapshot_required(snapshot) do
    if valid_snapshot?(snapshot), do: :ok, else: failure(:ast_snapshot_required)
  end

  defp count_required(count) when is_integer(count) and count in 0..@maximum_results, do: :ok
  defp count_required(_count), do: failure(:ast_expected_count_required)

  defp replacement_source(replacement) when is_binary(replacement) do
    if byte_size(replacement) > 16_384, do: failure(:ast_replacement_limit), else: :ok
  end

  defp replacement_source(_replacement), do: failure(:ast_replacement_required)

  defp limits(context, params) do
    file_bytes = Map.get(context.limits, :ast_file_bytes, @default_file_bytes)
    result_bytes = Map.get(context.limits, :ast_result_bytes, @default_result_bytes)
    max_results = Map.get(context.limits, :ast_max_results, @maximum_results)
    requested = Map.get(params, :max_results, 100)

    if Enum.all?([file_bytes, result_bytes, max_results, requested], &(is_integer(&1) and &1 > 0)) do
      {:ok,
       %{
         file_bytes: min(file_bytes, @default_file_bytes),
         result_bytes: result_bytes,
         max_results: min(min(max_results, requested), @maximum_results)
       }}
    else
      failure(:invalid_ast_limit)
    end
  end

  defp language(params, path) do
    Map.get(params, :language) ||
      case Path.extname(path) do
        extension when extension in [".ex", ".exs"] -> "elixir"
        ".erl" -> "erlang"
        ".js" -> "javascript"
        ".ts" -> "typescript"
        ".py" -> "python"
        extension -> String.trim_leading(extension, ".")
      end
  end

  defp text_source(%{binary: false}), do: :ok
  defp text_source(_file), do: failure(:binary_file)

  defp valid_snapshot?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_snapshot?(_value), do: false

  defp snapshot_guard(_file, nil), do: :ok
  defp snapshot_guard(%{snapshot: snapshot}, snapshot), do: :ok

  defp snapshot_guard(file, expected) do
    failure(:stale_snapshot, %{expected_snapshot: expected, actual_snapshot: file.snapshot})
  end

  defp perform(context, %{operation: "search"} = params, file, lines, language, limits) do
    with {:ok, matches, truncated} <- search(context, params, file, language, limits),
         {:ok, entries} <- normalize_entries(matches, file.content, lines, :search) do
      result = %{
        operation: :search,
        language: language,
        path: file.path,
        snapshot: file.snapshot,
        matches: Enum.map(entries, &Map.take(&1, [:range, :source, :captures])),
        count: length(entries),
        truncated: truncated
      }

      with :ok <- bounded(result, limits.result_bytes), do: {:ok, result}
    end
  end

  defp perform(context, %{operation: "replace"} = params, file, lines, language, limits) do
    with {:ok, replacements} <- plan(context, params, file, language, limits),
         {:ok, entries} <- normalize_entries(replacements, file.content, lines, :replace),
         {:ok, selected} <- select_ranges(entries, Map.get(params, :ranges), lines),
         :ok <- expected_count(selected, params.expected_count),
         :ok <- nonoverlapping(selected),
         {:ok, rendered} <- render_replacements(file.content, lines, selected),
         content = splice(file.content, rendered),
         :ok <- content_bound(content, limits.file_bytes),
         result = %{
           operation: :replace,
           language: language,
           path: file.path,
           previous_snapshot: file.snapshot,
           snapshot: Files.snapshot(content),
           count: length(rendered),
           changed: content != file.content,
           replacements: Enum.map(rendered, &Map.take(&1, [:range, :source, :replacement]))
         },
         :ok <- bounded(result, limits.result_bytes),
         {:ok, _published} <-
           Files.write(context, params.path, content, file.snapshot,
             max_file_bytes: limits.file_bytes
           ) do
      {:ok, result}
    end
  end

  defp search(_context, params, file, "elixir", limits) do
    parser(fn ->
      matches =
        ExAST.Patcher.find_all(file.content, params.pattern, limit: limits.max_results + 1)

      {:ok, Enum.take(matches, limits.max_results), length(matches) > limits.max_results}
    end)
  end

  defp search(context, params, file, language, limits) do
    with {:ok, response} <- adapter(context, params, file, language, limits, :search),
         matches when is_list(matches) <- field(response, :matches),
         truncated when is_boolean(truncated) <- field(response, :truncated) do
      {:ok, Enum.take(matches, limits.max_results),
       truncated or length(matches) > limits.max_results}
    else
      {:error, _reason} = error -> error
      _ -> failure(:invalid_ast_adapter_result)
    end
  end

  defp plan(_context, params, file, "elixir", limits) do
    parser(fn ->
      plan =
        ExAST.rewrite_plan(file.content, params.pattern, params.replacement,
          limit: limits.max_results + 1
        )

      plan_bound(plan.replacements, limits.max_results)
    end)
  end

  defp plan(context, params, file, language, limits) do
    with {:ok, response} <- adapter(context, params, file, language, limits, :plan_replace),
         replacements when is_list(replacements) <- field(response, :replacements),
         false <- field(response, :truncated) == true do
      plan_bound(replacements, limits.max_results)
    else
      true -> failure(:ast_match_limit)
      {:error, _reason} = error -> error
      _ -> failure(:invalid_ast_adapter_result)
    end
  end

  defp plan_bound(replacements, maximum) do
    if length(replacements) <= maximum, do: {:ok, replacements}, else: failure(:ast_match_limit)
  end

  defp adapter(context, params, file, language, limits, operation) do
    request = %{
      operation: operation,
      language: language,
      path: file.path,
      source: file.content,
      snapshot: file.snapshot,
      pattern: params.pattern,
      max_results: limits.max_results + 1,
      result_max_bytes: limits.result_bytes,
      range_convention: :one_based_grapheme_exclusive
    }

    request =
      if operation == :plan_replace,
        do: Map.put(request, :replacement, params.replacement),
        else: request

    case Host.call(context, :invoke, [:ast, request]) do
      {:ok, response} when is_map(response) ->
        with :ok <- bounded(response, limits.result_bytes),
             true <-
               field(response, :path) == file.path and field(response, :snapshot) == file.snapshot do
          {:ok, response}
        else
          false -> failure(:ast_adapter_snapshot_mismatch)
          {:error, _reason} = error -> error
        end

      {:error, {:capability_unavailable, :ast}} ->
        failure({:capability_unavailable, :ast, language})

      {:error, _reason} = error ->
        error

      _ ->
        failure(:invalid_ast_adapter_result)
    end
  end

  defp parser(fun) do
    fun.()
  rescue
    error in [SyntaxError, TokenMissingError, ArgumentError] ->
      failure(:ast_parse_error, %{
        description: Exception.message(error) |> Files.truncate_utf8(1024)
      })
  end

  defp normalize_entries(entries, source, lines, kind) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, range} <- range(field(entry, :range), lines),
           {:ok, start_byte} <- coordinate(range.start, lines),
           {:ok, end_byte} <- coordinate(range.end, lines),
           true <- end_byte > start_byte,
           {:ok, extra} <- entry_fields(entry, kind) do
        normalized =
          Map.merge(extra, %{
            range: range,
            start_byte: start_byte,
            end_byte: end_byte,
            source: binary_part(source, start_byte, end_byte - start_byte)
          })

        {:cont, {:ok, [normalized | acc]}}
      else
        false -> {:halt, failure(:ast_invalid_range)}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, &{&1.start_byte, &1.end_byte})}
      {:error, _reason} = error -> error
    end
  end

  defp entry_fields(entry, :replace) do
    case field(entry, :replacement) do
      replacement when is_binary(replacement) ->
        if String.valid?(replacement) and not String.contains?(replacement, <<0>>) do
          {:ok, %{replacement: replacement}}
        else
          failure(:invalid_ast_adapter_result)
        end

      _ ->
        failure(:invalid_ast_adapter_result)
    end
  end

  defp entry_fields(%{node: _node, captures: captures}, :search) do
    strings =
      captures
      |> ExAST.AST.strip_sourceror_meta()
      |> Map.new(fn {name, value} -> {Atom.to_string(name), ExAST.AST.to_string(value)} end)

    {:ok, %{captures: strings}}
  end

  defp entry_fields(entry, :search) do
    captures = field(entry, :captures) || %{}

    if is_map(captures) and
         Enum.all?(captures, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, %{captures: captures}}
    else
      failure(:invalid_ast_adapter_result)
    end
  end

  defp select_ranges(entries, nil, _lines), do: {:ok, entries}

  defp select_ranges(entries, requested, lines) when is_list(requested) do
    with {:ok, normalized} <- normalize_ranges(requested, lines),
         selected = Enum.filter(entries, &(&1.range in normalized)),
         true <- length(selected) == length(normalized) do
      {:ok, selected}
    else
      false -> failure(:ast_range_not_matched)
      {:error, _reason} = error -> error
    end
  end

  defp select_ranges(_entries, _requested, _lines), do: failure(:ast_invalid_range)

  defp normalize_ranges(requested, lines) do
    Enum.reduce_while(requested, {:ok, []}, fn requested_range, {:ok, acc} ->
      with {:ok, normalized} <- range(requested_range, lines),
           :ok <- unique_range(normalized, acc) do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp unique_range(range, ranges) do
    if range in ranges, do: failure(:ast_duplicate_ranges), else: :ok
  end

  defp expected_count(entries, expected) do
    actual = length(entries)

    if actual == expected,
      do: :ok,
      else: failure(:ast_match_count_mismatch, %{expected: expected, actual: actual})
  end

  defp nonoverlapping(entries) do
    if entries
       |> Enum.chunk_every(2, 1, :discard)
       |> Enum.any?(fn [left, right] -> left.end_byte > right.start_byte end) do
      failure(:ast_overlapping_replacements)
    else
      :ok
    end
  end

  # Sourceror 1.12's newline splitter treats CR and LF separately. Render each
  # selected range on LF text, then splice only that range into the original
  # bytes. This preserves every surrounding comment and mixed newline byte.
  defp render_replacements(source, lines, entries) do
    newline = newline(source)

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      {line_offset, _line} = elem(lines, entry.range.start.line - 1)
      prefix_size = entry.start_byte - line_offset
      segment = binary_part(source, line_offset, entry.end_byte - line_offset)

      local_range = %Sourceror.Range{
        start: [line: 1, column: entry.range.start.column],
        end: [
          line: entry.range.end.line - entry.range.start.line + 1,
          column: entry.range.end.column
        ]
      }

      replacement = %Replacement{
        range: local_range,
        replacement: lf(entry.replacement),
        captures: %{}
      }

      plan = %Plan{replacements: [replacement], conflicts: []}
      rendered = ExAST.Rewriter.apply(lf(segment), plan, on_conflict: :raise)
      prefix = binary_part(segment, 0, prefix_size)

      if String.starts_with?(rendered, prefix) do
        replacement = binary_part(rendered, prefix_size, byte_size(rendered) - prefix_size)

        replacement = restore_newline(replacement, newline)

        {:cont, {:ok, [Map.put(entry, :replacement, replacement) | acc]}}
      else
        {:halt, failure(:ast_preservation_error)}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      {:error, _reason} = error -> error
    end
  end

  defp splice(source, entries) do
    {pieces, cursor} =
      Enum.reduce(entries, {[], 0}, fn entry, {pieces, cursor} ->
        untouched = binary_part(source, cursor, entry.start_byte - cursor)
        {[entry.replacement, untouched | pieces], entry.end_byte}
      end)

    suffix = binary_part(source, cursor, byte_size(source) - cursor)
    IO.iodata_to_binary(Enum.reverse([suffix | pieces]))
  end

  defp lf(source), do: String.replace(source, ~r/\r\n?/, "\n")
  defp restore_newline(source, "\n"), do: source
  defp restore_newline(source, newline), do: String.replace(source, "\n", newline)

  defp newline(source) do
    case :binary.match(source, "\n") do
      {index, 1} when index > 0 -> if :binary.at(source, index - 1) == 13, do: "\r\n", else: "\n"
      {0, 1} -> "\n"
      :nomatch -> if String.contains?(source, "\r"), do: "\r", else: "\n"
    end
  end

  defp source_lines(source) do
    {lines, _offset} =
      source
      |> String.split(~r/\r\n|\r|\n/, include_captures: true)
      |> Enum.chunk_every(2)
      |> Enum.reduce({[], 0}, fn [line | newline], {acc, offset} ->
        size = byte_size(line) + IO.iodata_length(newline)
        {[{offset, line} | acc], offset + size}
      end)

    lines |> Enum.reverse() |> List.to_tuple()
  end

  defp range(value, lines) do
    with {:ok, start} <- position(field(value, :start)),
         {:ok, finish} <- position(field(value, :end)),
         {:ok, first} <- coordinate(start, lines),
         {:ok, last} <- coordinate(finish, lines),
         true <- last > first do
      {:ok, %{start: start, end: finish}}
    else
      false -> failure(:ast_invalid_range)
      {:error, _reason} = error -> error
    end
  end

  defp position(value) do
    line = field(value, :line)
    column = field(value, :column)

    if is_integer(line) and line > 0 and is_integer(column) and column > 0 do
      {:ok, %{line: line, column: column}}
    else
      failure(:ast_invalid_range)
    end
  end

  defp coordinate(%{line: line, column: column}, lines) when line <= tuple_size(lines) do
    {offset, text} = elem(lines, line - 1)

    if column <= String.length(text) + 1 do
      {prefix, _suffix} = String.split_at(text, column - 1)
      {:ok, offset + byte_size(prefix)}
    else
      failure(:ast_invalid_range)
    end
  end

  defp coordinate(_position, _lines), do: failure(:ast_invalid_range)

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp field(value, key) when is_list(value) do
    if Keyword.keyword?(value), do: Keyword.get(value, key), else: nil
  end

  defp field(_value, _key), do: nil

  defp content_bound(content, maximum) do
    if byte_size(content) <= maximum,
      do: :ok,
      else: failure(:file_too_large, %{max_bytes: maximum})
  end

  defp bounded(value, maximum) do
    case Jason.encode_to_iodata(value) do
      {:ok, encoded} ->
        if IO.iodata_length(encoded) <= maximum,
          do: :ok,
          else: failure(:ast_result_limit, %{max_bytes: maximum})

      {:error, _reason} ->
        failure(:invalid_ast_adapter_result)
    end
  end

  defp failure(reason, details \\ %{}) do
    {:error,
     Map.merge(
       %{message: "Structural AST operation rejected: #{inspect(reason)}", reason: reason},
       details
     )}
  end

  defp normalize({:error, %{message: _message}} = error), do: error
  defp normalize({:error, reason}), do: failure(reason)
  defp normalize(result), do: result
end
