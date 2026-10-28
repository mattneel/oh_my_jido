defmodule OhMyJido.Files do
  @moduledoc """
  Bounded file reads and snapshot-guarded atomic file effects.

  Snapshots are lowercase SHA256 digests of the complete original bytes, including
  newline sequences. A write must supply that digest or `"missing"` for creation.
  In-process writers serialize by canonical path; content and confinement are
  checked again immediately before publication. External writers are checked but
  are not locked by this adapter. Strong adversarial OS isolation is host-owned.
  """

  import Bitwise, only: [band: 2]

  alias OhMyJido.{Context, Tool, Workspace}

  @default_file_bytes 8 * 1024 * 1024
  @default_read_bytes 256 * 1024
  @chunk_bytes 64 * 1024
  @identity_fields [:type, :inode, :major_device, :minor_device, :size, :mtime, :ctime, :mode]

  @doc "Reads exact bytes, detects binary data and optionally selects inclusive UTF-8 lines."
  @spec read(Context.t() | map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def read(execution_context, path, opts \\ []) do
    result =
      with {:ok, context} <- Context.fetch(execution_context),
           :ok <- Tool.authorize(context, :read, %{operation: :read, path: path}),
           {:ok, max_file_bytes} <- limit(context, :max_file_bytes, opts, @default_file_bytes),
           {:ok, max_bytes} <-
             limit(context, :max_read_bytes, opts, @default_read_bytes, :max_bytes),
           {:ok, file} <- load(context, path, max_file_bytes) do
        render(file, opts, max_bytes)
      end

    normalize(result)
  end

  @doc false
  @spec read_bytes(Context.t() | map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def read_bytes(execution_context, path, opts \\ []) do
    authorized_bytes(execution_context, path, opts, :read)
  end

  @doc false
  @spec read_artifact_bytes(Context.t() | map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def read_artifact_bytes(execution_context, path, opts \\ []) do
    authorized_bytes(execution_context, path, opts, :artifact)
  end

  defp authorized_bytes(execution_context, path, opts, capability) do
    result =
      with {:ok, context} <- Context.fetch(execution_context),
           :ok <- Tool.authorize(context, capability, %{operation: :read, path: path}),
           {:ok, max_bytes} <- limit(context, :max_file_bytes, opts, @default_file_bytes) do
        load(context, path, max_bytes)
      end

    normalize(result)
  end

  @doc "Atomically creates or replaces one file after checking its complete snapshot."
  @spec write(Context.t() | map(), String.t(), binary(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def write(execution_context, path, content, expected_snapshot, opts \\ []) do
    mutate(execution_context, path, expected_snapshot, opts, :write, fn _current ->
      with :ok <- text_content(content) do
        {:ok, content, %{}}
      end
    end)
  end

  @doc "Applies nonoverlapping exact replacements against one original file snapshot."
  @spec edit(Context.t() | map(), String.t(), String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, map()}
  def edit(execution_context, path, expected_snapshot, edits, opts \\ []) do
    mutate(execution_context, path, expected_snapshot, opts, :edit, fn current ->
      with false <- current == :missing,
           :ok <- editable(current.binary),
           {:ok, content} <- apply_edits(current.content, edits) do
        {:ok, content, %{replacements: length(edits)}}
      else
        true -> {:error, :target_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc "Returns the SHA256 snapshot of exact bytes."
  @spec snapshot(binary()) :: String.t()
  def snapshot(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  @doc false
  @spec failure(term(), map()) :: {:error, map()}
  def failure(reason, details \\ %{}) do
    {:error,
     Map.merge(
       %{message: "Filesystem operation rejected: #{inspect(reason)}", reason: reason},
       details
     )}
  end

  @doc false
  def normalize({:error, %{message: _message} = reason}), do: {:error, reason}
  def normalize({:error, reason}), do: failure(reason)
  def normalize(result), do: result

  @doc false
  def truncate_utf8(content, max_bytes) do
    retained =
      if byte_size(content) <= max_bytes do
        content
      else
        binary_part(content, 0, utf8_boundary(content, max_bytes))
      end

    # Display slices must not keep an otherwise discarded large file alive.
    if :binary.referenced_byte_size(retained) > byte_size(retained),
      do: :binary.copy(retained),
      else: retained
  end

  defp utf8_boundary(_content, 0), do: 0

  defp utf8_boundary(content, offset) do
    if band(:binary.at(content, offset), 0xC0) == 0x80 do
      utf8_boundary(content, offset - 1)
    else
      offset
    end
  end

  defp mutate(execution_context, path, expected_snapshot, opts, operation, transform) do
    result =
      with {:ok, context} <- Context.fetch(execution_context),
           :ok <- Tool.authorize(context, :edit, %{operation: operation, path: path}),
           :ok <- valid_snapshot(expected_snapshot),
           {:ok, max_bytes} <- limit(context, :max_file_bytes, opts, @default_file_bytes),
           {:ok, resolved} <- Workspace.resolve(context, path, allow_missing: true) do
        :global.trans(
          {{__MODULE__, resolved}, self()},
          fn ->
            mutate_locked(context, path, resolved, expected_snapshot, max_bytes, transform)
          end,
          [node()]
        )
      end

    normalize(result)
  end

  defp mutate_locked(context, path, resolved, expected_snapshot, max_bytes, transform) do
    with {:ok, boundary} <- Workspace.resolve(context, path, allow_missing: true),
         :ok <- same_path(resolved, boundary),
         {:ok, current} <- current(context, resolved, max_bytes),
         :ok <- guard_snapshot(current, expected_snapshot),
         :ok <- writable(current),
         {:ok, content, extra} <- transform.(current),
         :ok <- within_bytes(byte_size(content), max_bytes),
         {:ok, result} <- publish(context, path, resolved, current, content, max_bytes) do
      {:ok, Map.merge(result, extra)}
    end
  end

  defp valid_snapshot("missing"), do: :ok

  defp valid_snapshot(snapshot) when is_binary(snapshot) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, snapshot), do: :ok, else: {:error, :invalid_snapshot}
  end

  defp valid_snapshot(_snapshot), do: {:error, :invalid_snapshot}

  defp limit(context, key, opts, default, option_key \\ nil) do
    maximum = Map.get(context.limits, key, default)
    requested = Keyword.get(opts, option_key || key, maximum)

    if is_integer(maximum) and maximum > 0 and is_integer(requested) and requested > 0 do
      {:ok, min(maximum, requested)}
    else
      {:error, :invalid_limit}
    end
  end

  defp load(context, path, max_bytes) do
    with {:ok, resolved} <- Workspace.resolve(context, path),
         {:ok, stat} <- File.stat(resolved, time: :posix),
         :ok <- regular(stat),
         :ok <- readable(stat),
         :ok <- within_bytes(stat.size, max_bytes),
         {:ok, descriptor} <- File.open(resolved, [:read, :binary, :raw]) do
      try do
        with {:ok, opened} <- descriptor_stat(descriptor),
             :ok <- same_identity(stat, opened),
             {:ok, boundary} <- Workspace.resolve(context, path),
             :ok <- same_path(resolved, boundary),
             {:ok, content} <- read_chunks(descriptor, max_bytes, []),
             {:ok, after_read} <- descriptor_stat(descriptor),
             :ok <- same_identity(opened, after_read),
             {:ok, boundary} <- Workspace.resolve(context, path),
             :ok <- same_path(resolved, boundary),
             {:ok, published} <- File.stat(resolved, time: :posix),
             :ok <- same_identity(opened, published) do
          {:ok,
           %{
             path: Workspace.relative(context, resolved),
             absolute: resolved,
             content: content,
             binary: binary?(content),
             stat: stat,
             snapshot: snapshot(content)
           }}
        end
      after
        File.close(descriptor)
      end
    end
  end

  defp descriptor_stat(descriptor) do
    case :file.read_file_info(descriptor, time: :posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_chunks(descriptor, remaining, acc) do
    case :file.read(descriptor, min(@chunk_bytes, remaining + 1)) do
      :eof ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

      {:ok, bytes} when byte_size(bytes) <= remaining ->
        read_chunks(descriptor, remaining - byte_size(bytes), [bytes | acc])

      {:ok, _bytes} ->
        {:error, :file_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp regular(%File.Stat{type: :regular}), do: :ok
  defp regular(_stat), do: {:error, :not_regular_file}

  defp readable(%File.Stat{mode: mode, access: access}) do
    if band(mode, 0o444) != 0 and access in [:read, :read_write], do: :ok, else: {:error, :eacces}
  end

  defp writable(:missing), do: :ok

  defp writable(%{stat: %File.Stat{mode: mode, access: access}}) do
    if band(mode, 0o222) != 0 and access in [:write, :read_write],
      do: :ok,
      else: {:error, :eacces}
  end

  defp within_bytes(size, maximum) when size <= maximum, do: :ok

  defp within_bytes(size, maximum),
    do: failure(:file_too_large, %{bytes: size, max_bytes: maximum})

  defp same_identity(first, second) do
    if Enum.all?(@identity_fields, &(Map.fetch!(first, &1) == Map.fetch!(second, &1))) do
      :ok
    else
      {:error, :concurrent_change}
    end
  end

  defp same_path(path, path), do: :ok
  defp same_path(_first, _second), do: {:error, :concurrent_change}

  defp binary?(content),
    do: not String.valid?(content) or :binary.match(content, <<0>>) != :nomatch

  defp render(file, opts, max_bytes) do
    if file.binary,
      do: render_binary(file, opts, max_bytes),
      else: render_text(file, opts, max_bytes)
  end

  defp render_binary(file, opts, max_bytes) do
    if Keyword.has_key?(opts, :start_line) or Keyword.has_key?(opts, :end_line) do
      {:error, :binary_range}
    else
      retained = min(byte_size(file.content), div(max_bytes, 4) * 3)
      base64 = file.content |> binary_part(0, retained) |> Base.encode64()
      truncated = retained < byte_size(file.content)

      {:ok,
       %{
         path: file.path,
         content: nil,
         base64: base64,
         encoding: "binary",
         binary: true,
         bytes: byte_size(file.content),
         bytes_returned: retained,
         snapshot: file.snapshot,
         line_count: nil,
         newline: nil,
         truncated: truncated,
         truncation: %{output: truncated}
       }}
    end
  end

  defp render_text(file, opts, max_bytes) do
    start_line = Keyword.get(opts, :start_line, 1)
    end_line = Keyword.get(opts, :end_line)

    with :ok <- valid_range(start_line, end_line) do
      {line_count, crlf, start_byte, end_byte} = line_bounds(file.content, start_line, end_line)

      if start_byte == nil and (byte_size(file.content) != 0 or start_line != 1) do
        {:error, :range_out_of_bounds}
      else
        start_byte = start_byte || 0
        end_byte = end_byte || byte_size(file.content)
        selected = binary_part(file.content, start_byte, end_byte - start_byte)
        content = truncate_utf8(selected, max_bytes)
        truncated = byte_size(content) < byte_size(selected)

        {:ok,
         %{
           path: file.path,
           content: content,
           encoding: "utf8",
           binary: false,
           bytes: byte_size(file.content),
           bytes_returned: byte_size(content),
           snapshot: file.snapshot,
           line_count: line_count,
           start_line: start_line,
           end_line: min(end_line || line_count, line_count),
           newline: newline(file.content, line_count, crlf),
           truncated: truncated,
           truncation: %{output: truncated}
         }}
      end
    end
  end

  defp valid_range(start_line, end_line) do
    if is_integer(start_line) and start_line > 0 and
         (end_line == nil or (is_integer(end_line) and end_line >= start_line)) do
      :ok
    else
      {:error, :invalid_range}
    end
  end

  defp line_bounds(content, start_line, end_line) do
    scan_lines(content, 0, 1, start_line, end_line, nil, nil, 0)
  end

  defp scan_lines(content, offset, line, _start_line, _end_line, start_byte, end_byte, crlf)
       when offset == byte_size(content) do
    {line - 1, crlf, start_byte, end_byte}
  end

  defp scan_lines(content, offset, line, start_line, end_line, start_byte, end_byte, crlf) do
    start_byte = if line == start_line, do: offset, else: start_byte

    case :binary.match(content, "\n", scope: {offset, byte_size(content) - offset}) do
      {index, 1} ->
        next = index + 1
        end_byte = if line == end_line, do: next, else: end_byte
        crlf = if index > 0 and :binary.at(content, index - 1) == 13, do: crlf + 1, else: crlf
        scan_lines(content, next, line + 1, start_line, end_line, start_byte, end_byte, crlf)

      :nomatch ->
        {line, crlf, start_byte, if(line == end_line, do: byte_size(content), else: end_byte)}
    end
  end

  defp newline("", _count, _crlf), do: "none"

  defp newline(content, _count, 0),
    do: if(:binary.match(content, "\n") == :nomatch, do: "none", else: "lf")

  defp newline(content, count, crlf) do
    terminators = if :binary.last(content) == 10, do: count, else: count - 1
    if crlf == terminators, do: "crlf", else: "mixed"
  end

  defp current(context, path, max_bytes) do
    case Workspace.resolve(context, path, allow_missing: true) do
      {:ok, resolved} ->
        case File.lstat(resolved) do
          {:error, :enoent} -> {:ok, :missing}
          {:error, reason} -> {:error, reason}
          {:ok, _stat} -> load(context, resolved, max_bytes)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp guard_snapshot(current, expected) do
    actual = current_snapshot(current)

    if actual == expected,
      do: :ok,
      else: failure(:stale_snapshot, %{expected_snapshot: expected, actual_snapshot: actual})
  end

  defp current_snapshot(:missing), do: "missing"
  defp current_snapshot(current), do: current.snapshot

  defp text_content(content) when is_binary(content) do
    if String.valid?(content), do: :ok, else: {:error, :invalid_encoding}
  end

  defp text_content(_content), do: {:error, :invalid_content}
  defp editable(true), do: {:error, :binary_file}
  defp editable(false), do: :ok

  defp publish(context, original_path, path, current, content, max_bytes) do
    if current != :missing and current.content == content do
      {:ok, mutation_result(context, path, current, content, false)}
    else
      temp =
        Path.join(
          Path.dirname(path),
          ".oh-my-jido-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        )

      try do
        with :ok <- writable_parent(context, path),
             {:ok, resolved_temp} <- Workspace.resolve(context, temp, allow_missing: true),
             :ok <- same_path(temp, resolved_temp),
             :ok <- stage(context, temp, content, current),
             {:ok, boundary} <- Workspace.resolve(context, original_path, allow_missing: true),
             :ok <- same_path(path, boundary),
             {:ok, latest} <- current(context, path, max_bytes),
             :ok <- guard_snapshot(latest, current_snapshot(current)),
             :ok <- unchanged_identity(current, latest),
             :ok <- writable(latest),
             :ok <- writable_parent(context, path),
             {:ok, resolved_temp} <- Workspace.resolve(context, temp),
             :ok <- same_path(temp, resolved_temp),
             :ok <- commit(temp, path, current) do
          {:ok, mutation_result(context, path, current, content, true)}
        end
      after
        cleanup(context, temp)
      end
    end
  end

  defp unchanged_identity(:missing, :missing), do: :ok
  defp unchanged_identity(%{stat: first}, %{stat: second}), do: same_identity(first, second)
  defp unchanged_identity(_first, _second), do: {:error, :concurrent_change}

  defp writable_parent(context, path) do
    with {:ok, parent} <- Workspace.resolve(context, Path.dirname(path)),
         {:ok, %File.Stat{type: :directory, mode: mode, access: access}} <- File.stat(parent),
         true <-
           band(mode, 0o222) != 0 and band(mode, 0o111) != 0 and access in [:write, :read_write] do
      :ok
    else
      false -> {:error, :eacces}
      {:ok, _stat} -> {:error, :enotdir}
      {:error, _reason} = error -> error
    end
  end

  defp stage(context, temp, content, current) do
    with {:ok, descriptor} <- File.open(temp, [:write, :binary, :raw, :exclusive]) do
      try do
        with {:ok, boundary} <- Workspace.resolve(context, temp),
             :ok <- same_path(temp, boundary),
             {:ok, opened} <- descriptor_stat(descriptor),
             {:ok, stat} <- File.stat(temp, time: :posix),
             :ok <- same_identity(opened, stat),
             :ok <- :file.write(descriptor, content),
             :ok <- :file.sync(descriptor) do
          preserve_mode(context, temp, current)
        end
      after
        File.close(descriptor)
      end
    end
  end

  defp preserve_mode(_context, _temp, :missing), do: :ok

  defp preserve_mode(context, temp, current) do
    with {:ok, boundary} <- Workspace.resolve(context, temp),
         :ok <- same_path(temp, boundary) do
      File.chmod(temp, band(current.stat.mode, 0o7777))
    end
  end

  defp commit(temp, path, :missing) do
    case File.ln(temp, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        stale_missing()

      {:error, reason} when reason in [:emlink, :enotsup, :eperm] ->
        reserve_and_replace(temp, path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit(temp, path, _current), do: File.rename(temp, path)

  # Filesystems without hard links, such as the browser VM's in-memory one,
  # still never overwrite: reserve the name exclusively, then atomically
  # replace that empty reservation with the staged content.
  defp reserve_and_replace(temp, path) do
    case File.open(path, [:write, :exclusive, :raw]) do
      {:ok, descriptor} ->
        :ok = File.close(descriptor)
        replace_reservation(temp, path)

      {:error, :eexist} ->
        stale_missing()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_reservation(temp, path) do
    case File.rename(temp, path) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        _ = File.rm(path)
        error
    end
  end

  defp stale_missing,
    do: failure(:stale_snapshot, %{expected_snapshot: "missing", actual_snapshot: "exists"})

  defp cleanup(context, temp) do
    case Workspace.resolve(context, temp) do
      {:ok, ^temp} -> File.rm(temp)
      _result -> :ok
    end
  end

  defp mutation_result(context, path, current, content, changed) do
    %{
      path: Workspace.relative(context, path),
      snapshot: if(changed, do: snapshot(content), else: current_snapshot(current)),
      previous_snapshot: current_snapshot(current),
      bytes_written: if(changed, do: byte_size(content), else: 0),
      created: current == :missing,
      changed: changed
    }
  end

  defp apply_edits(content, [_edit | _rest] = edits) when is_list(edits) do
    with true <- Enum.count_until(edits, 101) <= 100,
         {:ok, targets} <- edit_targets(content, edits),
         targets = Enum.sort_by(targets, & &1.offset),
         :ok <- nonoverlapping(targets, 0) do
      {pieces, offset} =
        Enum.reduce(targets, {[], 0}, fn target, {pieces, offset} ->
          prefix = binary_part(content, offset, target.offset - offset)
          {[target.new, prefix | pieces], target.offset + target.length}
        end)

      suffix = binary_part(content, offset, byte_size(content) - offset)
      {:ok, IO.iodata_to_binary(Enum.reverse([suffix | pieces]))}
    else
      false -> {:error, :invalid_edits}
      {:error, _reason} = error -> error
    end
  end

  defp apply_edits(_content, _edits), do: {:error, :invalid_edits}

  defp edit_targets(content, edits) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, targets} ->
      with %{old: old, new: new} when is_binary(old) and old != "" <- edit,
           :ok <- text_content(old),
           :ok <- text_content(new),
           {:ok, offset} <- locate(content, old, Map.get(edit, :occurrence)) do
        {:cont, {:ok, [%{offset: offset, length: byte_size(old), new: new} | targets]}}
      else
        {:error, _reason} = error -> {:halt, error}
        _invalid -> {:halt, {:error, :invalid_edit}}
      end
    end)
  end

  defp locate(content, target, nil) do
    case :binary.match(content, target) do
      :nomatch ->
        {:error, :target_not_found}

      {offset, _length} ->
        case find_match(content, target, offset + 1) do
          :nomatch -> {:ok, offset}
          _match -> {:error, :ambiguous_match}
        end
    end
  end

  defp locate(content, target, occurrence)
       when is_integer(occurrence) and occurrence > 0 and occurrence <= 10_000 do
    locate_occurrence(content, target, occurrence, 0)
  end

  defp locate(_content, _target, _occurrence), do: {:error, :invalid_occurrence}

  defp locate_occurrence(content, target, occurrence, from) do
    case find_match(content, target, from) do
      :nomatch -> {:error, :target_not_found}
      {offset, _length} when occurrence == 1 -> {:ok, offset}
      {offset, _length} -> locate_occurrence(content, target, occurrence - 1, offset + 1)
    end
  end

  defp find_match(content, _target, from) when from >= byte_size(content), do: :nomatch

  defp find_match(content, target, from),
    do: :binary.match(content, target, scope: {from, byte_size(content) - from})

  defp nonoverlapping([], _end_byte), do: :ok

  defp nonoverlapping([%{offset: offset} | _rest], end_byte) when offset < end_byte,
    do: {:error, :overlapping_edits}

  defp nonoverlapping([target | rest], _end_byte),
    do: nonoverlapping(rest, target.offset + target.length)
end
