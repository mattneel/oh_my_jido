defmodule OhMyJido.Search do
  @moduledoc """
  Stable, bounded workspace glob discovery and line-oriented text search.

  Ripgrep supplies glob and ignore semantics; it receives only fixed discovery
  arguments, never a shell command or text pattern. Global/parent ignore files,
  configuration and symlink following are disabled. Ignore-file indirections are
  checked within the grant before discovery. Text is read through the same
  descriptor-checked file boundary as the read Action.

  Returned columns are one-based byte columns. Lines omit only their LF/CRLF
  terminator. Output limits count the JSON bytes of retained entries; metadata is
  fixed-size apart from the already bounded workspace path.
  """

  import Bitwise, only: [band: 2]

  alias OhMyJido.{Context, Files, Tool, Workspace}
  alias OhMyJido.Process, as: Command

  @defaults %{
    results: 200,
    output_bytes: 128 * 1024,
    discovery_bytes: 1024 * 1024,
    files: 10_000,
    scan_bytes: 32 * 1024 * 1024,
    line_bytes: 2048,
    timeout_ms: 10_000,
    pattern_bytes: 4096,
    walk_entries: 100_000,
    depth: 64
  }
  @rule_files [".gitignore", ".ignore", ".rgignore"]
  @flags %{
    results: false,
    output: false,
    enumeration: false,
    files: false,
    lines: false,
    deadline: false
  }
  @skipped %{binary: 0, large: 0, denied: 0, changed: 0, unsafe: 0}

  @doc "Lists confined files with ripgrep glob and ignore semantics."
  @spec files(Context.t() | map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def files(execution_context, path \\ ".", opts \\ []) do
    result =
      with {:ok, context} <- Context.fetch(execution_context),
           :ok <- Tool.authorize(context, :read, %{operation: :list, path: path}),
           {:ok, limits} <- limits(context, opts),
           {:ok, discovery} <- discover(context, path, opts, limits) do
        {paths, _bytes, flags} = retain_paths(discovery.paths, limits, [], 0, 0, discovery.flags)
        paths = Enum.reverse(paths)

        {:ok,
         %{
           path: discovery.path,
           paths: paths,
           count: length(paths),
           skipped: discovery.skipped,
           truncated: truncated?(flags),
           truncation: flags
         }}
      end

    Files.normalize(result)
  end

  @doc "Searches bounded UTF-8 files, returning stable paths and precise line locations."
  @spec text(Context.t() | map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def text(execution_context, pattern, opts \\ []) do
    path = Keyword.get(opts, :path, ".")

    result =
      with {:ok, context} <- Context.fetch(execution_context),
           :ok <- Tool.authorize(context, :read, %{operation: :search, path: path}),
           {:ok, limits} <- limits(context, opts),
           {:ok, matcher} <- matcher(pattern, opts, limits),
           {:ok, discovery} <- discover(context, path, opts, limits),
           {:ok, state} <- scan(context, discovery, matcher, limits) do
        {:ok,
         %{
           path: discovery.path,
           matches: Enum.reverse(state.matches),
           count: state.count,
           scanned_files: state.scanned_files,
           scanned_bytes: state.scanned_bytes,
           skipped: state.skipped,
           truncated: truncated?(state.flags),
           truncation: state.flags
         }}
      end

    Files.normalize(result)
  end

  defp limits(context, opts) do
    fields = [
      {:results, :search_max_results, :max_results},
      {:output_bytes, :search_max_output_bytes, :max_bytes},
      {:line_bytes, :search_max_line_bytes, :max_line_bytes},
      {:discovery_bytes, :search_max_discovery_bytes, :max_discovery_bytes},
      {:files, :search_max_files, :max_files},
      {:scan_bytes, :search_max_scan_bytes, :max_scan_bytes},
      {:timeout_ms, :search_timeout_ms, :timeout},
      {:pattern_bytes, :search_max_pattern_bytes, :max_pattern_bytes},
      {:walk_entries, :search_max_walk_entries, :max_walk_entries},
      {:depth, :search_max_depth, :max_depth}
    ]

    result =
      Enum.reduce_while(fields, {:ok, %{}}, fn {field, key, option}, {:ok, acc} ->
        ceiling = Map.get(context.limits, key, @defaults[field])
        requested = Keyword.get(opts, option, ceiling)

        if is_integer(ceiling) and ceiling > 0 and is_integer(requested) and requested > 0 do
          {:cont, {:ok, Map.put(acc, field, min(ceiling, requested))}}
        else
          {:halt, {:error, :invalid_limit}}
        end
      end)

    with {:ok, limits} <- result do
      {:ok, Map.put(limits, :deadline, System.monotonic_time(:millisecond) + limits.timeout_ms)}
    end
  end

  defp discover(context, path, opts, limits) do
    glob = Keyword.get(opts, :glob, "**/*")
    ignore = Keyword.get(opts, :ignore, true)
    hidden = Keyword.get(opts, :hidden, false)

    with {:ok, root} <- Workspace.resolve(context, "."),
         {:ok, resolved} <- Workspace.resolve(context, path),
         :ok <- directory_or_file(resolved),
         :ok <- safe_glob(glob),
         true <- is_boolean(ignore) and is_boolean(hidden),
         {:ok, compiled_glob} <- compile_glob(glob, hidden),
         :ok <- deadline(limits),
         args = discovery_args(Workspace.relative(context, resolved), ignore, hidden),
         {:ok, captured} <-
           Command.run(context, "rg", args,
             capability: :read,
             cwd: ".",
             timeout: max(1, limits.deadline - System.monotonic_time(:millisecond)),
             max_output_bytes: limits.discovery_bytes,
             effect: %{operation: :search_paths},
             before_effect: fn -> safe_rules(context, root, ignore, hidden, limits) end
           ),
         :ok <- discovery_status(captured),
         {:ok, boundary} <- Workspace.resolve(context, path),
         true <- resolved == boundary do
      flags = %{@flags | enumeration: captured.truncated}
      {paths, skipped} = confined_paths(context, captured.stdout)
      relative_root = Workspace.relative(context, resolved)

      paths =
        Enum.filter(paths, fn path ->
          GlobEx.match?(compiled_glob, Path.relative_to(path, relative_root))
        end)

      limited = Enum.take(paths, limits.files)

      flags = %{
        flags
        | enumeration: flags.enumeration or length(limited) < length(paths),
          files: skipped.changed > 0 or skipped.denied > 0
      }

      {:ok,
       %{
         path: Workspace.relative(context, resolved),
         paths: limited,
         skipped: skipped,
         flags: flags
       }}
    else
      false -> {:error, :invalid_search_request}
      {:error, {:executable_not_found, "rg"}} -> {:error, {:capability_unavailable, :ripgrep}}
      {:error, _reason} = error -> error
    end
  end

  defp directory_or_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: type, mode: mode, access: access}}
      when type in [:directory, :regular] ->
        if band(mode, 0o444) != 0 and access in [:read, :read_write],
          do: :ok,
          else: {:error, :eacces}

      {:ok, _stat} ->
        {:error, :not_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_glob(glob) when is_binary(glob) do
    cond do
      glob == "" or not String.valid?(glob) or String.contains?(glob, <<0>>) ->
        {:error, :invalid_pattern}

      byte_size(glob) > 4096 ->
        {:error, :invalid_pattern}

      Path.type(glob) == :absolute or String.contains?(glob, "..") ->
        {:error, :outside_workspace}

      true ->
        :ok
    end
  end

  defp safe_glob(_glob), do: {:error, :invalid_pattern}

  defp compile_glob(glob, hidden), do: GlobEx.compile(glob, match_dot: hidden)

  defp discovery_args(path, ignore, hidden) do
    args = [
      "--files",
      "--null",
      "--sort=path",
      "--no-config",
      "--no-require-git",
      "--no-ignore-parent",
      "--no-ignore-global",
      "--glob=!.git",
      "--glob=!**/.git/**",
      "--glob=!.oh-my-jido-*",
      "--glob=!**/.oh-my-jido-*"
    ]

    args = if hidden, do: args ++ ["--hidden"], else: args
    args = if ignore, do: args, else: args ++ ["--no-ignore"]
    args ++ ["--", "./" <> path]
  end

  defp discovery_status(%{status: :exited, exit_status: status}) when status in [0, 1], do: :ok
  defp discovery_status(%{status: :timed_out}), do: {:error, :search_timeout}
  defp discovery_status(%{status: :cancelled}), do: {:error, :search_cancelled}

  defp discovery_status(%{exit_status: status}),
    do: Files.failure(:search_failed, %{exit_status: status})

  defp confined_paths(context, output) do
    parts = :binary.split(output, <<0>>, [:global])
    complete = Enum.drop(parts, -1)

    {paths, skipped} =
      Enum.reduce(complete, {[], @skipped}, &confined_path(context, &1, &2))

    {paths |> Enum.uniq() |> Enum.sort(), skipped}
  end

  defp confined_path(context, candidate, {paths, skipped}) do
    case Workspace.resolve(context, candidate) do
      {:ok, resolved} ->
        case File.stat(resolved) do
          {:ok, %File.Stat{type: :regular}} ->
            {[Workspace.relative(context, resolved) | paths], skipped}

          _other ->
            {paths, Map.update!(skipped, :changed, &(&1 + 1))}
        end

      {:error, :outside_workspace} ->
        {paths, Map.update!(skipped, :unsafe, &(&1 + 1))}

      {:error, :eacces} ->
        {paths, Map.update!(skipped, :denied, &(&1 + 1))}

      {:error, _reason} ->
        {paths, Map.update!(skipped, :changed, &(&1 + 1))}
    end
  end

  defp retain_paths([], _limits, paths, bytes, _count, flags), do: {paths, bytes, flags}

  defp retain_paths([_path | _rest], limits, paths, bytes, count, flags)
       when count == limits.results do
    {paths, bytes, %{flags | results: true}}
  end

  defp retain_paths([path | rest], limits, paths, bytes, count, flags) do
    next_bytes = bytes + byte_size(Jason.encode!(path)) + 1

    if next_bytes > limits.output_bytes do
      {paths, bytes, %{flags | output: true}}
    else
      retain_paths(rest, limits, [path | paths], next_bytes, count + 1, flags)
    end
  end

  defp matcher(pattern, opts, limits) when is_binary(pattern) do
    mode = Keyword.get(opts, :mode, "literal")
    case_sensitive = Keyword.get(opts, :case_sensitive, true)

    cond do
      pattern == "" or not String.valid?(pattern) or String.contains?(pattern, <<0>>) ->
        {:error, :invalid_pattern}

      byte_size(pattern) > limits.pattern_bytes ->
        {:error, :invalid_pattern}

      mode not in ["literal", "regex"] or not is_boolean(case_sensitive) ->
        {:error, :invalid_pattern}

      true ->
        compile_matcher(pattern, mode, case_sensitive)
    end
  end

  defp matcher(_pattern, _opts, _limits), do: {:error, :invalid_pattern}

  defp compile_matcher(pattern, "literal", true), do: {:ok, {:literal, pattern}}

  defp compile_matcher(pattern, mode, case_sensitive) do
    source = if mode == "literal", do: Regex.escape(pattern), else: pattern
    options = if case_sensitive, do: "u", else: "ui"

    case Regex.compile(source, options) do
      {:ok, regex} -> {:ok, {:regex, Regex.re_pattern(regex)}}
      {:error, _reason} -> {:error, :invalid_pattern}
    end
  end

  defp scan(context, discovery, matcher, limits) do
    state = %{
      matches: [],
      count: 0,
      output_bytes: 0,
      scanned_files: 0,
      scanned_bytes: 0,
      skipped: discovery.skipped,
      flags: discovery.flags,
      deadline: limits.deadline,
      halted: false
    }

    Enum.reduce_while(discovery.paths, {:ok, state}, fn path, {:ok, state} ->
      scan_path(context, path, matcher, limits, state)
    end)
  end

  defp scan_path(context, path, matcher, limits, state) do
    cond do
      state.halted ->
        {:halt, {:ok, state}}

      expired?(state) ->
        {:halt, {:ok, %{state | flags: %{state.flags | deadline: true}}}}

      true ->
        case scan_file(context, path, matcher, limits, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, _reason} = error -> {:halt, error}
        end
    end
  end

  defp scan_file(_context, _path, _matcher, limits, state)
       when state.scanned_bytes >= limits.scan_bytes do
    {:ok, %{state | halted: true, flags: %{state.flags | files: true}}}
  end

  defp scan_file(context, path, matcher, limits, state) do
    state = %{state | scanned_files: state.scanned_files + 1}

    case Files.read_bytes(context, path, max_file_bytes: limits.scan_bytes - state.scanned_bytes) do
      {:ok, file} ->
        if file.binary do
          {:ok,
           %{
             state
             | scanned_bytes: state.scanned_bytes + byte_size(file.content),
               skipped: Map.update!(state.skipped, :binary, &(&1 + 1))
           }}
        else
          state = %{state | scanned_bytes: state.scanned_bytes + byte_size(file.content)}
          scan_lines(file.content, 0, 1, file, matcher, limits, state)
        end

      {:error, %{reason: :file_too_large}} ->
        {:ok, skip_file(state, :large)}

      {:error, %{reason: :eacces}} ->
        {:ok, skip_file(state, :denied)}

      {:error, %{reason: :outside_workspace}} ->
        {:ok, skip_file(state, :unsafe)}

      {:error, %{reason: reason}}
      when reason in [:enoent, :concurrent_change, :not_regular_file] ->
        {:ok, skip_file(state, :changed)}

      {:error, _reason} = error ->
        error
    end
  end

  defp skip_file(state, reason) do
    %{
      state
      | flags: %{state.flags | files: true},
        skipped: Map.update!(state.skipped, reason, &(&1 + 1))
    }
  end

  defp scan_lines(content, offset, _line, _file, _matcher, _limits, state)
       when offset >= byte_size(content), do: {:ok, state}

  defp scan_lines(_content, _offset, _line, _file, _matcher, _limits, %{halted: true} = state),
    do: {:ok, state}

  defp scan_lines(content, offset, line, file, matcher, limits, state) do
    if expired?(state) do
      {:ok, %{state | halted: true, flags: %{state.flags | deadline: true}}}
    else
      {text, next} = next_line(content, offset)

      with {:ok, state} <- match_line(text, line, file, matcher, limits, state) do
        scan_lines(content, next, line + 1, file, matcher, limits, state)
      end
    end
  end

  defp next_line(content, offset) do
    case :binary.match(content, "\n", scope: {offset, byte_size(content) - offset}) do
      {index, 1} ->
        length = index - offset

        length =
          if length > 0 and :binary.at(content, index - 1) == 13, do: length - 1, else: length

        {binary_part(content, offset, length), index + 1}

      :nomatch ->
        {binary_part(content, offset, byte_size(content) - offset), byte_size(content)}
    end
  end

  defp match_line(text, line, file, matcher, limits, state) do
    case match_position(text, matcher) do
      :nomatch -> {:ok, state}
      {:error, reason} -> {:error, reason}
      {:ok, column} -> retain_match(text, line, column, file, limits, state)
    end
  end

  defp match_position(text, {:literal, pattern}) do
    case :binary.match(text, pattern) do
      :nomatch -> :nomatch
      {offset, _length} -> {:ok, offset + 1}
    end
  end

  defp match_position(text, {:regex, compiled}) do
    case :re.run(text, compiled, [
           :report_errors,
           {:capture, :first, :index},
           {:match_limit, 100_000},
           {:match_limit_recursion, 1000}
         ]) do
      :nomatch -> :nomatch
      {:match, [{offset, _length}]} -> {:ok, offset + 1}
      {:error, reason} -> Files.failure(:regex_limit, %{matching_error: reason})
    end
  end

  defp retain_match(_text, _line, _column, _file, limits, state)
       when state.count == limits.results do
    {:ok, %{state | halted: true, flags: %{state.flags | results: true}}}
  end

  defp retain_match(text, line, column, file, limits, state) do
    retained = Files.truncate_utf8(text, limits.line_bytes)
    partial = byte_size(retained) < byte_size(text)

    match = %{
      path: file.path,
      line: line,
      column: column,
      text: retained,
      text_truncated: partial,
      snapshot: file.snapshot
    }

    next_bytes = state.output_bytes + byte_size(Jason.encode!(match)) + 1

    if next_bytes > limits.output_bytes do
      {:ok, %{state | halted: true, flags: %{state.flags | output: true}}}
    else
      {:ok,
       %{
         state
         | matches: [match | state.matches],
           count: state.count + 1,
           output_bytes: next_bytes,
           flags: %{state.flags | lines: state.flags.lines or partial}
       }}
    end
  end

  defp expired?(state), do: System.monotonic_time(:millisecond) >= state.deadline

  defp deadline(limits) do
    if System.monotonic_time(:millisecond) < limits.deadline,
      do: :ok,
      else: {:error, :search_timeout}
  end

  defp truncated?(flags), do: Enum.any?(flags, fn {_name, truncated} -> truncated end)

  defp safe_rules(_context, _root, false, _hidden, _limits), do: :ok

  defp safe_rules(context, root, true, hidden, limits) do
    case walk_rules(context, [root], hidden, limits, 0) do
      {:ok, _count} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp walk_rules(_context, [], _hidden, _limits, count), do: {:ok, count}

  defp walk_rules(context, [directory | rest], hidden, limits, count) do
    depth = context |> Workspace.relative(directory) |> Path.split() |> length()

    cond do
      System.monotonic_time(:millisecond) >= limits.deadline ->
        {:error, :search_timeout}

      count >= limits.walk_entries or depth > limits.depth ->
        {:error, :search_traversal_limit}

      true ->
        with {:ok, boundary} <- Workspace.resolve(context, directory),
             true <- boundary == directory,
             :ok <- directory_or_file(directory),
             {:ok, entries} <- File.ls(directory),
             true <- count + length(entries) <= limits.walk_entries,
             {:ok, directories} <-
               inspect_rule_entries(context, directory, entries, hidden, limits.deadline) do
          walk_rules(context, directories ++ rest, hidden, limits, count + length(entries))
        else
          false -> {:error, :search_traversal_limit}
          {:error, _reason} = error -> error
        end
    end
  end

  defp inspect_rule_entries(context, directory, entries, hidden, deadline) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, directories} ->
      path = Path.join(directory, entry)

      if System.monotonic_time(:millisecond) >= deadline do
        {:halt, {:error, :search_timeout}}
      else
        inspect_rule_entry(context, path, entry, hidden, directories)
      end
    end)
  end

  defp inspect_rule_entry(context, path, entry, _hidden, directories) when entry in @rule_files do
    continue_rule_scan(rule_path(context, path), directories)
  end

  defp inspect_rule_entry(context, path, ".git", _hidden, directories) do
    continue_rule_scan(git_rules(context, path), directories)
  end

  defp inspect_rule_entry(_context, path, entry, hidden, directories) do
    if not hidden and String.starts_with?(entry, ".") do
      {:cont, {:ok, directories}}
    else
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, [path | directories]}}
        {:ok, _stat} -> {:cont, {:ok, directories}}
        {:error, :enoent} -> {:cont, {:ok, directories}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp continue_rule_scan(:ok, directories), do: {:cont, {:ok, directories}}
  defp continue_rule_scan({:error, _reason} = error, _directories), do: {:halt, error}

  defp rule_path(context, path) do
    case Workspace.resolve(context, path, allow_missing: true) do
      {:ok, resolved} ->
        case File.stat(resolved) do
          {:ok, %File.Stat{type: :regular}} -> directory_or_file(resolved)
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
          {:ok, _stat} -> {:error, :unsafe_ignore_rules}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git_rules(context, path) do
    with {:ok, resolved} <- Workspace.resolve(context, path),
         {:ok, stat} <- File.stat(resolved) do
      case stat.type do
        :directory ->
          rule_path(context, Path.join(resolved, "info/exclude"))

        :regular ->
          git_file_rules(context, resolved)

        _other ->
          {:error, :unsafe_ignore_rules}
      end
    end
  end

  defp git_file_rules(context, resolved) do
    with {:ok, file} <- Files.read_bytes(context, resolved, max_file_bytes: 64 * 1024),
         false <- file.binary,
         "gitdir:" <> target <- String.trim(file.content),
         target = Path.expand(String.trim(target), Path.dirname(resolved)),
         {:ok, target} <- Workspace.resolve(context, target) do
      rule_path(context, Path.join(target, "info/exclude"))
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :unsafe_ignore_rules}
    end
  end
end
