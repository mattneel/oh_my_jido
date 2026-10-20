defmodule OhMyJidoDocs.Candidates.EffectLease do
  @moduledoc false

  alias OhMyJidoDocs.{Candidates, Workspaces}
  alias OhMyJidoDocs.Candidates.{Runner, Source}

  @schema 2
  @maximum_bytes 524_288
  @owned_process_limit 1_024
  @source_root Path.expand("../../../../..", __DIR__)
  @process_fields ~w(launch_id os_pid process_identity launcher_pid launcher_identity kill_executable started_at process_keeper owned_processes owned_processes_complete scope_observed scope_error)

  def acquire(candidate, kind) when kind in [:check, :preview, :deploy] do
    Workspaces.with_source_lock(fn ->
      with {:ok, nil} <- read(),
           :ok <- deployment_authority(candidate, kind),
           {:ok, attempt_id} <- Ecto.UUID.cast(effect_receipt(candidate, kind)["attempt_id"]) do
        lease = %{
          "schema" => @schema,
          "candidate_id" => candidate.id,
          "kind" => Atom.to_string(kind),
          "attempt_id" => attempt_id,
          "state" => "active",
          "generation" => nil,
          "process" => nil,
          "cleanup" => nil,
          "recorded_at" => now(),
          "path" => path()
        }

        persist_acquired_lease(lease)
      else
        {:ok, lease} when is_map(lease) -> occupied(lease)
        :error -> {:error, :invalid_effect_attempt}
        {:error, _} = error -> error
      end
    end)
  end

  def available do
    Workspaces.with_source_lock(fn ->
      case read() do
        {:ok, nil} -> :ok
        {:ok, lease} -> occupied(lease)
        {:error, _} = error -> error
      end
    end)
  end

  def owned(expected) do
    Workspaces.with_source_lock(fn ->
      with {:ok, %{"state" => "active"} = current} <- read(),
           true <- same?(current, expected) do
        :ok
      else
        _ -> {:error, :process_lease_not_owned}
      end
    end)
  end

  # Called by adoption while it already holds Workspaces' canonical source lock.
  # A reserved deployment excludes replacement during staging as well as launch.
  def active_source_guard do
    case read() do
      {:ok, %{"kind" => "deploy"}} -> {:error, :source_deployment_in_progress}
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def begin_launch(lease, launch) when is_map(launch) do
    update(lease, fn current ->
      with "active" <- current["state"],
           {:ok, generation} <- Ecto.UUID.cast(launch["launch_id"]) do
        {:persist,
         current
         |> Map.put("generation", generation)
         |> Map.put("process", nil)
         |> Map.put("cleanup", nil)
         |> Map.put("recorded_at", now())}
      else
        _ -> {:error, :process_launch_not_authorized}
      end
    end)
  end

  def stop_current(expected) do
    Workspaces.with_source_lock(fn ->
      with {:ok, current} when is_map(current) <- read(),
           true <- same?(current, expected) do
        {:ok, current_cleanup_receipt(current)}
      else
        _ -> {:error, :current_process_lease_unavailable}
      end
    end)
  end

  def record_process(lease, process) when is_map(process) do
    update(lease, fn current ->
      if is_binary(process["launch_id"]) and process["launch_id"] == current["generation"] do
        {:persist,
         Map.put(
           current,
           "process",
           merge_process_proof(current["process"], process_proof(process))
         )}
      else
        {:error, :process_launch_generation_mismatch}
      end
    end)
  end

  def complete(lease, receipt) when is_map(receipt) do
    update(lease, fn current ->
      attestation = latest_process_receipt(receipt)
      current? = current_attestation?(current, attestation)

      if cleanup_confirmed?(receipt) and current? do
        {:remove, merge_attested_process(current, attestation),
         attestation["cleanup"] || cleanup(receipt)}
      else
        block_current_lease(current, receipt, attestation, current?)
      end
    end)
  end

  defp block_current_lease(current, receipt, attestation, current?) do
    proof = process_proof(attestation)

    proof =
      if current? and (proof["process_identity"] || proof["launcher_identity"]),
        do: merge_process_proof(current["process"], proof),
        else: current["process"]

    cleanup =
      if current? do
        compact_cleanup(cleanup(receipt))
      else
        %{
          "status" => "uncertain",
          "reason" => "cleanup_attestation_not_current",
          "reported_cleanup_status" => cleanup(receipt)["status"],
          "observed_generation" => attestation["launch_id"],
          "current_generation" => current["generation"]
        }
      end

    {:persist,
     current
     |> Map.put("state", "blocked")
     |> Map.put("process", proof)
     |> Map.put("cleanup", cleanup)
     |> Map.put("recorded_at", now())}
  end

  # Every spawn has a durable generation first. A nil generation proves that no
  # Runner launch began; a newer generation without identity remains uncertain.
  def reconcile do
    # Match adoption's candidate -> canonical-source lock order. The second
    # source-lock acquisition re-reads the current generation before settlement.
    with {:ok, lease} when is_map(lease) <- Workspaces.with_source_lock(fn -> read() end) do
      case Candidates.with_candidate(lease["candidate_id"], &reconcile_current(lease, &1)) do
        {:error, :not_found} -> reconcile_current(lease, nil)
        result -> result
      end
    end
  end

  def path do
    root = Application.get_env(:oh_my_jido_docs, :source_root, @source_root) |> Path.expand()
    data = Application.get_env(:oh_my_jido_docs, :data_dir, Path.join(root, "var/docs_site"))
    Path.join([Path.expand(data, root), "candidate-effects", "active-process-lease.json"])
  end

  defp deployment_authority(candidate, :deploy) do
    with true <- candidate.adoption_status == "adopted",
         :ok <- Candidates.verify_effect_base(candidate, deployment: true) do
      :ok
    else
      false -> {:error, :source_adoption_required}
      {:error, _} = error -> error
    end
  end

  defp deployment_authority(_candidate, _kind), do: :ok

  defp persist_acquired_lease(lease) do
    with :ok <- persist(lease), do: {:ok, lease}
  end

  defp effect_receipt(candidate, :check), do: candidate.check_receipt
  defp effect_receipt(candidate, :preview), do: candidate.preview_receipt
  defp effect_receipt(candidate, :deploy), do: candidate.deployment_receipt

  defp occupied(%{"state" => "blocked"}), do: {:error, :global_process_cleanup_unconfirmed}
  defp occupied(_lease), do: {:error, :candidate_resource_limit}

  defp update(expected, function) do
    Workspaces.with_source_lock(fn ->
      with {:ok, current} when is_map(current) <- read(),
           true <- same?(current, expected) do
        apply_update(current, function)
      else
        {:ok, nil} -> {:error, :process_lease_missing}
        false -> {:error, :process_lease_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  defp apply_update(current, function) do
    case function.(current) do
      {:remove, attested, cleanup} -> release_current(attested, cleanup)
      {:persist, lease} -> persist(lease)
      {:error, _} = error -> error
    end
  end

  defp same?(left, right) when is_map(right) do
    Enum.all?(~w(candidate_id kind attempt_id path), &(left[&1] == right[&1]))
  end

  defp same?(_left, _right), do: false

  defp reconcile_current(expected, candidate) do
    Workspaces.with_source_lock(fn ->
      with {:ok, current} when is_map(current) <- read(),
           true <- same?(current, expected) do
        reconcile_lease(current, candidate)
      else
        {:ok, nil} -> {:ok, nil}
        false -> {:error, :process_lease_mismatch}
        {:error, _} = error -> error
      end
    end)
  end

  defp reconcile_lease(lease, candidate) do
    receipt = current_cleanup_receipt(lease)
    cleanup = receipt["cleanup"]

    if cleanup["status"] in ["confirmed", "not_started"] and current_attestation?(lease, receipt) do
      attested = merge_attested_process(lease, receipt)

      with :ok <- persist_candidate_cleanup(candidate, attested, cleanup),
           :ok <- release_current(attested, cleanup) do
        {:ok,
         attested
         |> Map.put("state", "released")
         |> Map.put("cleanup", compact_cleanup(cleanup))}
      else
        {:error, reason} ->
          {:error, {:process_lease_release_failed, reason}}
      end
    else
      blocked =
        merge_attested_process(lease, receipt)
        |> Map.put("state", "blocked")
        |> Map.put("cleanup", compact_cleanup(cleanup))
        |> Map.put("recorded_at", now())

      with :ok <- persist(blocked), do: {:error, {:global_process_cleanup_unconfirmed, blocked}}
    end
  end

  defp persist_candidate_cleanup(nil, _lease, _cleanup), do: :ok

  defp persist_candidate_cleanup(candidate, lease, cleanup) do
    field =
      case lease["kind"] do
        "check" -> :check_receipt
        "preview" -> :preview_receipt
        "deploy" -> :deployment_receipt
      end

    receipt = Map.fetch!(candidate, field)

    if receipt["attempt_id"] == lease["attempt_id"] do
      cleanup = compact_cleanup(cleanup)
      # The durable lease may be ahead of the candidate's delayed process_started
      # message. Its current generation, not an older DB process, owns cleanup.

      process =
        if is_map(lease["process"]),
          do: Map.put(lease["process"], "cleanup", cleanup),
          else: nil

      process_key = if lease["kind"] == "check", do: "active_process", else: "process"

      receipt =
        receipt
        |> Map.put("cleanup", cleanup)
        |> Map.put("launch_id", lease["generation"])
        |> Map.put(process_key, process)

      case Candidates.update(candidate, %{field => receipt}) do
        {:ok, _updated} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp current_cleanup_receipt(%{"generation" => nil, "process" => nil}) do
    %{"launch_id" => nil, "cleanup" => %{"status" => "not_started"}}
  end

  defp current_cleanup_receipt(lease) do
    process = lease["process"]

    if is_map(process) and process["launch_id"] == lease["generation"] do
      cleanup = Runner.stop(process)

      process
      |> Map.put("cleanup", cleanup)
      |> Map.merge(
        Map.take(cleanup, ~w(owned_processes owned_processes_complete scope_observed scope_error))
      )
    else
      %{
        "launch_id" => lease["generation"],
        "cleanup" => %{
          "status" => "uncertain",
          "reason" => "current_launch_identity_not_recorded"
        }
      }
    end
  end

  defp latest_process_receipt(%{"steps" => [_ | _] = steps}) do
    Enum.find(Enum.reverse(steps), List.last(steps), &is_binary(&1["launch_id"]))
  end

  defp latest_process_receipt(receipt), do: receipt

  defp current_attestation?(%{"generation" => nil, "process" => nil}, receipt) do
    get_in(receipt, ["cleanup", "status"]) == "not_started" and
      Enum.all?(
        ~w(launch_id os_pid process_identity launcher_pid launcher_identity),
        &is_nil(receipt[&1])
      )
  end

  defp current_attestation?(current, receipt) do
    process = current["process"]

    current["generation"] == receipt["launch_id"] and
      (is_nil(process) or
         Enum.all?(
           ~w(launch_id os_pid process_identity launcher_pid launcher_identity process_keeper),
           fn key ->
             process[key] == receipt[key]
           end
         ))
  end

  defp cleanup_confirmed?(receipt) do
    steps = receipt["steps"]

    if is_list(steps) and steps != [] do
      Enum.all?(steps, &cleanup_confirmed?/1)
    else
      get_in(receipt, ["cleanup", "status"]) in ["confirmed", "not_started"]
    end
  end

  defp cleanup(receipt) do
    receipt["cleanup"] ||
      (List.last(receipt["steps"] || []) || %{})["cleanup"] ||
      %{"status" => "uncertain", "reason" => "cleanup_not_recorded"}
  end

  defp process_proof(receipt), do: Map.take(receipt, @process_fields)

  defp merge_attested_process(current, attestation) do
    if current_attestation?(current, attestation) and
         (is_map(current["process"]) or is_map(attestation["process_identity"]) or
            is_map(attestation["launcher_identity"])) do
      Map.put(
        current,
        "process",
        merge_process_proof(current["process"], process_proof(attestation))
      )
    else
      current
    end
  end

  defp merge_process_proof(nil, process), do: merge_process_proof(%{}, process)

  defp merge_process_proof(previous, process) do
    keeper = process["process_identity"] || previous["process_identity"] || %{}
    owned = merge_owned_processes(previous, process, identity_stamp(keeper))
    overflow = Enum.count_until(owned, @owned_process_limit + 1) > @owned_process_limit

    process
    |> Map.put("owned_processes", Enum.take(owned, @owned_process_limit))
    |> Map.put(
      "owned_processes_complete",
      not overflow and Map.get(previous, "owned_processes_complete", true) and
        Map.get(process, "owned_processes_complete", true)
    )
    |> Map.put(
      "scope_observed",
      Map.get(previous, "scope_observed", false) or Map.get(process, "scope_observed", false)
    )
    |> Map.put(
      "scope_error",
      previous["scope_error"] || process["scope_error"] || if(overflow, do: "owned_process_limit")
    )
  end

  defp merge_owned_processes(previous, process, keeper_stamp) do
    ((previous["owned_processes"] || []) ++ (process["owned_processes"] || []))
    |> Map.new(fn identity -> {identity_stamp(identity), identity} end)
    |> Map.values()
    |> Enum.sort_by(fn identity ->
      key = identity_stamp(identity)
      {if(key == keeper_stamp, do: 0, else: 1), key}
    end)
  end

  defp identity_stamp(identity),
    do: {identity["pid"], identity["start_time"], identity["boot_id"]}

  defp compact_cleanup(cleanup) do
    remaining = cleanup["remaining"] || []
    remaining_count = length(remaining)

    cleanup
    |> Map.take(
      ~w(status identity_verified term kill reason launcher scope reported_cleanup_status observed_generation current_generation owned_processes_complete scope_observed scope_error authority subreaper all_children_reaped)
    )
    |> Map.put("remaining", Enum.take(remaining, 128))
    |> Map.put("remaining_count", remaining_count)
    |> Map.put("remaining_truncated", remaining_count > 128)
  end

  defp read do
    directory = Path.dirname(path())

    with :ok <- secure_optional_directory(directory),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @maximum_bytes <-
           File.lstat(path()),
         {:ok, bytes} <- bounded_read(path()),
         {:ok, lease} <- Jason.decode(bytes),
         true <- valid?(lease) do
      {:ok, lease}
    else
      {:error, :enoent} -> {:ok, nil}
      _ -> {:error, :global_process_lease_unavailable}
    end
  end

  defp valid?(lease) when is_map(lease) do
    lease["schema"] == @schema and lease["kind"] in ["check", "preview", "deploy"] and
      lease["state"] in ["active", "blocked"] and lease["path"] == path() and
      match?({:ok, _}, Ecto.UUID.cast(lease["candidate_id"])) and
      match?({:ok, _}, Ecto.UUID.cast(lease["attempt_id"])) and
      valid_generation?(lease) and
      (is_nil(lease["process"]) or is_map(lease["process"]))
  end

  defp valid?(_lease), do: false

  defp valid_generation?(lease) do
    Map.has_key?(lease, "generation") and
      (is_nil(lease["generation"]) or match?({:ok, _}, Ecto.UUID.cast(lease["generation"])))
  end

  defp bounded_read(file) do
    case File.open(file, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @maximum_bytes + 1) do
            bytes when is_binary(bytes) and byte_size(bytes) <= @maximum_bytes -> {:ok, bytes}
            _ -> {:error, :process_lease_too_large}
          end
        after
          File.close(io)
        end

      {:error, _} = error ->
        error
    end
  end

  defp secure_optional_directory(directory) do
    case File.lstat(directory) do
      {:error, :enoent} -> Source.secure_root(Path.dirname(directory)) |> root_result()
      {:ok, %File.Stat{type: :directory}} -> Source.secure_root(directory) |> root_result()
      _ -> {:error, :unsafe_process_lease_directory}
    end
  end

  defp root_result({:ok, _}), do: :ok
  defp root_result({:error, _} = error), do: error

  defp release_current(lease, cleanup) do
    receipt_path = Path.join(Path.dirname(path()), "process-lease-receipt.json")

    receipt =
      lease
      |> Map.put("state", "released")
      |> Map.put("cleanup", compact_cleanup(cleanup))
      |> Map.put("released_at", now())
      |> Map.put("receipt_path", receipt_path)

    with :ok <- persist(receipt, receipt_path),
         :ok <- File.rm(path()) do
      Runner.sync_receipt_directory(Path.dirname(path()))
    end
  end

  defp persist(lease, destination \\ path()) do
    directory = Path.dirname(destination)
    temporary = destination <> ".staging"
    bytes = Jason.encode!(lease)

    with true <- byte_size(bytes) <= @maximum_bytes,
         :ok <- secure_optional_directory(directory),
         :ok <- File.mkdir_p(directory),
         {:ok, _} <- Source.secure_root(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- Runner.sync_receipt_directory(Path.dirname(directory)),
         :ok <- remove_staging(temporary),
         {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(io, bytes),
             :ok <- :file.sync(io),
             :ok <- File.rename(temporary, destination) do
          Runner.sync_receipt_directory(directory)
        end
      after
        File.close(io)
        File.rm(temporary)
      end
    else
      false -> {:error, :process_lease_too_large}
      {:error, _} = error -> error
    end
  end

  defp remove_staging(file) do
    case File.lstat(file) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> File.rm(file)
      _ -> {:error, :unsafe_process_lease_staging}
    end
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
