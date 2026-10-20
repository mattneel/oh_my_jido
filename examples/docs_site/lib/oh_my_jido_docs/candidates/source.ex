defmodule OhMyJidoDocs.Candidates.Source do
  @moduledoc """
  Bounded, confined source snapshots. Manifests contain logical POSIX permission
  bits, byte sizes and SHA-256 hashes, keyed by repository-relative file name.

  `manifest/1` inventories a snapshot, including newly authored files. Initial
  repositories use `selected_manifest/2`: native Git selects tracked working
  bytes, plus explicitly approved directories; packaged repositories use a
  confined allowlist instead. Neither operation evaluates project code.

  Frozen trees physically strip write bits. Their persisted manifest retains the
  original modes: use `verify/3` with `readonly: true`, not a fresh physical-mode
  manifest, to verify them. `copy/3` restores those logical modes in a fresh tree.

  Public certificate/public-key PEM is ordinary source. A PEM private-key
  boundary is rejected as `:private_key_source` while hashing and copying,
  regardless of the filename, including boundaries split across read chunks.
  """

  import Bitwise

  @excluded_components MapSet.new(~w(
    .git deps _build node_modules .runtime .data .cache
    secrets .secrets .ssh .aws .config .hex .mix .npm .yarn .pnpm-store
    .fetch .elixir_ls .expert .omp .next .nuxt .svelte-kit .turbo .parcel-cache
    .pytest_cache __pycache__ .mypy_cache .ruff_cache coverage cover log logs
    tmp temp var .DS_Store .env .netrc .npmrc .pypirc credentials credentials.json
    .git-credentials .authinfo .envrc .direnv .docker .fly .terraform .venv venv
    id_rsa id_ed25519 secret.exs secrets.exs secrets.json credentials.exs credentials.yml
    erl_crash.dump
  ))
  @operational_components MapSet.new(~w(runtime cache caches))
  @source_containers ~w(lib src include test tests assets docs)
  @packaged_paths ~w(mix.exs mix.lock lib priv config test vendor)
  @chunk_bytes 65_536
  @pem_overlap 512
  @private_key_pem ~r/(?:\A|\n)[\t ]{0,64}-----BEGIN (?:[A-Z0-9][A-Z0-9 -]{0,96} )?PRIVATE KEY-----/
  @default_max_files 25_000
  @default_max_entries 100_000
  @default_max_directories 50_000
  @default_max_depth 64
  @default_max_bytes 268_435_456
  @default_max_file_bytes 33_554_432
  @default_max_diff_bytes 2_097_152

  @doc """
  Inventories every non-excluded regular source file beneath a root.

  `max_files`, `max_entries`, `max_directories`, `max_depth`, `max_bytes` and
  `max_file_bytes` optionally override source limits for trusted inventories
  such as privately staged dependency receipts. Budgets are global across
  selected paths: all visited entries, including empty directories and excluded
  names, consume the entry limit; inspected non-excluded directories also consume
  the directory limit. Excluded subtrees are never descended. Defaults are
  100,000 entries, 50,000 directories and 64 relative path components; an `:all`
  inventory counts its root as one entry and directory. Directory listings must
  fit the remaining entry budget before sorting or descent.
  """
  def manifest(root, opts \\ [])

  def manifest(root, opts) when is_binary(root) and is_list(opts) do
    opts = Keyword.put(opts, :limits, limits(opts))

    with {:ok, root} <- secure_root(root),
         {:ok, inventory} <- inventory_paths(root, Keyword.get(opts, :paths, :all), opts) do
      hash_paths(root, inventory.paths, limits(opts))
    end
  end

  def manifest(_, _), do: {:error, :unsafe_path}

  @doc "Selects tracked current bytes and approved additions, or packaged source."
  def selected_manifest(root, opts \\ []) do
    app = Keyword.get(opts, :app_relative, config(:source_app_path, "examples/docs_site"))
    approved = config(:approved_source_paths, [app])
    packaged = config(:packaged_source_paths, @packaged_paths)
    opts = Keyword.put(opts, :limits, limits(opts))

    with {:ok, root} <- secure_root(root),
         :ok <- validate_allowlist(approved),
         :ok <- validate_allowlist(packaged),
         {:ok, tracked} <- tracked_paths(root),
         {:ok, inventory} <- selected_paths(root, tracked, packaged, approved, opts) do
      hash_paths(root, inventory.paths, limits(opts))
    end
  end

  defp selected_paths(root, :packaged, packaged, approved, opts) do
    inventory_paths(root, packaged ++ approved, opts)
  end

  defp selected_paths(root, tracked, _packaged, approved, opts) do
    with {:ok, inventory} <- inventory_paths(root, approved, opts) do
      Enum.reduce_while(
        tracked,
        {:ok, inventory},
        &inventory_path_step(&1, &2, root, opts, false)
      )
    end
  end

  @doc "Hashes sorted names, logical modes, lengths and byte hashes deterministically."
  def digest(manifest) when is_map(manifest) do
    manifest
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {path, entry}, context ->
      :crypto.hash_update(context, [
        <<byte_size(path)::unsigned-big-64>>,
        path,
        <<entry["mode"]::unsigned-big-32, entry["size"]::unsigned-big-64>>,
        Base.decode16!(entry["sha256"], case: :lower)
      ])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Validates a complete snapshot, rejecting additions, deletions and mode drift."
  def verify(root, expected, opts \\ []) do
    with :ok <- validate_manifest(expected),
         {:ok, actual} <-
           manifest(
             root,
             Keyword.take(opts, [
               :readonly,
               :max_files,
               :max_entries,
               :max_directories,
               :max_depth,
               :max_bytes,
               :max_file_bytes
             ])
           ),
         true <- map_size(actual) == map_size(expected),
         true <- Enum.all?(expected, &matching_entry?(&1, actual, opts)) do
      :ok
    else
      false -> {:error, :source_changed}
      {:error, _} = error -> error
    end
  end

  @doc "Copies into a missing or empty destination, validating bytes during copying."
  def copy(root, destination, manifest) do
    with :ok <- validate_manifest(manifest),
         {:ok, root} <- secure_root(root),
         {:ok, destination} <- empty_destination(destination) do
      result = copy_files(root, destination, manifest)

      if result != :ok, do: remove_tree(destination)
      result
    end
  end

  defp copy_files(root, destination, manifest) do
    manifest
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {relative, entry}, :ok ->
      case copy_file(root, destination, relative, entry) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Strips physical write bits after validating the logical snapshot."
  def read_only(root, manifest) do
    with :ok <- verify(root, manifest),
         :ok <- chmod_files(root, manifest) do
      chmod_directories(root)
    end
  end

  @doc "Produces a complete full-index unified/binary review diff, never truncating."
  def diff(base_root, new_root, base_manifest, new_manifest) do
    with :ok <- validate_manifest(base_manifest),
         :ok <- validate_manifest(new_manifest) do
      changed = changed_paths(base_manifest, new_manifest)
      temporary = Path.join(Path.dirname(Path.expand(new_root)), ".source-diff-" <> unique())

      try do
        with :ok <- ensure_directory(temporary),
             :ok <- copy(base_root, Path.join(temporary, "a"), Map.take(base_manifest, changed)),
             :ok <- copy(new_root, Path.join(temporary, "b"), Map.take(new_manifest, changed)),
             {:ok, output} <- diff_files(temporary, changed, base_manifest, new_manifest) do
          {:ok, output, changed}
        end
      after
        remove_tree(temporary)
      end
    end
  end

  def changed_paths(base, current) do
    (Map.keys(base) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(base, &1) != Map.get(current, &1)))
    |> Enum.sort()
  end

  @doc false
  def validate_manifest(manifest) when is_map(manifest) do
    limits = limits()

    if map_size(manifest) > limits.files do
      {:error, :source_too_large}
    else
      Enum.reduce_while(manifest, {:ok, 0}, &validate_manifest_entry(&1, &2, manifest, limits))
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  def validate_manifest(_), do: {:error, :invalid_manifest}

  defp validate_manifest_entry({path, entry}, {:ok, size}, manifest, bounds) do
    with :ok <- relative_path(path),
         false <- excluded?(path),
         :ok <- validate_entry(entry),
         true <- entry["size"] <= bounds.file_bytes,
         true <- size + entry["size"] <= bounds.bytes,
         false <- has_file_parent?(path, manifest) do
      {:cont, {:ok, size + entry["size"]}}
    else
      {:error, _} = error -> {:halt, error}
      true -> {:halt, {:error, :unsafe_path}}
      false -> {:halt, {:error, :source_too_large}}
    end
  end

  @doc false
  def relative_path(path) when is_binary(path) do
    parts = String.split(path, "/")

    if String.valid?(path) and Path.type(path) == :relative and
         not String.contains?(path, <<0>>) and
         Enum.all?(parts, &(&1 not in ["", ".", ".."])) do
      :ok
    else
      {:error, :unsafe_path}
    end
  end

  def relative_path(_), do: {:error, :unsafe_path}

  @doc false
  def excluded?(relative) do
    parts = String.split(relative, "/")

    generated_asset?(relative) or operational_path?(parts) or
      Enum.any?(parts, fn component ->
        MapSet.member?(@excluded_components, component) or
          String.starts_with?(component, [".env.", ".#"]) or
          String.ends_with?(String.downcase(component), [
            ".key",
            ".p12",
            ".pfx",
            ".sqlite",
            ".sqlite3",
            ".db",
            ".sqlite-wal",
            ".sqlite-shm",
            ".sqlite3-wal",
            ".sqlite3-shm",
            ".db-wal",
            ".db-shm",
            ".db-journal",
            ".secret.exs",
            ".beam"
          ])
      end)
  end

  # Operational directories stay private, but lib/foo/runtime and docs/runtime
  # are authored source, not application state. Secret components stay forbidden.
  defp operational_path?([]), do: false
  defp operational_path?([component | _rest]) when component in @source_containers, do: false

  defp operational_path?([component | rest]) do
    MapSet.member?(@operational_components, component) or operational_path?(rest)
  end

  defp generated_asset?(relative) do
    parts = String.split(relative, "/")

    parts
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.any?(fn
      ["priv", "static", "assets"] -> true
      ["priv", "static", "cache_manifest.json"] -> true
      _ -> false
    end)
  end

  @doc false
  def secure_root(root) when is_binary(root) do
    expanded = Path.expand(root)

    with :ok <- check_directory_chain(expanded) do
      {:ok, expanded}
    end
  end

  def secure_root(_), do: {:error, :unsafe_path}

  @doc false
  def ensure_directory(path) do
    expanded = Path.expand(path)

    expanded
    |> Path.split()
    |> Enum.reduce_while(nil, &ensure_directory_component/2)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp ensure_directory_component(component, parent) do
    current = if parent, do: Path.join(parent, component), else: component

    case File.lstat(current) do
      {:ok, %File.Stat{type: :directory}} -> {:cont, current}
      {:ok, _} -> {:halt, {:error, :unsafe_path}}
      {:error, :enoent} -> create_directory_component(current)
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp create_directory_component(current) do
    case File.mkdir(current) do
      :ok -> {:cont, current}
      {:error, :eexist} -> existing_directory_component(current)
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp existing_directory_component(current) do
    case File.lstat(current) do
      {:ok, %File.Stat{type: :directory}} -> {:cont, current}
      _ -> {:halt, {:error, :unsafe_path}}
    end
  end

  @doc false
  def file_path(root, relative) do
    with :ok <- relative_path(relative),
         false <- excluded?(relative),
         :ok <- check_parents(root, relative) do
      {:ok, Path.join(root, relative)}
    else
      true -> {:error, :unsafe_path}
      {:error, _} = error -> error
    end
  end

  @doc false
  def remove_tree(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        File.chmod(root, 0o700)

        case File.ls(root) do
          {:ok, entries} -> Enum.each(entries, &remove_tree(Path.join(root, &1)))
          _ -> :ok
        end

        File.rmdir(root)

      {:ok, %File.Stat{type: :regular}} ->
        File.chmod(root, 0o600)
        File.rm(root)

      {:ok, _} ->
        File.rm(root)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def git(root, arguments, max_output \\ 4_194_304) do
    executable = config(:source_git_executable, "git")

    case System.find_executable(executable) do
      nil -> {:error, :git_unavailable}
      git -> run_git(git, root, arguments, max_output)
    end
  end

  @doc false
  def initialize_git(root) do
    with {:ok, _, 0} <- git(root, ["init", "--quiet", "--template=", "--initial-branch=source"]),
         {:ok, _, 0} <- git(root, ["add", "--force", "--all", "--", "."]),
         {:ok, _, 0} <-
           git(root, [
             "-c",
             "user.name=OhMyJido Docs",
             "-c",
             "user.email=docs@localhost",
             "commit",
             "--quiet",
             "--allow-empty",
             "--no-gpg-sign",
             "--no-verify",
             "-m",
             "Adopt reviewed source snapshot"
           ]) do
      :ok
    else
      {:ok, _, _} -> {:error, :git_failed}
      {:error, _} = error -> error
    end
  end

  defp inventory_paths(root, :all, opts), do: walk(root, "", new_inventory(), opts)

  defp inventory_paths(root, paths, opts) when is_list(paths) do
    if length(paths) > limits(opts).entries do
      {:error, :source_too_large}
    else
      paths
      |> Enum.sort()
      |> Enum.reduce_while({:ok, new_inventory()}, &inventory_path_step(&1, &2, root, opts))
    end
  end

  defp inventory_paths(_, _, _), do: {:error, :unsafe_path}

  defp inventory_path_step(relative, {:ok, state}, root, opts, descend? \\ true) do
    with :ok <- relative_path(relative),
         {:ok, next} <- walk(root, relative, state, opts, descend?) do
      {:cont, {:ok, next}}
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp new_inventory do
    %{paths: MapSet.new(), visited: MapSet.new(), entries: 0, directories: 0}
  end

  defp walk(root, relative, state, opts, descend? \\ true) do
    absolute = if relative == "", do: root, else: Path.join(root, relative)

    case visit_entry(relative, state, limits(opts)) do
      {:seen, _} ->
        {:ok, state}

      {:ok, state} ->
        if (relative != "" and excluded?(relative)) or
             excluded_root?(absolute, Keyword.get(opts, :exclude_roots, [])) do
          {:ok, state}
        else
          inventory_entry(root, relative, absolute, state, opts, descend?)
        end

      {:error, _} = error ->
        error
    end
  end

  defp visit_entry(relative, state, bounds) do
    cond do
      MapSet.member?(state.visited, relative) ->
        {:seen, state}

      state.entries >= bounds.entries or path_depth(relative) > bounds.depth ->
        {:error, :source_too_large}

      true ->
        {:ok, %{state | visited: MapSet.put(state.visited, relative), entries: state.entries + 1}}
    end
  end

  defp inventory_entry(root, relative, absolute, state, opts, descend?) do
    case check_parents(root, relative) do
      :ok -> inventory_stat(root, relative, absolute, state, opts, descend?)
      {:error, :enoent} -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  defp inventory_stat(root, relative, absolute, state, opts, descend?) do
    case File.lstat(absolute) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        with {:ok, state} <- visit_directory(state, opts),
             :ok <- directory_permissions(mode, opts) do
          descend_inventory(root, relative, absolute, state, opts, descend?)
        end

      {:ok, %File.Stat{type: :regular}} ->
        if MapSet.size(state.paths) >= limits(opts).files,
          do: {:error, :source_too_large},
          else: {:ok, %{state | paths: MapSet.put(state.paths, relative)}}

      {:ok, _} ->
        {:error, :unsafe_path}

      {:error, :enoent} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp visit_directory(state, opts) do
    if state.directories >= limits(opts).directories,
      do: {:error, :source_too_large},
      else: {:ok, %{state | directories: state.directories + 1}}
  end

  defp descend_inventory(root, relative, absolute, state, opts, true),
    do: inventory_directory(root, relative, absolute, state, opts)

  defp descend_inventory(_root, _relative, _absolute, state, _opts, false), do: {:ok, state}

  defp inventory_directory(root, relative, absolute, state, opts) do
    with {:ok, names} <- File.ls(absolute),
         :ok <- within_total_limit(state.entries + length(names), limits(opts).entries) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, state}, &inventory_child_step(&1, &2, root, relative, opts))
    end
  end

  defp inventory_child_step(name, state, root, relative, opts) do
    child = if relative == "", do: name, else: relative <> "/" <> name
    inventory_path_step(child, state, root, opts)
  end

  defp path_depth(""), do: 0
  defp path_depth(relative), do: relative |> String.split("/") |> length()

  defp directory_permissions(mode, opts) do
    if Keyword.get(opts, :readonly, false) and band(mode, 0o222) != 0,
      do: {:error, :source_changed},
      else: :ok
  end

  defp hash_paths(root, paths, bounds) do
    if Enum.count(paths) > bounds.files do
      {:error, :source_too_large}
    else
      Enum.reduce_while(Enum.sort(paths), {:ok, %{}, 0}, &hash_path(&1, &2, root, bounds))
      |> case do
        {:ok, result, _} -> {:ok, result}
        error -> error
      end
    end
  end

  defp hash_path(relative, {:ok, result, total}, root, bounds) do
    with {:ok, path} <- file_path(root, relative),
         {:ok, before} <- regular_stat(path, bounds.file_bytes),
         :ok <- within_total_limit(before.size + total, bounds.bytes),
         {:ok, hash, size} <- hash_file(path, bounds.file_bytes, before),
         {:ok, after_stat} <- regular_stat(path, bounds.file_bytes),
         true <- stable_stat?(before, after_stat) and size == before.size do
      entry = %{"sha256" => hash, "mode" => band(before.mode, 0o777), "size" => size}
      {:cont, {:ok, Map.put(result, relative, entry), total + size}}
    else
      false -> {:halt, {:error, :source_changed}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp hash_file(path, maximum, before) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with :ok <- opened_file_matches(file, before) do
          hash_chunks(file, :crypto.hash_init(:sha256), 0, maximum, {"", true})
        end
      after
        :file.close(file)
      end
    end
  end

  defp hash_chunks(file, context, size, maximum, pem_state) do
    case :file.read(file, @chunk_bytes) do
      {:ok, chunk} ->
        with :ok <- within_total_limit(size + byte_size(chunk), maximum),
             {:ok, pem_state} <- inspect_pem_chunk(chunk, pem_state) do
          hash_chunks(
            file,
            :crypto.hash_update(context, chunk),
            size + byte_size(chunk),
            maximum,
            pem_state
          )
        end

      :eof ->
        {:ok, Base.encode16(:crypto.hash_final(context), case: :lower), size}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inspect_pem_chunk(chunk, {tail, at_start?}) do
    bytes = tail <> chunk
    probe = if at_start?, do: bytes, else: <<0>> <> bytes

    if Regex.match?(@private_key_pem, probe) do
      {:error, :private_key_source}
    else
      retained = min(byte_size(bytes), @pem_overlap)
      tail = :binary.copy(binary_part(bytes, byte_size(bytes) - retained, retained))
      {:ok, {tail, at_start? and byte_size(bytes) <= @pem_overlap}}
    end
  end

  defp within_total_limit(bytes, maximum) do
    if bytes <= maximum, do: :ok, else: {:error, :source_too_large}
  end

  defp copy_file(root, destination, relative, expected) do
    with {:ok, source} <- file_path(root, relative),
         {:ok, before} <- regular_stat(source),
         true <- copy_mode?(before.mode, expected["mode"]),
         true <- before.size == expected["size"],
         target <- Path.join(destination, relative),
         :ok <- ensure_directory(Path.dirname(target)),
         {:ok, input} <- :file.open(String.to_charlist(source), [:read, :binary, :raw]) do
      result =
        try do
          with :ok <- opened_file_matches(input, before) do
            copy_open_file(input, target, expected)
          end
        after
          :file.close(input)
        end

      with :ok <- result,
           {:ok, after_stat} <- regular_stat(source),
           true <- stable_stat?(before, after_stat),
           :ok <- check_parents(root, relative),
           :ok <- File.chmod(target, expected["mode"]) do
        :ok
      else
        false -> {:error, :source_changed}
        {:error, _} = error -> error
      end
    else
      false -> {:error, :source_changed}
      {:error, _} = error -> error
    end
  end

  defp copy_open_file(input, target, expected) do
    with {:ok, output} <-
           :file.open(String.to_charlist(target), [:write, :binary, :raw, :exclusive]) do
      try do
        with {:ok, hash, size} <-
               copy_chunks(
                 input,
                 output,
                 :crypto.hash_init(:sha256),
                 0,
                 expected["size"],
                 {"", true}
               ),
             true <- hash == expected["sha256"] and size == expected["size"],
             :ok <- :file.sync(output) do
          :ok
        else
          false -> {:error, :source_changed}
          {:error, _} = error -> error
        end
      after
        :file.close(output)
      end
    end
  end

  defp copy_chunks(input, output, context, size, expected_size, pem_state) do
    case :file.read(input, @chunk_bytes) do
      {:ok, chunk} when size + byte_size(chunk) <= expected_size ->
        with {:ok, pem_state} <- inspect_pem_chunk(chunk, pem_state),
             :ok <- :file.write(output, chunk) do
          copy_chunks(
            input,
            output,
            :crypto.hash_update(context, chunk),
            size + byte_size(chunk),
            expected_size,
            pem_state
          )
        end

      {:ok, _} ->
        {:error, :source_changed}

      :eof ->
        {:ok, Base.encode16(:crypto.hash_final(context), case: :lower), size}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_destination(path) when is_binary(path) do
    path = Path.expand(path)

    with :ok <- ensure_directory(Path.dirname(path)) do
      prepare_empty_destination(path)
    end
  end

  defp empty_destination(_), do: {:error, :unsafe_path}

  defp prepare_empty_destination(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with :ok <- File.mkdir(path), do: {:ok, path}

      {:ok, %File.Stat{type: :directory}} ->
        empty_directory(path)

      {:ok, _} ->
        {:error, :unsafe_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_directory(path) do
    case File.ls(path) do
      {:ok, []} -> {:ok, path}
      {:ok, _} -> {:error, :destination_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracked_paths(root) do
    case File.lstat(Path.join(root, ".git")) do
      {:error, :enoent} ->
        {:ok, :packaged}

      {:ok, %File.Stat{type: type}} when type in [:directory, :regular] ->
        output_limit = max(limits().files * 4096, 65_536)

        case git(
               root,
               [
                 "--work-tree=" <> root,
                 "-c",
                 "core.bare=false",
                 "ls-files",
                 "-z",
                 "--cached",
                 "--full-name",
                 "--",
                 "."
               ],
               output_limit
             ) do
          {:ok, output, 0} -> {:ok, String.split(output, <<0>>, trim: true)}
          {:ok, _, _} -> {:error, :git_failed}
          {:error, _} = error -> error
        end

      {:ok, _} ->
        {:error, :unsafe_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp diff_files(root, paths, base, current) do
    Enum.reduce_while(paths, {:ok, [], 0}, &append_file_diff(&1, &2, root, base, current))
    |> case do
      {:ok, output, _} -> {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp append_file_diff(path, {:ok, output, size}, root, base, current) do
    remaining = limits().diff_bytes - size

    if remaining <= 0 do
      {:halt, {:error, :diff_too_large}}
    else
      case file_diff(root, path, Map.get(base, path), Map.get(current, path), remaining) do
        {:ok, patch} when byte_size(patch) <= remaining ->
          {:cont, {:ok, [patch | output], size + byte_size(patch)}}

        {:ok, _} ->
          {:halt, {:error, :diff_too_large}}

        {:error, :git_output_too_large} ->
          {:halt, {:error, :diff_too_large}}

        {:error, _} = error ->
          {:halt, error}
      end
    end
  end

  defp file_diff(root, path, before, after_entry, remaining) do
    if before && after_entry && before["sha256"] == after_entry["sha256"] do
      {:ok, diff_header(path) <> mode_diff(before, after_entry)}
    else
      file_content_diff(root, path, before, after_entry, remaining)
    end
  end

  defp file_content_diff(root, path, before, after_entry, remaining) do
    old = if before, do: "a/" <> path, else: "/dev/null"
    new = if after_entry, do: "b/" <> path, else: "/dev/null"
    header = diff_header(path)
    mode_header = mode_diff(before, after_entry)

    arguments = [
      "diff",
      "--no-index",
      "--binary",
      "--full-index",
      "--no-ext-diff",
      "--no-textconv",
      "--no-renames",
      "--no-color",
      "--src-prefix=",
      "--dst-prefix=",
      "--",
      old,
      new
    ]

    with {:ok, output} <- review_git_diff(root, arguments, remaining) do
      {index, body} = patch_body(output)
      index = normalize_index_mode(index, before, after_entry)

      labels =
        if String.starts_with?(body, "@@"),
          do: "--- " <> quote_path(old) <> "\n+++ " <> quote_path(new) <> "\n",
          else: ""

      {:ok, header <> mode_header <> index <> labels <> body}
    end
  end

  defp diff_header(path) do
    "diff --git " <> quote_path("a/" <> path) <> " " <> quote_path("b/" <> path) <> "\n"
  end

  defp review_git_diff(root, arguments, maximum) do
    case git(root, arguments, maximum) do
      {:ok, output, status} when status in [0, 1] ->
        if String.valid?(output) and not String.contains?(output, <<0>>),
          do: {:ok, output},
          else: binary_review_diff(root, arguments, maximum)

      {:ok, _, _} ->
        {:error, :git_failed}

      {:error, _} = error ->
        error
    end
  end

  # Invalid UTF-8 is source bytes, not invalid JSON. The highest-priority local
  # attribute forces a lossless ASCII Git binary patch, including when authored
  # .gitattributes would otherwise force these bytes to be treated as text.
  defp binary_review_diff(root, arguments, maximum) do
    attributes = Path.join(root, ".git/info/attributes")

    with {:ok, _, 0} <- git(root, ["init", "--quiet", "--template=", "--initial-branch=review"]),
         :ok <- ensure_directory(Path.dirname(attributes)),
         :ok <- File.write(attributes, "* -diff\n", [:binary, :exclusive]) do
      try do
        with {:ok, output, status} when status in [0, 1] <- git(root, arguments, maximum),
             true <- String.valid?(output) and not String.contains?(output, <<0>>) do
          {:ok, output}
        else
          false -> {:error, :non_utf8_diff}
          {:ok, _, _} -> {:error, :git_failed}
          {:error, _} = error -> error
        end
      after
        File.rm(attributes)
      end
    else
      {:ok, _, _} -> {:error, :git_failed}
      {:error, _} = error -> error
    end
  end

  defp patch_body(output) do
    lines = String.split(output, "\n", trim: false)
    index = Enum.find(lines, "", &String.starts_with?(&1, "index "))

    body =
      Enum.drop_while(
        lines,
        &(not String.starts_with?(&1, ["@@", "GIT binary patch", "Binary files "]))
      )

    {if(index == "", do: "", else: index <> "\n"), Enum.join(body, "\n")}
  end

  defp normalize_index_mode("", _, _), do: ""

  defp normalize_index_mode(index, before, after_entry) do
    hashes = index |> String.trim_trailing("\n") |> String.split(" ") |> Enum.at(1)

    suffix =
      if before && after_entry && before["mode"] == after_entry["mode"],
        do: " " <> git_mode(before["mode"]),
        else: ""

    "index " <> hashes <> suffix <> "\n"
  end

  defp mode_diff(nil, entry) do
    "new file mode " <>
      git_mode(entry["mode"]) <> "\nnew POSIX mode " <> posix_mode(entry["mode"]) <> "\n"
  end

  defp mode_diff(entry, nil) do
    "deleted file mode " <>
      git_mode(entry["mode"]) <> "\nold POSIX mode " <> posix_mode(entry["mode"]) <> "\n"
  end

  defp mode_diff(before, after_entry) do
    if before["mode"] == after_entry["mode"],
      do: "",
      else:
        "old mode " <>
          git_mode(before["mode"]) <>
          "\nnew mode " <>
          git_mode(after_entry["mode"]) <>
          "\nold POSIX mode " <>
          posix_mode(before["mode"]) <>
          "\nnew POSIX mode " <> posix_mode(after_entry["mode"]) <> "\n"
  end

  defp git_mode(mode), do: "100" <> (mode |> Integer.to_string(8) |> String.pad_leading(3, "0"))

  defp posix_mode(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")

  defp quote_path(path) do
    if String.match?(path, ~r/^[\x21-\x7E]+$/) and not String.contains?(path, ["\\", "\""]) do
      path
    else
      escaped = for <<byte <- path>>, into: "", do: quote_byte(byte)

      "\"" <> escaped <> "\""
    end
  end

  defp quote_byte(?\"), do: "\\\""
  defp quote_byte(?\\), do: "\\\\"
  defp quote_byte(?\n), do: "\\n"
  defp quote_byte(?\r), do: "\\r"
  defp quote_byte(?\t), do: "\\t"

  defp quote_byte(byte) when byte < 32 or byte >= 127,
    do: "\\" <> (byte |> Integer.to_string(8) |> String.pad_leading(3, "0"))

  defp quote_byte(byte), do: <<byte>>

  defp run_git(executable, root, arguments, max_output) do
    arguments =
      [
        "--no-pager",
        "--no-optional-locks",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "init.templateDir=",
        "-c",
        "credential.helper=",
        "-c",
        "core.askPass=/bin/false",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.untrackedCache=false",
        "-c",
        "core.attributesFile=/dev/null",
        "-c",
        "core.excludesFile=/dev/null",
        "-c",
        "core.autocrlf=false",
        "-c",
        "core.fileMode=true",
        "-c",
        "protocol.allow=never",
        "-c",
        "protocol.file.allow=never",
        "-c",
        "diff.external=",
        "-c",
        "commit.gpgSign=false",
        "-c",
        "tag.gpgSign=false",
        "-c",
        "maintenance.auto=false",
        "-c",
        "gc.auto=0"
      ] ++ arguments

    environment = %{
      "PATH" => Path.dirname(executable) <> ":/usr/bin:/bin",
      "HOME" => "/nonexistent",
      "XDG_CONFIG_HOME" => "/nonexistent",
      "LANG" => "C",
      "LC_ALL" => "C",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_ATTR_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_ASKPASS" => "/bin/false",
      "SSH_ASKPASS" => "/bin/false",
      "GIT_SSH_COMMAND" => "/bin/false",
      "GIT_ALLOW_PROTOCOL" => "",
      "GIT_OPTIONAL_LOCKS" => "0",
      "GIT_PAGER" => "cat"
    }

    cleared = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

    overrides =
      Enum.map(environment, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    env =
      Enum.reject(cleared, fn {key, _} -> Map.has_key?(environment, List.to_string(key)) end) ++
        overrides

    try do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, Enum.map(arguments, &String.to_charlist/1)},
          {:cd, String.to_charlist(root)},
          {:env, env}
        ])

      deadline = System.monotonic_time(:millisecond) + config(:source_git_timeout, 30_000)
      collect_git(port, [], 0, max_output, deadline)
    rescue
      ArgumentError -> {:error, :git_failed}
      ErlangError -> {:error, :git_failed}
    end
  end

  defp collect_git(port, chunks, bytes, maximum, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if bytes + byte_size(chunk) <= maximum do
          collect_git(port, [chunk | chunks], bytes + byte_size(chunk), maximum, deadline)
        else
          close_port(port)
          {:error, :git_output_too_large}
        end

      {^port, {:exit_status, status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining ->
        close_port(port)
        {:error, :git_timeout}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp regular_stat(path, maximum \\ limits_file_bytes()) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        cond do
          band(stat.mode, 0o7000) != 0 -> {:error, :unsafe_mode}
          stat.size > maximum -> {:error, :source_too_large}
          true -> {:ok, stat}
        end

      {:ok, _} ->
        {:error, :unsafe_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stable_stat?(before, after_stat) do
    Enum.all?([:inode, :major_device, :minor_device, :size, :mode, :mtime, :ctime], fn field ->
      Map.fetch!(before, field) == Map.fetch!(after_stat, field)
    end)
  end

  defp opened_file_matches(file, before) do
    case :file.read_file_info(file, time: :posix) do
      {:ok,
       {:file_info, size, :regular, _access, _atime, mtime, ctime, mode, _links, major, minor,
        inode, _uid, _gid}} ->
        if {size, mtime, ctime, mode, major, minor, inode} ==
             {before.size, before.mtime, before.ctime, before.mode, before.major_device,
              before.minor_device, before.inode},
           do: :ok,
           else: {:error, :source_changed}

      {:ok, _} ->
        {:error, :unsafe_path}

      {:error, _} = error ->
        error
    end
  end

  defp matching_entry?({path, entry}, actual, opts) do
    case Map.fetch(actual, path) do
      {:ok, physical} ->
        expected_mode =
          if Keyword.get(opts, :readonly, false),
            do: band(entry["mode"], 0o555),
            else: entry["mode"]

        physical == Map.put(entry, "mode", expected_mode)

      :error ->
        false
    end
  end

  defp copy_mode?(physical, logical), do: band(physical, 0o777) in [logical, band(logical, 0o555)]

  defp validate_entry(%{"sha256" => hash, "mode" => mode, "size" => size} = entry)
       when is_binary(hash) and is_integer(mode) and mode >= 0 and mode <= 0o777 and
              is_integer(size) and size >= 0 and map_size(entry) == 3 do
    if String.match?(hash, ~r/^[0-9a-f]{64}$/), do: :ok, else: {:error, :invalid_manifest}
  end

  defp validate_entry(_), do: {:error, :invalid_manifest}

  defp has_file_parent?(path, manifest) do
    path
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.reduce_while("", fn part, prefix ->
      prefix = if prefix == "", do: part, else: prefix <> "/" <> part
      if Map.has_key?(manifest, prefix), do: {:halt, true}, else: {:cont, prefix}
    end)
    |> Kernel.==(true)
  end

  defp validate_allowlist(paths) when is_list(paths) do
    Enum.reduce_while(paths, :ok, &validate_allowlist_path/2)
  end

  defp validate_allowlist(_), do: {:error, :unsafe_path}

  defp validate_allowlist_path(path, :ok) do
    case relative_path(path) do
      :ok -> if excluded?(path), do: {:halt, {:error, :unsafe_path}}, else: {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_directory_chain(path) do
    path
    |> Path.split()
    |> Enum.reduce_while(nil, fn component, parent ->
      current = if parent, do: Path.join(parent, component), else: component

      case File.lstat(current) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, current}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp check_parents(root, ""), do: check_directory_chain(root)

  defp check_parents(root, relative) do
    with :ok <- check_directory_chain(root) do
      relative
      |> Path.dirname()
      |> case do
        "." -> :ok
        directory -> check_directory_chain(Path.join(root, directory))
      end
    end
  end

  defp excluded_root?(path, roots) do
    Enum.any?(roots, fn root ->
      root = Path.expand(root)
      path == root or String.starts_with?(path, root <> "/")
    end)
  end

  defp chmod_files(root, manifest) do
    Enum.reduce_while(manifest, :ok, fn {relative, entry}, :ok ->
      case File.chmod(Path.join(root, relative), band(entry["mode"], 0o555)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp chmod_directories(root) do
    with {:ok, names} <- File.ls(root),
         :ok <- Enum.reduce_while(names, :ok, &chmod_directory_entry(&1, &2, root)) do
      File.chmod(root, 0o555)
    end
  end

  defp chmod_directory_entry(name, :ok, root) do
    path = Path.join(root, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        chmod_step(chmod_directories(path))

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        chmod_step(File.chmod(path, band(mode, 0o555)))

      {:ok, _} ->
        {:halt, {:error, :unsafe_path}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp chmod_step(:ok), do: {:cont, :ok}
  defp chmod_step({:error, _} = error), do: {:halt, error}

  defp limits, do: limits([])

  defp limits(opts) do
    case Keyword.fetch(opts, :limits) do
      {:ok, bounds} ->
        bounds

      :error ->
        %{
          files: Keyword.get(opts, :max_files, config(:source_max_files, @default_max_files)),
          entries:
            Keyword.get(opts, :max_entries, config(:source_max_entries, @default_max_entries)),
          directories:
            Keyword.get(
              opts,
              :max_directories,
              config(:source_max_directories, @default_max_directories)
            ),
          depth: Keyword.get(opts, :max_depth, config(:source_max_depth, @default_max_depth)),
          bytes: Keyword.get(opts, :max_bytes, config(:source_max_bytes, @default_max_bytes)),
          file_bytes: Keyword.get(opts, :max_file_bytes, limits_file_bytes()),
          diff_bytes: config(:source_max_diff_bytes, @default_max_diff_bytes)
        }
    end
  end

  defp limits_file_bytes, do: config(:source_max_file_bytes, @default_max_file_bytes)
  defp unique, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp config(key, default), do: Application.get_env(:oh_my_jido_docs, key, default)
end
