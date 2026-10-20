defmodule OhMyJidoDocs.Workspaces do
  @moduledoc """
  Source-first workspaces and reviewed, durable source adoption.

  Source and data locations are trusted application configuration. Initial
  selection includes native Git's tracked *working bytes*, even in a dirty
  checkout, and recursively approved source paths. Packaged source uses an
  allowlist. Editable trees, immutable bases, candidates, and host-only metadata
  occupy separate directories; project code is never loaded into this VM.

  Adoption never writes to the configured checkout. It copies current source,
  applies only the reviewed paths, creates an offline local Git commit, then
  atomically replaces a durable current-source pointer. Creation and adoption
  share a reentrant node-local lock. Managed workspace writers and adoption share
  a nonblocking lease; an active writer returns `:workspace_busy`.
  Review and adoption also check durable managed-writer settlement while holding
  the lease and at commit; unavailable writer state fails closed with
  `:writer_state_unavailable`.
  Adoption checks the protected workspace digest at the pointer boundary and
  rejects an active deployment with `:source_deployment_in_progress`.
  A conflicting reviewed path
  returns `:base_conflict`; source movement during staging returns
  `:source_changed`, and a stale pointer returns `:source_pointer_conflict`.
  Other errors include `:workspace_changed`, `:candidate_changed`,
  `:invalid_metadata`, `:unsafe_path`, `:source_too_large`, `:diff_too_large`,
  `:no_changes`, Git execution errors, and ordinary filesystem error atoms.
  `:no_changes` creates no candidate directory or receipt.

  Exactly one private editor VM may own a `data_dir`. Allocation leases are
  synced outside editable source before copying. Fetch, discard, reconciliation,
  creation and adoption share the same local source lock. Cleanup never guesses
  ownership from a UUID alone; missing/corrupt ownership evidence is retained
  with an uncertainty receipt instead of deleting possibly unrelated source.
  """

  alias OhMyJidoDocs.Candidates.{EffectLease, Source}
  alias OhMyJidoDocs.Editor

  @metadata_limit 33_554_432
  @identity_keys ~w(source_path manifest base_manifest source_root app_relative changed_paths digest)
  @allocation_owner "OhMyJidoDocs.Workspaces"
  @temporary_metadata_limit 16

  @doc "Creates a complete editable repository snapshot and an immutable base."
  def create(id) do
    with :ok <- valid_id(id) do
      locked(fn settings -> create_workspace(settings, id) end)
    end
  end

  @doc "Recovers a completed allocation when its caller did not persist the result."
  def fetch(id) do
    with :ok <- valid_id(id) do
      locked(&fetch_workspace(&1, id))
    end
  end

  defp fetch_workspace(settings, id) do
    case workspace_record(settings, id) do
      {:ok, metadata} -> fetch_completed_workspace(settings, metadata)
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp fetch_completed_workspace(settings, metadata) do
    with {:ok, _} <- workspace_metadata(settings, metadata["workspace"]),
         :ok <- Source.verify(metadata["base_root"], metadata["base_manifest"], readonly: true) do
      {:ok, %{workspace: metadata["workspace"], base_revision: metadata["base_revision"]}}
    else
      {:error, :enoent} -> {:error, :incomplete_workspace}
      {:error, _} = error -> error
    end
  end

  @doc "Discards only this run's owned allocation; referenced candidate bases are retained."
  def discard(id) do
    with :ok <- valid_id(id) do
      locked(fn settings -> discard_workspace(settings, id) end)
    end
  end

  @doc """
  Reconciles interrupted owned copies under the source lock.

  Complete/pending batches return `{:ok, receipt}`. Any unresolved cleanup or
  ownership uncertainty returns `{:error, {:staging_cleanup_uncertain, receipt}}`;
  the per-path receipt is persisted in either case. `source_cleanup_limit`
  (default 128, maximum 1024) bounds each batch; `source_cleanup_scan_limit`
  (default 10,000) bounds inventory. A durable cursor advances later batches.
  Completed/canonical source is preserved.
  """
  def reconcile_staging do
    locked(&reconcile_allocations/1)
  end

  @doc "Reads protected workspace metadata, outside the editable source tree."
  def describe(workspace) when is_binary(workspace) do
    with {:ok, settings} <- settings(),
         {:ok, metadata} <- workspace_metadata(settings, workspace) do
      {:ok, describe_map(metadata)}
    end
  end

  def describe(_), do: {:error, :invalid_workspace}

  @doc "Captures all allowed source additions and an exact, immutable review diff."
  def freeze(workspace, candidate_id) when is_binary(workspace) do
    with :ok <- valid_id(candidate_id) do
      with_workspace_lease(workspace, fn ->
        locked(&freeze_settled_workspace(&1, workspace, candidate_id))
      end)
    end
  end

  def freeze(_, _), do: {:error, :invalid_workspace}

  defp freeze_settled_workspace(settings, workspace, candidate_id) do
    with :ok <- Editor.source_write_settled(workspace) do
      freeze_workspace(settings, workspace, candidate_id)
    end
  end

  @doc "Checks the current editable snapshot against its reviewed logical digest."
  def verify_workspace(workspace, expected_digest) do
    with {:ok, description} <- describe(workspace),
         {:ok, manifest} <- Source.manifest(description.root),
         true <- Source.digest(manifest) == expected_digest do
      :ok
    else
      false -> {:error, :workspace_changed}
      {:error, _} = error -> error
    end
  end

  @doc "Compares all original current bytes, not Git HEAD, to a captured base."
  def verify_base(source_root, base_manifest) when is_binary(source_root) do
    result =
      with :ok <- Source.validate_manifest(base_manifest),
           {:ok, settings} <- settings(),
           {:ok, current} <- authority(settings),
           true <- current.root == Path.expand(source_root),
           true <- current.manifest == base_manifest do
        :ok
      end

    if result == :ok, do: :ok, else: {:error, :base_conflict}
  end

  def verify_base(_, _), do: {:error, :base_conflict}

  @doc "Returns the source root future workspaces will use, including prior adoption."
  def current_source do
    locked(fn settings ->
      with {:ok, current} <- authority(settings) do
        {:ok, %{source_root: current.root, digest: Source.digest(current.manifest)}}
      end
    end)
  end

  @doc "Adopts reviewed paths into a new durable source, without changing host files."
  def adopt(candidate) when is_map(candidate) do
    with {:ok, settings} <- settings(),
         {:ok, receipt} <- candidate_metadata(settings, candidate) do
      with_workspace_lease(receipt["workspace"], fn ->
        locked(&adopt_guarded_candidate(&1, candidate))
      end)
    end
  end

  def adopt(_), do: {:error, :invalid_candidate}

  defp adopt_guarded_candidate(settings, candidate) do
    with :ok <- EffectLease.active_source_guard() do
      adopt_candidate(settings, candidate)
    end
  end

  @doc false
  def with_source_lock(function) when is_function(function, 0) do
    locked(fn _settings -> function.() end)
  end

  @doc false
  def with_workspace_lease(workspace, function)
      when is_binary(workspace) and is_function(function, 0) do
    with {:ok, settings} <- settings(),
         {:ok, metadata} <- workspace_metadata(settings, workspace) do
      resource = {__MODULE__, :workspace, settings.data_dir, metadata["workspace"]}
      with_process_lock(resource, function, 0, :workspace_busy)
    end
  end

  def with_workspace_lease(_, _), do: {:error, :invalid_workspace}

  defp create_workspace(settings, id) do
    directory = Path.join(settings.workspaces, id)
    temporary = allocation_record(settings, "workspace", id)["staging"]

    with_allocation(settings, "workspace", id, fn ->
      with :ok <- absent(directory, :workspace_exists),
           :ok <- absent(workspace_metadata_path(settings, id), :workspace_exists),
           {:ok, current} <- authority(settings),
           :ok <- validate_application(current.root, settings.app_relative),
           :ok <- Source.copy(current.root, Path.join(temporary, "base"), current.manifest),
           :ok <- Source.copy(current.root, Path.join(temporary, "source"), current.manifest),
           :ok <- Source.read_only(Path.join(temporary, "base"), current.manifest),
           :ok <- recheck_authority(settings, current),
           :ok <- File.rename(temporary, directory) do
        complete_workspace(settings, id, current, directory)
      end
    end)
  end

  defp complete_workspace(settings, id, current, directory) do
    root = Path.join(directory, "source")
    workspace = Path.join(root, settings.app_relative)
    revision = Source.digest(current.manifest)

    metadata = %{
      "schema" => 1,
      "id" => id,
      "root" => root,
      "workspace" => workspace,
      "app_relative" => settings.app_relative,
      "base_root" => Path.join(directory, "base"),
      "base_revision" => revision,
      "base_manifest" => current.manifest,
      "source_root" => current.root,
      "source_revision" => revision
    }

    result =
      with :ok <- Source.initialize_git(workspace),
           :ok <- recheck_authority(settings, current) do
        write_metadata(workspace_metadata_path(settings, id), metadata)
      end

    case result do
      :ok ->
        {:ok, %{workspace: workspace, base_revision: revision}}

      {:error, _} = error ->
        Source.remove_tree(directory)
        error
    end
  end

  defp freeze_workspace(settings, workspace, id) do
    directory = Path.join(settings.candidates, id)
    temporary = allocation_record(settings, "candidate", id)["staging"]
    destination = Path.join(directory, "source")

    with_allocation(settings, "candidate", id, fn ->
      with :ok <- absent(directory, :candidate_exists),
           :ok <- absent(candidate_metadata_path(settings, id), :candidate_exists),
           {:ok, metadata} <- workspace_metadata(settings, workspace),
           :ok <- Source.verify(metadata["base_root"], metadata["base_manifest"], readonly: true),
           {:ok, manifest} <- Source.manifest(metadata["root"]),
           :ok <- validate_application(metadata["root"], metadata["app_relative"]),
           :ok <- require_source_changes(metadata["base_manifest"], manifest),
           :ok <- Source.copy(metadata["root"], Path.join(temporary, "source"), manifest),
           {:ok, patch, changed_paths} <-
             Source.diff(
               metadata["base_root"],
               Path.join(temporary, "source"),
               metadata["base_manifest"],
               manifest
             ),
           :ok <- Source.read_only(Path.join(temporary, "source"), manifest),
           :ok <- verify_editable(metadata["root"], manifest),
           :ok <- Editor.source_write_settled(metadata["workspace"]),
           :ok <- File.rename(temporary, directory) do
        digest = Source.digest(manifest)

        receipt = %{
          "schema" => 1,
          "id" => id,
          "source_path" => destination,
          "app_path" => Path.join(destination, metadata["app_relative"]),
          "digest" => digest,
          "manifest" => manifest,
          "base_manifest" => metadata["base_manifest"],
          "base_revision" => metadata["base_revision"],
          "source_root" => metadata["source_root"],
          "base_root" => metadata["base_root"],
          "app_relative" => metadata["app_relative"],
          "diff" => patch,
          "changed_paths" => changed_paths,
          "workspace_digest" => digest,
          "workspace" => metadata["workspace"]
        }

        publish_candidate(settings, id, receipt, directory)
      end
    end)
  end

  defp publish_candidate(settings, id, receipt, directory) do
    case write_metadata(candidate_metadata_path(settings, id), receipt) do
      :ok ->
        {:ok, freeze_map(receipt)}

      {:error, _} = error ->
        Source.remove_tree(directory)
        error
    end
  end

  defp require_source_changes(base, current) do
    if Source.changed_paths(base, current) == [], do: {:error, :no_changes}, else: :ok
  end

  defp adopt_candidate(settings, candidate) do
    with {:ok, receipt} <- candidate_metadata(settings, candidate),
         :ok <- Editor.source_write_settled(receipt["workspace"]),
         :ok <- immutable_candidate(receipt),
         {:ok, current} <- authority(settings),
         true <- current.root == receipt["source_root"],
         :ok <- reviewed_paths_unchanged(current, receipt),
         :ok <- Source.verify(receipt["base_root"], receipt["base_manifest"], readonly: true) do
      stage_adoption(settings, current, receipt)
    else
      false -> {:error, :source_pointer_conflict}
      {:error, _} = error -> error
    end
  end

  defp stage_adoption(settings, current, receipt) do
    id = unique()
    temporary = allocation_record(settings, "source", id)["staging"]
    final = Path.join(settings.sources, id)
    reviewed = receipt["changed_paths"]

    manifest =
      current.manifest |> Map.drop(reviewed) |> Map.merge(Map.take(receipt["manifest"], reviewed))

    with_allocation(settings, "source", id, fn ->
      with :ok <- Source.validate_manifest(manifest),
           :ok <- Source.copy(current.root, temporary, current.manifest),
           :ok <- apply_reviewed_paths(temporary, receipt),
           :ok <- Source.verify(temporary, manifest),
           :ok <- validate_application(temporary, receipt["app_relative"]),
           :ok <- Source.initialize_git(temporary),
           :ok <- Source.read_only(temporary, manifest),
           :ok <- File.rename(temporary, final) do
        finish_adoption(settings, current, receipt, final, manifest, id)
      end
    end)
  end

  defp finish_adoption(settings, current, receipt, final, manifest, id) do
    case commit_source_pointer(settings, current, receipt, final, manifest) do
      {:ok, _} = result ->
        result

      {:error, _} = error ->
        cleanup = cleanup_path(final)
        receipt = cleanup_receipt(settings, "adopt", [cleanup], 0, nil, id)

        with {:ok, _} <- persist_cleanup(settings, "adopt-" <> id <> ".json", receipt) do
          error
        end
    end
  end

  defp apply_reviewed_paths(destination, receipt) do
    changed = receipt["changed_paths"]
    additions = Map.take(receipt["manifest"], changed)
    overlay = destination <> ".reviewed"

    try do
      with :ok <- Source.copy(receipt["source_path"], overlay, additions),
           :ok <- remove_reviewed_files(destination, changed) do
        move_reviewed_files(overlay, destination, additions)
      end
    after
      Source.remove_tree(overlay)
    end
  end

  defp remove_reviewed_files(root, changed) do
    changed
    |> Enum.sort_by(&(-length(Path.split(&1))))
    |> Enum.reduce_while(:ok, &remove_reviewed_file(&1, &2, root))
  end

  defp remove_reviewed_file(relative, :ok, root) do
    absolute = Path.join(root, relative)

    case File.lstat(absolute) do
      {:ok, %File.Stat{type: :regular}} ->
        remove_reviewed_regular_file(absolute, root)

      {:ok, %File.Stat{type: :directory}} ->
        remove_reviewed_directory(absolute)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:cont, :ok}

      {:ok, _} ->
        {:halt, {:error, :unsafe_path}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp remove_reviewed_regular_file(absolute, root) do
    with :ok <- File.rm(absolute),
         :ok <- prune_empty_parents(Path.dirname(absolute), root) do
      {:cont, :ok}
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp remove_reviewed_directory(absolute) do
    case File.rmdir(absolute) do
      :ok ->
        {:cont, :ok}

      {:error, reason} when reason in [:enotempty, :eexist] ->
        {:halt, {:error, :base_conflict}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp move_reviewed_files(overlay, root, additions) do
    Enum.reduce_while(Enum.sort(additions), :ok, fn {relative, _entry}, :ok ->
      destination = Path.join(root, relative)

      with :ok <- Source.ensure_directory(Path.dirname(destination)),
           :ok <- File.rename(Path.join(overlay, relative), destination) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # POSIX permits EEXIST as well as ENOTEMPTY for a non-empty directory.
  defp prune_empty_parents(directory, root) when directory == root, do: :ok

  defp prune_empty_parents(directory, root) do
    case File.rmdir(directory) do
      :ok -> prune_empty_parents(Path.dirname(directory), root)
      {:error, :enoent} -> :ok
      {:error, reason} when reason in [:enotempty, :eexist] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_source_pointer(settings, current, receipt, final, manifest) do
    pointer = %{
      "schema" => 1,
      "source_root" => final,
      "configured_source_root" => settings.source_root,
      "digest" => Source.digest(manifest),
      "manifest" => manifest,
      "candidate_digest" => receipt["digest"],
      "candidate_id" => receipt["id"],
      "parent_source_root" => current.root,
      "base_revision" => receipt["base_revision"],
      "parent_digest" => Source.digest(current.manifest),
      "generation" => current.generation + 1
    }

    with {:ok, temporary} <- json_temporary(settings.pointer, pointer) do
      try do
        with :ok <- Source.verify(final, manifest, readonly: true),
             :ok <- immutable_candidate(receipt),
             :ok <- reviewed_paths_unchanged(current, receipt),
             :ok <- retire_current_source_allocation(settings, current),
             :ok <- recheck_authority(settings, current),
             :ok <- Editor.source_write_settled(receipt["workspace"]),
             :ok <- verify_workspace(receipt["workspace"], receipt["workspace_digest"]),
             :ok <- File.rename(temporary, settings.pointer) do
          {:ok, Map.take(pointer, ["source_root", "digest", "candidate_digest", "base_revision"])}
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp reviewed_paths_unchanged(current, receipt) do
    changed = receipt["changed_paths"]

    topmost =
      Enum.reject(changed, fn path ->
        Enum.any?(changed, &(path != &1 and String.starts_with?(path, &1 <> "/")))
      end)

    case Source.manifest(current.root, paths: topmost) do
      {:ok, actual} ->
        actual = logical_current_modes(actual, current)

        if actual == Map.take(receipt["base_manifest"], changed),
          do: :ok,
          else: {:error, :base_conflict}

      {:error, _} ->
        {:error, :base_conflict}
    end
  end

  defp logical_current_modes(actual, %{readonly: false}), do: actual

  defp logical_current_modes(actual, current) do
    Map.new(actual, fn {path, entry} ->
      logical = Map.get(current.manifest, path)
      {path, if(logical, do: Map.put(entry, "mode", logical["mode"]), else: entry)}
    end)
  end

  defp immutable_candidate(receipt) do
    case Source.verify(receipt["source_path"], receipt["manifest"], readonly: true) do
      :ok -> :ok
      {:error, _} -> {:error, :candidate_changed}
    end
  end

  defp recheck_authority(settings, expected) do
    with {:ok, token} <- pointer_token(settings.pointer),
         true <- token == expected.token,
         {:ok, manifest} <- authority_manifest(settings, expected),
         true <- manifest == expected.manifest,
         {:ok, final_token} <- pointer_token(settings.pointer),
         true <- final_token == expected.token do
      :ok
    else
      false ->
        case pointer_token(settings.pointer) do
          {:ok, token} when token != expected.token -> {:error, :source_pointer_conflict}
          _ -> {:error, :source_changed}
        end

      {:error, _} = error ->
        error
    end
  end

  defp authority_manifest(_settings, %{readonly: true} = current) do
    with :ok <- Source.verify(current.root, current.manifest, readonly: true) do
      {:ok, current.manifest}
    end
  end

  defp authority_manifest(settings, current) do
    Source.selected_manifest(current.root,
      app_relative: settings.app_relative,
      exclude_roots: [settings.data_dir]
    )
  end

  defp authority(settings) do
    case read_json(settings.pointer) do
      {:error, :enoent} ->
        current = %{
          root: settings.source_root,
          manifest: %{},
          token: nil,
          generation: 0,
          readonly: false
        }

        with {:ok, manifest} <- authority_manifest(settings, current),
             do: {:ok, %{current | manifest: manifest}}

      {:ok, pointer, token} ->
        with :ok <- validate_pointer(settings, pointer),
             :ok <- Source.verify(pointer["source_root"], pointer["manifest"], readonly: true) do
          {:ok,
           %{
             root: pointer["source_root"],
             manifest: pointer["manifest"],
             token: token,
             generation: pointer["generation"],
             readonly: true
           }}
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_pointer(settings, pointer) do
    with %{
           "schema" => 1,
           "source_root" => root,
           "manifest" => manifest,
           "digest" => digest,
           "generation" => generation
         } <- pointer,
         true <- is_integer(generation) and generation > 0,
         true <- pointer["configured_source_root"] == settings.source_root,
         {:ok, _id} <- confined_id(root, settings.sources, []),
         :ok <- Source.validate_manifest(manifest),
         true <- Source.digest(manifest) == digest do
      :ok
    else
      _ -> {:error, :invalid_metadata}
    end
  end

  defp workspace_metadata(settings, workspace) do
    workspace = Path.expand(workspace)

    with {:ok, id} <- workspace_id(workspace, settings.workspaces),
         {:ok, metadata} <- workspace_record(settings, id),
         true <- metadata["workspace"] == workspace,
         {:ok, _} <- Source.secure_root(metadata["root"]),
         {:ok, _} <- Source.secure_root(metadata["base_root"]) do
      {:ok, metadata}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_metadata}
    end
  end

  defp workspace_record(settings, id) do
    with {:ok, metadata, _} <- read_json(workspace_metadata_path(settings, id)),
         %{"schema" => 1, "app_relative" => relative, "base_manifest" => manifest} <- metadata,
         :ok <- Source.relative_path(relative),
         true <- metadata["id"] == id,
         root <- Path.join([settings.workspaces, id, "source"]),
         true <- metadata["root"] == root,
         true <- metadata["base_root"] == Path.join([settings.workspaces, id, "base"]),
         true <- metadata["workspace"] == Path.join(root, relative),
         true <- is_binary(metadata["source_root"]),
         :ok <- Source.validate_manifest(manifest),
         true <- Source.digest(manifest) == metadata["base_revision"],
         true <- metadata["source_revision"] == metadata["base_revision"] do
      {:ok, metadata}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_metadata}
    end
  end

  defp candidate_metadata(settings, candidate) do
    source_path = field(candidate, "source_path")

    with true <- is_binary(source_path),
         {:ok, id} <- confined_id(source_path, settings.candidates, ["source"]),
         {:ok, receipt} <- candidate_record(settings, id),
         true <- receipt["source_path"] == source_path,
         true <- Enum.all?(@identity_keys, &(field(candidate, &1) == receipt[&1])) do
      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_candidate}
    end
  end

  defp candidate_record(settings, id) do
    with {:ok, receipt, _} <- read_json(candidate_metadata_path(settings, id)),
         %{"schema" => 1, "manifest" => manifest, "base_manifest" => base} <- receipt,
         true <- receipt["id"] == id,
         true <- receipt["source_path"] == Path.join([settings.candidates, id, "source"]),
         {:ok, workspace_id} <- confined_id(receipt["base_root"], settings.workspaces, ["base"]),
         :ok <- Source.relative_path(receipt["app_relative"]),
         :ok <- Source.validate_manifest(manifest),
         :ok <- Source.validate_manifest(base),
         true <- Source.digest(manifest) == receipt["digest"],
         true <- receipt["workspace_digest"] == receipt["digest"],
         true <-
           receipt["workspace"] ==
             Path.join([settings.workspaces, workspace_id, "source", receipt["app_relative"]]),
         true <- Source.digest(base) == receipt["base_revision"],
         true <- Source.changed_paths(base, manifest) == receipt["changed_paths"],
         true <- is_binary(receipt["source_root"]) do
      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_candidate}
    end
  end

  defp workspace_id(workspace, parent) do
    case Path.split(Path.relative_to(workspace, parent)) do
      [id, "source" | rest] when rest != [] ->
        with :ok <- valid_id(id), do: {:ok, id}

      _ ->
        {:error, :invalid_workspace}
    end
  end

  defp confined_id(path, parent, suffix) when is_binary(path) do
    case Path.split(Path.relative_to(path, parent)) do
      [id | rest] ->
        with true <- rest == suffix,
             :ok <- valid_id(id),
             true <- Path.join([parent, id] ++ suffix) == path do
          {:ok, id}
        else
          _ -> {:error, :unsafe_path}
        end

      _ ->
        {:error, :unsafe_path}
    end
  end

  defp confined_id(_, _, _), do: {:error, :unsafe_path}

  defp describe_map(metadata) do
    %{
      root: metadata["root"],
      app_path: metadata["workspace"],
      app_relative: metadata["app_relative"],
      base_root: metadata["base_root"],
      base_revision: metadata["base_revision"],
      base_manifest: metadata["base_manifest"],
      source_root: metadata["source_root"],
      source_revision: metadata["source_revision"]
    }
  end

  defp freeze_map(receipt) do
    %{
      source_path: receipt["source_path"],
      app_path: receipt["app_path"],
      digest: receipt["digest"],
      manifest: receipt["manifest"],
      base_manifest: receipt["base_manifest"],
      base_revision: receipt["base_revision"],
      source_root: receipt["source_root"],
      base_root: receipt["base_root"],
      app_relative: receipt["app_relative"],
      diff: receipt["diff"],
      changed_paths: receipt["changed_paths"],
      workspace_digest: receipt["workspace_digest"],
      workspace: receipt["workspace"]
    }
  end

  defp field(map, key) do
    case key do
      "source_path" -> Map.get(map, :source_path, Map.get(map, key))
      "manifest" -> Map.get(map, :manifest, Map.get(map, key))
      "base_manifest" -> Map.get(map, :base_manifest, Map.get(map, key))
      "source_root" -> Map.get(map, :source_root, Map.get(map, key))
      "app_relative" -> Map.get(map, :app_relative, Map.get(map, key))
      "changed_paths" -> Map.get(map, :changed_paths, Map.get(map, key))
      "digest" -> Map.get(map, :digest, Map.get(map, key))
    end
  end

  defp validate_application(root, app_relative) do
    with {:ok, root_mix} <- Source.file_path(root, "mix.exs"),
         {:ok, app_mix} <- Source.file_path(root, app_relative <> "/mix.exs"),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(root_mix),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(app_mix) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_source_application}
    end
  end

  defp verify_editable(root, expected) do
    case Source.verify(root, expected) do
      :ok -> :ok
      {:error, _} -> {:error, :workspace_changed}
    end
  end

  defp settings do
    source_root =
      Application.get_env(:oh_my_jido_docs, :source_root, Path.expand("../../../..", __DIR__))

    app_relative = Application.get_env(:oh_my_jido_docs, :source_app_path, "examples/docs_site")

    with true <- is_binary(source_root) and String.valid?(source_root),
         :ok <- Source.relative_path(app_relative),
         false <- Source.excluded?(app_relative),
         source_root <- Path.expand(source_root),
         data_dir <-
           Application.get_env(
             :oh_my_jido_docs,
             :data_dir,
             Path.join(source_root, "var/docs_site")
           ),
         true <- is_binary(data_dir) and String.valid?(data_dir),
         data_dir <- Path.expand(data_dir, source_root),
         false <-
           source_root == data_dir or
             String.starts_with?(source_root, String.trim_trailing(data_dir, "/") <> "/"),
         :ok <- Source.ensure_directory(data_dir),
         :ok <- File.chmod(data_dir, 0o700),
         :ok <- infrastructure_directories(data_dir) do
      {:ok,
       %{
         source_root: source_root,
         app_relative: app_relative,
         data_dir: data_dir,
         workspaces: Path.join(data_dir, "workspaces"),
         candidates: Path.join(data_dir, "candidates"),
         sources: Path.join(data_dir, "sources"),
         pointer: Path.join(data_dir, "source/current.json"),
         workspace_metadata: Path.join(data_dir, "workspace_metadata"),
         candidate_metadata: Path.join(data_dir, "candidate_metadata"),
         allocations: Path.join(data_dir, "source_allocations"),
         cleanup: Path.join(data_dir, "source_cleanup")
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_source_configuration}
    end
  end

  defp infrastructure_directories(root) do
    Enum.reduce_while(
      ~w(workspaces candidates sources source workspace_metadata candidate_metadata source_allocations source_cleanup),
      :ok,
      fn name, :ok ->
        directory = Path.join(root, name)

        with :ok <- Source.ensure_directory(directory),
             :ok <- File.chmod(directory, 0o700) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end
    )
  end

  defp locked(function) do
    with {:ok, settings} <- settings() do
      with_process_lock(
        {__MODULE__, settings.data_dir},
        fn -> function.(settings) end,
        :infinity,
        :workspace_lock_unavailable
      )
    end
  end

  defp with_process_lock(resource, function, retries, unavailable) do
    key = {__MODULE__, :lock_depth, resource}
    depth = Process.get(key, 0)

    if depth > 0 do
      with_lock_depth(key, depth, function)
    else
      lock = {resource, self()}

      if :global.set_lock(lock, [node()], retries) do
        try do
          with_lock_depth(key, depth, function)
        after
          :global.del_lock(lock, [node()])
        end
      else
        {:error, unavailable}
      end
    end
  end

  defp with_lock_depth(key, depth, function) do
    Process.put(key, depth + 1)

    try do
      function.()
    after
      if depth == 0, do: Process.delete(key), else: Process.put(key, depth)
    end
  end

  defp allocation_record(settings, kind, id) do
    {parent, metadata} =
      case kind do
        "workspace" -> {settings.workspaces, workspace_metadata_path(settings, id)}
        "candidate" -> {settings.candidates, candidate_metadata_path(settings, id)}
        "source" -> {settings.sources, settings.pointer}
      end

    staging = Path.join(parent, ".staging-" <> kind <> "-" <> id)

    %{
      "schema" => 1,
      "owner" => @allocation_owner,
      "data_dir" => settings.data_dir,
      "kind" => kind,
      "id" => id,
      "staging" => staging,
      "final" => Path.join(parent, id),
      "metadata" => metadata,
      "auxiliary" => if(kind == "source", do: [staging <> ".reviewed"], else: []),
      "lease" => Path.join(settings.allocations, kind <> "-" <> id <> ".json")
    }
  end

  defp begin_allocation(settings, kind, id) do
    record = allocation_record(settings, kind, id)

    exists =
      case kind do
        "workspace" -> :workspace_exists
        "candidate" -> :candidate_exists
        "source" -> :allocation_pending
      end

    with :ok <- absent(record["final"], exists),
         :ok <- if(kind == "source", do: :ok, else: absent(record["metadata"], exists)),
         :ok <- absent(record["lease"], :allocation_pending),
         :ok <- require_absent([record["staging"] | record["auxiliary"]]) do
      write_metadata(record["lease"], record)
    end
  end

  defp require_absent(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case absent(path, :allocation_pending) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp read_allocation(settings, kind, id) do
    expected = allocation_record(settings, kind, id)

    with {:ok, record, _} <- read_json(expected["lease"]),
         true <- record == expected do
      {:ok, record}
    else
      false -> {:error, :invalid_allocation}
      {:error, _} = error -> error
    end
  end

  defp release_allocation(settings, kind, id) do
    with {:ok, record} <- read_allocation(settings, kind, id),
         {:ok, temporary} <- allocation_temporaries(record) do
      completed = allocation_completed(settings, record)
      removable = require_absent(temporary) == :ok

      if removable and (completed == {:ok, true} or absent(record["final"], :present) == :ok),
        do: File.rm(record["lease"]),
        else: :ok
    end
  end

  defp with_allocation(settings, kind, id, function) do
    with :ok <- begin_allocation(settings, kind, id) do
      record = allocation_record(settings, kind, id)

      try do
        function.()
      after
        Enum.each([record["staging"] | record["auxiliary"]], &Source.remove_tree/1)
        release_allocation(settings, kind, id)
      end
    end
  end

  defp allocation_completed(settings, %{"kind" => "workspace", "id" => id}) do
    completion(workspace_record(settings, id))
  end

  defp allocation_completed(settings, %{"kind" => "candidate", "id" => id}) do
    completion(candidate_record(settings, id))
  end

  defp allocation_completed(settings, %{"kind" => "source", "final" => final}) do
    with {:ok, current} <- cleanup_current_root(settings) do
      {:ok, current == final}
    end
  end

  defp completion({:ok, _}), do: {:ok, true}
  defp completion({:error, :enoent}), do: {:ok, false}
  defp completion({:error, _} = error), do: error

  defp retire_current_source_allocation(_settings, %{readonly: false}), do: :ok

  defp retire_current_source_allocation(settings, current) do
    with {:ok, id} <- confined_id(current.root, settings.sources, []) do
      case read_allocation(settings, "source", id) do
        {:error, :enoent} ->
          :ok

        {:ok, record} ->
          retire_source_allocation(record)

        {:error, _} = error ->
          error
      end
    end
  end

  defp retire_source_allocation(record) do
    with {:ok, lease_temporary} <- temporary_metadata(record["lease"]),
         receipts <- cleanup_paths([record["staging"] | record["auxiliary"]] ++ lease_temporary),
         false <- cleanup_failed?(receipts) do
      File.rm(record["lease"])
    else
      true -> {:error, :source_cleanup_failed}
      {:error, _} = error -> error
    end
  end

  defp discard_workspace(settings, id) do
    record = allocation_record(settings, "workspace", id)

    result =
      with {:ok, metadata} <- optional_record(workspace_record(settings, id)),
           {:ok, lease} <- optional_record(read_allocation(settings, "workspace", id)),
           :ok <- discard_owned(record, metadata, lease),
           :ok <- unreferenced_base(settings, Path.join(record["final"], "base")),
           {:ok, temporary} <- allocation_temporaries(record) do
        cleanup_discarded_workspace(record, metadata, lease, temporary)
      else
        {:error, reason} ->
          {:error, reason, [cleanup_item(record["final"], "retained", reason)]}
      end

    {outcome, items} =
      case result do
        {:ok, items} -> {:ok, items}
        {:error, reason, items} -> {{:error, reason}, items}
      end

    receipt = cleanup_receipt(settings, "discard", items, 0, nil, id)

    case persist_cleanup(settings, "discard-" <> id <> ".json", receipt) do
      {:ok, _} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_discarded_workspace(record, metadata, lease, temporary) do
    items = cleanup_paths(temporary ++ [record["final"]])

    if cleanup_failed?(items) do
      {:error, :workspace_cleanup_failed, items}
    else
      metadata_items = cleanup_paths(if(metadata, do: [record["metadata"]], else: []))
      items = items ++ metadata_items

      lease_items =
        if lease && not cleanup_failed?(metadata_items),
          do: cleanup_paths([record["lease"]]),
          else: []

      items = items ++ lease_items

      if cleanup_failed?(items),
        do: {:error, :workspace_cleanup_failed, items},
        else: {:ok, items}
    end
  end

  defp optional_record({:ok, record}), do: {:ok, record}
  defp optional_record({:error, :enoent}), do: {:ok, nil}
  defp optional_record({:error, _} = error), do: error

  defp discard_owned(record, metadata, lease) do
    cond do
      lease ->
        :ok

      metadata && absent(record["staging"], :present) == :ok ->
        :ok

      metadata ->
        {:error, :unowned_staging}

      absent(record["final"], :present) == :ok and absent(record["staging"], :present) == :ok ->
        :ok

      true ->
        {:error, :unowned_workspace}
    end
  end

  defp unreferenced_base(settings, base) do
    unreferenced_base_from(protected_references(settings, "candidate"), base)
  end

  defp unreferenced_base_from({:ok, records}, base) do
    if Enum.any?(records, &(&1["base_root"] == base)),
      do: {:error, :candidate_references_workspace},
      else: :ok
  end

  defp unreferenced_base_from({:error, _} = error, _base), do: error

  defp protected_references(settings, kind) do
    directory =
      if kind == "candidate", do: settings.candidate_metadata, else: settings.workspace_metadata

    with {:ok, names} <- cleanup_listing(directory) do
      Enum.reduce_while(
        names,
        {:ok, []},
        &protected_reference_step(&1, &2, settings, kind, directory)
      )
    end
  end

  defp protected_reference_step(name, {:ok, rows}, settings, kind, directory) do
    if String.ends_with?(name, ".json") do
      id = String.trim_trailing(name, ".json")

      with :ok <- valid_id(id),
           {:ok, record, _} <- read_json(Path.join(directory, name)),
           true <- record["schema"] == 1 and record["id"] == id,
           true <- is_binary(record["source_root"]),
           :ok <- valid_reference(settings, kind, id, record) do
        {:cont, {:ok, [Map.take(record, ["base_root", "source_root"]) | rows]}}
      else
        _ -> {:halt, {:error, :protected_metadata_uncertain}}
      end
    else
      {:cont, {:ok, rows}}
    end
  end

  defp valid_reference(settings, "candidate", id, record) do
    with true <- record["source_path"] == Path.join([settings.candidates, id, "source"]),
         {:ok, _} <- confined_id(record["base_root"], settings.workspaces, ["base"]) do
      :ok
    else
      _ -> {:error, :protected_metadata_uncertain}
    end
  end

  defp valid_reference(settings, "workspace", id, record) do
    if record["root"] == Path.join([settings.workspaces, id, "source"]) and
         record["base_root"] == Path.join([settings.workspaces, id, "base"]),
       do: :ok,
       else: {:error, :protected_metadata_uncertain}
  end

  defp cleanup_current_root(settings) do
    case read_json(settings.pointer) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, pointer, _} ->
        with :ok <- validate_pointer(settings, pointer), do: {:ok, pointer["source_root"]}

      {:error, _} = error ->
        error
    end
  end

  defp source_unreferenced(context, final) do
    with {:ok, current} <- context.current,
         false <- current == final,
         {:ok, candidates} <- context.candidates,
         {:ok, workspaces} <- context.workspaces,
         false <- Enum.any?(candidates ++ workspaces, &(&1["source_root"] == final)) do
      :ok
    else
      true -> {:error, :canonical_source_referenced}
      {:error, _} = error -> error
    end
  end

  defp allocation_temporaries(record) do
    with {:ok, metadata} <- temporary_metadata(record["metadata"]),
         {:ok, lease} <- temporary_metadata(record["lease"]) do
      {:ok, [record["staging"]] ++ record["auxiliary"] ++ metadata ++ lease}
    end
  end

  defp temporary_metadata(path) do
    directory = Path.dirname(path)
    prefix = Path.basename(path) <> ".staging-"

    with {:ok, names} <- cleanup_listing(directory),
         paths <-
           for(name <- names, staging_suffix?(name, prefix), do: Path.join(directory, name)),
         true <- length(paths) <= @temporary_metadata_limit do
      {:ok, paths}
    else
      false -> {:error, :cleanup_scan_limit}
      {:error, _} = error -> error
    end
  end

  defp staging_suffix?(name, prefix) do
    String.starts_with?(name, prefix) and
      Regex.match?(
        ~r/^[0-9a-f]{32}$/,
        binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix))
      )
  end

  defp cleanup_paths(paths) do
    paths |> Enum.uniq() |> Enum.map(&cleanup_path/1)
  end

  defp cleanup_path(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        cleanup_item(path, "absent", nil)

      {:error, reason} ->
        cleanup_item(path, "error", reason)

      {:ok, _} ->
        with {:ok, _} <- Source.secure_root(Path.dirname(path)),
             :ok <- Source.remove_tree(path),
             {:error, :enoent} <- File.lstat(path) do
          cleanup_item(path, "removed", nil)
        else
          {:error, reason} -> cleanup_item(path, "error", reason)
          {:ok, _} -> cleanup_item(path, "error", :cleanup_incomplete)
        end
    end
  end

  defp cleanup_item(path, status, reason) do
    %{"path" => path, "status" => status, "reason" => if(reason, do: inspect(reason), else: nil)}
  end

  defp cleanup_failed?(items), do: Enum.any?(items, &(&1["status"] in ["error", "retained"]))

  defp reconcile_allocations(settings) do
    result =
      with {:ok, limit} <- cleanup_limit(),
           {:ok, entries} <- cleanup_entries(settings) do
        cursor = cleanup_cursor(settings)

        {earlier, later} =
          Enum.split_while(Enum.sort_by(entries, &elem(&1, 0)), fn {path, _} ->
            is_binary(cursor) and path <= cursor
          end)

        selected = Enum.take(later ++ earlier, limit)
        context = cleanup_context(settings, selected)

        items =
          Enum.flat_map(selected, fn {_path, entry} ->
            reconcile_entry(settings, entry, context)
          end)

        remaining = max(length(entries) - length(selected), 0)

        cursor =
          case List.last(selected) do
            {path, _} -> path
            nil -> cursor
          end

        cleanup_receipt(settings, "reconcile", items, remaining, cursor, nil)
      else
        {:error, reason} ->
          cleanup_receipt(
            settings,
            "reconcile",
            [cleanup_item(settings.allocations, "error", reason)],
            nil,
            nil,
            nil
          )
      end

    with {:ok, receipt} <- persist_cleanup(settings, "latest.json", result) do
      if receipt["status"] == "uncertain",
        do: {:error, {:staging_cleanup_uncertain, receipt}},
        else: {:ok, receipt}
    end
  end

  defp cleanup_context(settings, selected) do
    source? =
      Enum.any?(selected, fn
        {_, {:allocation, "source", _}} -> true
        _ -> false
      end)

    workspace? =
      Enum.any?(selected, fn
        {_, {:allocation, "workspace", _}} -> true
        _ -> false
      end)

    %{
      current: if(source?, do: cleanup_current_root(settings), else: {:ok, nil}),
      candidates:
        if(source? or workspace?,
          do: protected_references(settings, "candidate"),
          else: {:ok, []}
        ),
      workspaces: if(source?, do: protected_references(settings, "workspace"), else: {:ok, []})
    }
  end

  defp cleanup_entries(settings) do
    with {:ok, names} <- cleanup_listing(settings.allocations),
         {:ok, allocations} <- allocation_entries(settings, names),
         {:ok, unknown} <- unknown_staging(settings, allocations),
         entries <- allocations ++ unknown,
         true <-
           length(entries) <=
             Application.get_env(:oh_my_jido_docs, :source_cleanup_scan_limit, 10_000) do
      {:ok, entries}
    else
      false -> {:error, :cleanup_scan_limit}
      {:error, _} = error -> error
    end
  end

  defp allocation_entries(settings, names) do
    {:ok, Enum.map(names, &allocation_entry(settings, &1))}
  end

  defp allocation_entry(settings, name) do
    path = Path.join(settings.allocations, name)

    case Regex.run(
           ~r/^(workspace|candidate|source)-([A-Za-z0-9][A-Za-z0-9_-]{0,127})\.json$/,
           name
         ) do
      [_, kind, id] -> {path, {:allocation, kind, id}}
      nil -> allocation_temporary_entry(path, name)
    end
  end

  defp allocation_temporary_entry(path, name) do
    case Regex.run(
           ~r/^(workspace|candidate|source)-([A-Za-z0-9][A-Za-z0-9_-]{0,127})\.json\.staging-[0-9a-f]{32}$/,
           name
         ) do
      [_, _, _] -> {path, {:temporary_metadata, path}}
      nil -> {path, {:unknown, path, :ownership_unknown}}
    end
  end

  defp unknown_staging(settings, allocations) do
    owned = owned_allocation_paths(settings, allocations)

    Enum.reduce_while(
      [
        {"workspace", settings.workspaces},
        {"candidate", settings.candidates},
        {"source", settings.sources}
      ],
      {:ok, []},
      &unknown_staging_root(&1, &2, settings, owned)
    )
  end

  defp owned_allocation_paths(settings, allocations) do
    MapSet.new(
      Enum.flat_map(allocations, fn
        {_path, {:allocation, kind, id}} ->
          record = allocation_record(settings, kind, id)
          [record["staging"], record["final"] | record["auxiliary"]]

        _ ->
          []
      end)
    )
  end

  defp unknown_staging_root({kind, root}, {:ok, entries}, settings, owned) do
    case cleanup_listing(root) do
      {:ok, names} ->
        unknown = Enum.flat_map(names, &unknown_staging_entry(&1, settings, kind, root, owned))
        {:cont, {:ok, entries ++ unknown}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp unknown_staging_entry(name, settings, kind, root, owned) do
    path = Path.join(root, name)
    orphan_final? = orphan_final?(settings, kind, name)

    if not MapSet.member?(owned, path) and
         (String.starts_with?(name, ".staging-") or orphan_final?),
       do: [{path, {:unknown, path, :ownership_unknown}}],
       else: []
  end

  defp orphan_final?(settings, kind, name) do
    metadata =
      case kind do
        "workspace" -> workspace_metadata_path(settings, name)
        "candidate" -> candidate_metadata_path(settings, name)
        "source" -> nil
      end

    orphan_id? =
      Regex.match?(
        ~r/^(?:[0-9a-f]{32}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/,
        name
      )

    kind != "source" and orphan_id? and absent(metadata, :present) == :ok
  end

  defp reconcile_entry(settings, {:allocation, kind, id}, context) do
    case read_allocation(settings, kind, id) do
      {:ok, record} ->
        reconcile_allocation(settings, record, context)

      {:error, reason} ->
        [cleanup_item(allocation_record(settings, kind, id)["lease"], "retained", reason)]
    end
  end

  defp reconcile_entry(_settings, {:temporary_metadata, path}, _context) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> [cleanup_path(path)]
      {:error, :enoent} -> [cleanup_item(path, "absent", nil)]
      _ -> [cleanup_item(path, "retained", :unsafe_metadata_path)]
    end
  end

  defp reconcile_entry(_settings, {:unknown, path, reason}, _context),
    do: [cleanup_item(path, "retained", reason)]

  defp reconcile_allocation(settings, record, context) do
    case reconciliation_completion(settings, record, context) do
      {:ok, true} ->
        reconcile_owned(record, false, :completed_allocation)

      {:ok, false} ->
        reconcile_incomplete_allocation(record, context)

      {:error, reason} ->
        [cleanup_item(record["lease"], "retained", reason)]
    end
  end

  defp reconcile_incomplete_allocation(record, context) do
    case allocation_unreferenced(record, context) do
      :ok ->
        reconcile_owned(record, true, nil)

      {:error, :canonical_source_referenced} ->
        reconcile_owned(record, false, :canonical_source_referenced)

      {:error, reason} ->
        [cleanup_item(record["final"], "retained", reason)]
    end
  end

  defp allocation_unreferenced(%{"kind" => "workspace"} = record, context) do
    unreferenced_base_from(context.candidates, Path.join(record["final"], "base"))
  end

  defp allocation_unreferenced(%{"kind" => "candidate"}, _context), do: :ok

  defp allocation_unreferenced(%{"kind" => "source"} = record, context) do
    source_unreferenced(context, record["final"])
  end

  defp reconciliation_completion(_settings, %{"kind" => "source", "final" => final}, context) do
    with {:ok, current} <- context.current, do: {:ok, current == final}
  end

  defp reconciliation_completion(settings, record, _context),
    do: allocation_completed(settings, record)

  defp reconcile_owned(record, delete_final?, preserved_reason) do
    case allocation_temporaries(record) do
      {:ok, temporary} ->
        items = cleanup_paths(temporary ++ if(delete_final?, do: [record["final"]], else: []))

        lease =
          if cleanup_failed?(items),
            do: [cleanup_item(record["lease"], "retained", :cleanup_incomplete)],
            else: cleanup_paths([record["lease"]])

        preserved =
          if delete_final?,
            do: [],
            else: [cleanup_item(record["final"], "preserved", preserved_reason)]

        items ++ lease ++ preserved

      {:error, reason} ->
        [cleanup_item(record["lease"], "retained", reason)]
    end
  end

  defp cleanup_listing(directory) do
    maximum = Application.get_env(:oh_my_jido_docs, :source_cleanup_scan_limit, 10_000)

    with true <- is_integer(maximum) and maximum > 0 and maximum <= 100_000,
         {:ok, _} <- Source.secure_root(directory),
         {:ok, names} <- File.ls(directory),
         true <- length(names) <= maximum do
      {:ok, Enum.sort(names)}
    else
      false -> {:error, :cleanup_scan_limit}
      {:error, _} = error -> error
    end
  end

  defp cleanup_limit do
    limit = Application.get_env(:oh_my_jido_docs, :source_cleanup_limit, 128)

    if is_integer(limit) and limit > 0 and limit <= 1024,
      do: {:ok, limit},
      else: {:error, :invalid_cleanup_limit}
  end

  defp cleanup_cursor(settings) do
    case read_json(Path.join(settings.cleanup, "latest.json")) do
      {:ok, %{"owner" => @allocation_owner, "cursor" => cursor}, _} when is_binary(cursor) ->
        cursor

      _ ->
        nil
    end
  end

  defp cleanup_receipt(settings, operation, items, remaining, cursor, id) do
    status =
      cond do
        cleanup_failed?(items) -> "uncertain"
        remaining == nil -> "uncertain"
        remaining > 0 -> "pending"
        true -> "complete"
      end

    %{
      "schema" => 1,
      "owner" => @allocation_owner,
      "data_dir" => settings.data_dir,
      "operation" => operation,
      "run_id" => id,
      "status" => status,
      "items" => items,
      "remaining" => remaining,
      "cursor" => cursor,
      "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp persist_cleanup(settings, name, receipt) do
    path = Path.join(settings.cleanup, name)
    receipt = Map.put(receipt, "receipt_path", path)

    case json_temporary(path, receipt) do
      {:ok, temporary} ->
        try do
          case File.rename(temporary, path) do
            :ok -> {:ok, receipt}
            {:error, reason} -> {:error, {:cleanup_receipt_failed, reason, receipt}}
          end
        after
          File.rm(temporary)
        end

      {:error, reason} ->
        {:error, {:cleanup_receipt_failed, reason, receipt}}
    end
  end

  defp read_json(path) do
    with {:ok, _} <- Source.secure_root(Path.dirname(path)),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @metadata_limit <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @metadata_limit,
         {:ok, value} when is_map(value) <- Jason.decode(bytes) do
      {:ok, value, bytes}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_metadata}
      {:error, _} = error -> error
      _ -> {:error, :invalid_metadata}
    end
  end

  defp pointer_token(path) do
    case read_json(path) do
      {:ok, _, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp write_metadata(path, metadata) do
    with :ok <- absent(path, :metadata_exists),
         {:ok, temporary} <- json_temporary(path, metadata) do
      try do
        File.rename(temporary, path)
      after
        File.rm(temporary)
      end
    end
  end

  defp json_temporary(path, value) do
    temporary = path <> ".staging-" <> unique()
    bytes = Jason.encode!(value)

    with true <- byte_size(bytes) <= @metadata_limit,
         {:ok, file} <-
           :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]) do
      result =
        try do
          with :ok <- :file.write(file, bytes),
               :ok <- :file.sync(file),
               :ok <- File.chmod(temporary, 0o444) do
            {:ok, temporary}
          end
        after
          :file.close(file)
        end

      if match?({:error, _}, result), do: File.rm(temporary)
      result
    else
      false -> {:error, :metadata_too_large}
      {:error, _} = error -> error
    end
  end

  defp absent(path, reason) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp valid_id(id) when is_binary(id) do
    if String.match?(id, ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/),
      do: :ok,
      else: {:error, :invalid_id}
  end

  defp valid_id(_), do: {:error, :invalid_id}

  defp workspace_metadata_path(settings, id),
    do: Path.join(settings.workspace_metadata, id <> ".json")

  defp candidate_metadata_path(settings, id),
    do: Path.join(settings.candidate_metadata, id <> ".json")

  defp unique, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
