defmodule OhMyJidoDocs.Editor.Writers do
  @moduledoc false

  import Ecto.Query

  alias OhMyJido.{Runtime, SessionRef, Workspace}
  alias OhMyJidoDocs.Editor.{Run, Store, WriterLease}
  alias OhMyJidoDocs.Repo

  @runtime OhMyJidoDocs.Coding
  @uncertain_summary "Native source writer settlement is unconfirmed; source promotion remains blocked."

  def source_write_settled(workspace) do
    with {:ok, canonical} <- Workspace.new(workspace) do
      paths = Enum.uniq([canonical, Path.expand(workspace)])
      active = Store.active_statuses()

      # A cleared map is JSON null in SQLite, not necessarily SQL NULL.
      blocked? =
        Repo.exists?(
          from r in Run,
            where:
              r.workspace in ^paths and
                (r.source_writer_pending or not is_nil(r.source_writer_token) or
                   fragment("json_type(?) != 'null'", r.source_writer_origin) or
                   r.status in ^active)
        )

      if blocked?, do: {:error, :workspace_busy}, else: :ok
    end
  rescue
    _error -> {:error, :writer_state_unavailable}
  catch
    :exit, _reason -> {:error, :writer_state_unavailable}
  end

  def acquire(run) do
    cond do
      not is_nil(run.source_writer_origin) -> recover_and_acquire(run)
      run.source_writer_pending or not is_nil(run.source_writer_token) -> acquire_existing(run)
      true -> claim_new_writer(run)
    end
  end

  def recover(run) do
    case claim_source(run) do
      {:ok, :operator} -> recover_operator(run)
      {:ok, :native} -> recover_native(run)
      {:error, reason} -> {:error, reason, run}
    end
  end

  def bind(run, lease, native_pid) do
    case verify_native(run, native_pid) do
      :ok -> WriterLease.bind(lease, native_pid)
      {:error, _reason} = error -> error
    end
  end

  def stop(run, lease, native_pid) do
    with {:ok, current} <- current_claim(run),
         true <- live_pid(ref(current)) == native_pid,
         {:ok, source} <- claim_source(current) do
      stop_current(current, lease, native_pid, source)
    else
      false -> {:error, :native_identity_changed, run}
      {:error, reason} -> {:error, reason, run}
    end
  end

  def settle_down(run, lease) do
    with {:ok, current} <- current_claim(run),
         {:ok, source} <- claim_source(current) do
      settle_current_down(current, lease, source)
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  def abandon_unbound(run, lease, reason) do
    case claim_source(run) do
      {:ok, :operator} -> recover_operator(run)
      {:ok, :native} -> abandon_native_unbound(run, lease, reason)
      {:error, error} -> {:error, error, run}
    end
  end

  def acknowledge_absence(run) do
    with {:ok, _config} <- Runtime.config(@runtime),
         {:ok, current} <- current_claim(run),
         {:ok, lease} <- recovery_lease(current),
         {:ok, marked} <- acknowledge_operator_claim(current, lease) do
      finish_operator(marked, lease)
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  def uncertain(run, reason) do
    updates = %{source_writer_pending: true}

    if run.status in Store.active_statuses() do
      updates =
        Map.merge(updates, %{
          status: "interrupted",
          summary: @uncertain_summary,
          pending_questions: %{},
          session_snapshot: nil
        })

      Store.append(
        run.id,
        "source_writer_unsettled",
        %{reason: reason, native_stop_confirmed: false},
        updates
      )
    else
      Store.refresh(run, updates)
    end
  end

  def ref(run), do: %SessionRef{runtime: @runtime, id: run.session_id}

  def live_pid(session) do
    GenServer.whereis(Runtime.via(session))
  rescue
    ArgumentError -> nil
  end

  defp recover_and_acquire(run) do
    case recover(run) do
      {:ok, current} -> acquire(current)
      {:error, _reason, _run} = error -> error
    end
  end

  defp recover_native(run) do
    run = ensure_claim(run)

    case recovery_lease(run) do
      {:ok, lease} -> recover_with(run, lease)
      {:error, reason} -> {:error, reason, uncertain(run, reason)}
    end
  end

  defp recover_operator(run) do
    with {:ok, current} <- current_claim(run),
         {:ok, lease} <- recovery_lease(current) do
      finish_operator(current, lease)
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp stop_current(run, _lease, _pid, :operator), do: recover_operator(run)

  defp stop_current(run, lease, pid, :native) do
    case stop_native(run, lease, pid) do
      :ok -> settle(run, lease, %{native_stop_confirmed: true})
      {:error, reason} -> {:error, reason, uncertain(run, reason)}
    end
  end

  defp settle_current_down(run, _lease, :operator), do: recover_operator(run)

  defp settle_current_down(run, lease, :native) do
    with {:ok, info} <- WriterLease.info(lease),
         true <- stopped_owner_confirmed?(info),
         true <- is_nil(live_pid(ref(run))),
         :ok <- WriterLease.confirm_stopped(lease, info.native_pid) do
      settle(run, lease, %{native_stop_confirmed: true})
    else
      false -> {:error, :native_stop_unconfirmed, uncertain(run, :native_stop_unconfirmed)}
      {:error, reason} -> {:error, reason, uncertain(run, reason)}
    end
  end

  defp abandon_native_unbound(run, lease, reason) do
    with {:ok, info} <- WriterLease.info(lease),
         true <- is_nil(info.native_pid) and not info.native_attempted and info.origin == :new,
         true <- is_nil(live_pid(ref(run))) do
      settle(run, lease, %{native_started: false, reason: reason})
    else
      _unconfirmed -> {:error, :native_stop_unconfirmed, uncertain(run, reason)}
    end
  end

  # An operator absence acknowledgement can permit recovery, but is not an
  # actual native strong-stop acknowledgement for the old owner.
  defp stopped_owner_confirmed?(info) do
    info.native_down and info.settled and info.stop_acknowledged and
      is_pid(info.native_pid) and not Process.alive?(info.native_pid)
  end

  defp acquire_existing(run) do
    case WriterLease.lookup(run) do
      {:ok, lease} -> acquire_held_writer(run, lease)
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp acquire_held_writer(run, lease) do
    cond do
      lease.phase != :held -> {:error, :workspace_busy, run}
      lease.native_down and lease.settled -> settle_and_acquire(run, lease)
      unconfirmed_native?(lease) -> {:error, :native_stop_unconfirmed, run}
      true -> {:ok, run, lease}
    end
  end

  defp unconfirmed_native?(lease) do
    dead_native? = is_pid(lease.native_pid) and not Process.alive?(lease.native_pid)

    (not lease.settled and (lease.native_down or dead_native?)) or
      (is_nil(lease.native_pid) and (lease.native_attempted or lease.origin == :recovery))
  end

  defp settle_and_acquire(run, lease) do
    case settle_down(run, lease) do
      {:ok, current} -> acquire(current)
      {:error, _reason, _run} = error -> error
    end
  end

  defp claim_new_writer(run) do
    run =
      Store.append(run.id, "source_writer_claimed", %{settled: false}, %{
        source_writer_pending: true,
        source_writer_token: Ecto.UUID.generate(),
        source_writer_origin: nil
      })

    case WriterLease.start(run, :new) do
      {:ok, lease} -> {:ok, run, lease}
      {:error, :writer_lease_unconfirmed = reason} -> {:error, reason, uncertain(run, reason)}
      {:error, reason} -> writer_not_started(run, reason)
    end
  end

  defp writer_not_started(run, reason) do
    run =
      Store.append(
        run.id,
        "source_writer_not_started",
        %{reason: reason, native_started: false},
        %{source_writer_pending: false, source_writer_token: nil}
      )

    {:error, reason, run}
  end

  defp stop_native(run, lease, native_pid) do
    session = ref(run)

    with :ok <- verify_native(run, native_pid),
         :ok <- WriterLease.bind(lease, native_pid),
         true <- live_pid(session) == native_pid,
         :ok <- OhMyJido.stop_session(session),
         true <- not Process.alive?(native_pid) and is_nil(live_pid(session)) do
      WriterLease.confirm_stopped(lease, native_pid)
    else
      false -> {:error, :native_identity_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recovery_lease(run) do
    case WriterLease.lookup(run) do
      {:ok, lease} -> {:ok, lease}
      {:error, :writer_missing} -> WriterLease.start(run, :recovery)
      {:error, _reason} = error -> error
    end
  end

  defp current_claim(run) do
    with {:ok, current} <- Store.get(run.id),
         true <- same_claim?(current, run) do
      {:ok, current}
    else
      false -> {:error, :writer_claim_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp same_claim?(current, run) do
    current.source_writer_pending and current.source_writer_token == run.source_writer_token and
      current.session_id == run.session_id and current.workspace == run.workspace
  end

  defp claim_source(%{source_writer_origin: nil}), do: {:ok, :native}

  defp claim_source(run) do
    if matching_operator_origin?(run, run.source_writer_origin),
      do: {:ok, :operator},
      else: {:error, :writer_origin_mismatch}
  end

  defp matching_operator_origin?(
         run,
         %{
           "source" => "operator",
           "claim_digest" => digest,
           "session_id" => session_id,
           "workspace" => workspace,
           "native_run_id" => native_id
         }
       ) do
    is_binary(run.source_writer_token) and session_id == run.session_id and
      workspace == run.workspace and digest == claim_digest(run.source_writer_token) and
      (is_nil(native_id) or is_binary(native_id))
  end

  defp matching_operator_origin?(_run, _origin), do: false

  defp claim_digest(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp acknowledge_operator_claim(run, lease) do
    case claim_source(run) do
      {:ok, :operator} -> {:ok, run}
      {:ok, :native} -> begin_operator_claim(run, lease)
      {:error, _reason} = error -> error
    end
  end

  defp begin_operator_claim(run, lease) do
    with {:ok, %{native_pid: native_pid}} <- WriterLease.info(lease),
         true <- is_nil(native_pid) or not Process.alive?(native_pid) do
      persist_operator_claim(run)
    else
      false -> {:error, :native_session_active}
      {:error, _reason} = error -> error
    end
  end

  defp persist_operator_claim(run) do
    if is_nil(live_pid(ref(run))) do
      origin = %{
        "source" => "operator",
        "claim_digest" => claim_digest(run.source_writer_token),
        "session_id" => run.session_id,
        "workspace" => run.workspace,
        "native_run_id" => nil
      }

      Store.update_writer(
        run,
        "source_writer_operator_acknowledged",
        %{operator_acknowledged: true, native_stop_confirmed: false},
        %{source_writer_origin: origin}
      )
    else
      {:error, :native_session_active}
    end
  end

  defp finish_operator(run, lease) do
    with {:ok, :operator} <- claim_source(run),
         {:ok, current, session, pid} <- restore_reconciled_owner(run, lease),
         :ok <- OhMyJido.checkpoint(session),
         :ok <- stop_native(current, lease, pid) do
      settle(current, lease, %{native_stop_confirmed: true})
    else
      {:ok, :native} -> {:error, :writer_origin_mismatch, run}
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp restore_reconciled_owner(run, lease) do
    with {:ok, session, pid} <- operator_session(run),
         {:ok, info} <- OhMyJido.inspect_session(session),
         :ok <- verify_operator_snapshot(run, info),
         {:ok, native_id, ids} <- interrupted_native_identity(run, info),
         {:ok, current} <- persist_native_identity(run, native_id),
         :ok <- prepare_operator_binding(lease, pid),
         :ok <- bind(current, lease, pid),
         :ok <- reconcile_restored_effects(current, session, ids) do
      {:ok, current, session, pid}
    end
  end

  defp operator_session(run) do
    case live_pid(ref(run)) do
      pid when is_pid(pid) -> {:ok, ref(run), pid}
      nil -> start_operator_session(run)
    end
  end

  defp start_operator_session(run) do
    with {:ok, session} <- OhMyJido.resume_session(@runtime, run.session_id),
         pid when is_pid(pid) <- live_pid(session) do
      {:ok, session, pid}
    else
      nil -> {:error, :native_identity_changed}
      {:error, _reason} = error -> error
    end
  end

  defp verify_operator_snapshot(run, info) do
    with {:ok, canonical} <- Workspace.new(run.workspace),
         true <- info.id == run.session_id and info.workspace == canonical,
         true <- is_nil(info.active_run) do
      :ok
    else
      _mismatch -> {:error, :native_identity_mismatch}
    end
  end

  defp prepare_operator_binding(lease, pid) do
    case WriterLease.info(lease) do
      {:ok, %{native_pid: ^pid}} -> :ok
      {:ok, _old_owner} -> WriterLease.acknowledge_absence(lease)
      {:error, _reason} = error -> error
    end
  end

  defp persist_native_identity(run, native_id) do
    origin = Map.put(run.source_writer_origin, "native_run_id", native_id)

    if run.native_run_id == native_id and origin == run.source_writer_origin do
      {:ok, run}
    else
      Store.update_writer(
        run,
        "source_writer_native_identity_recovered",
        %{native_run_id: native_id, replay: false},
        %{native_run_id: native_id, source_writer_origin: origin}
      )
    end
  end

  defp interrupted_native_identity(run, info) do
    with {:ok, pending} <- pending_native_effects(info) do
      select_native_identity(run, info.runs, pending)
    end
  end

  defp pending_native_effects(info) do
    Enum.reduce_while(info.effects, {:ok, %{}}, &group_native_effect(&1, &2, info.runs))
  end

  defp group_native_effect({id, effect}, {:ok, groups}, runs) do
    case native_effect_identity(id, effect, runs) do
      :settled ->
        {:cont, {:ok, groups}}

      {:pending, native_id} ->
        {:cont, {:ok, Map.update(groups, native_id, [id], &[id | &1])}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp native_effect_identity(id, effect, runs) do
    if execution_pending?(effect),
      do: pending_effect_run(id, effect, runs),
      else: :settled
  end

  defp pending_effect_run(id, %{id: id, run: native_id, status: status}, runs)
       when is_binary(id) and is_binary(native_id) and status in [:running, :uncertain] do
    case Map.get(runs, native_id) do
      %{id: ^native_id, status: :interrupted} -> {:pending, native_id}
      _unmatched -> {:error, :native_run_identity_mismatch}
    end
  end

  defp pending_effect_run(_id, _effect, _runs),
    do: {:error, :native_run_identity_mismatch}

  defp execution_pending?(%{
         status: :uncertain,
         execution_settlement: %{
           source: :operator,
           execution: :stopped,
           effect: :uncertain,
           native_stop_confirmed: false
         }
       }),
       do: false

  defp execution_pending?(%{status: status} = effect) when status in [:running, :uncertain],
    do: not Map.has_key?(effect, :completed_at)

  defp execution_pending?(%{status: status}) when status in [:completed, :failed], do: false
  defp execution_pending?(_malformed), do: true

  defp select_native_identity(run, runs, pending) do
    case run.source_writer_origin["native_run_id"] do
      nil -> discover_native_identity(run, runs, pending)
      native_id -> validate_native_identity(native_id, runs, pending)
    end
  end

  defp discover_native_identity(run, runs, pending) do
    case Map.keys(pending) do
      [native_id] -> validate_native_identity(native_id, runs, pending)
      [] -> latest_native_identity(run, runs)
      _ambiguous -> {:error, :native_run_identity_ambiguous}
    end
  end

  defp validate_native_identity(native_id, runs, pending) do
    with %{id: ^native_id, status: status} <- Map.get(runs, native_id),
         true <- status in [:completed, :failed, :cancelled, :suspended, :interrupted, :timed_out],
         true <- Enum.all?(Map.keys(pending), &(&1 == native_id)) do
      {:ok, native_id, Map.get(pending, native_id, [])}
    else
      _unmatched -> {:error, :native_run_identity_mismatch}
    end
  end

  defp latest_native_identity(run, runs) when map_size(runs) == 0 do
    if is_nil(run.native_run_id),
      do: {:ok, nil, []},
      else: {:error, :native_run_identity_mismatch}
  end

  defp latest_native_identity(_run, runs) do
    ordered = Enum.sort_by(runs, fn {_id, record} -> Map.get(record, :started_at) end, :desc)
    select_latest_native(ordered, runs)
  end

  defp select_latest_native([{native_id, %{started_at: started}} | rest], runs)
       when is_binary(native_id) and is_integer(started) do
    if Enum.any?(rest, fn {_id, record} -> Map.get(record, :started_at) == started end),
      do: {:error, :native_run_identity_ambiguous},
      else: validate_native_identity(native_id, runs, %{})
  end

  defp select_latest_native(_malformed, _runs), do: {:error, :native_run_identity_mismatch}

  defp reconcile_restored_effects(_run, _session, []), do: :ok

  defp reconcile_restored_effects(run, session, ids) do
    OhMyJido.reconcile_interrupted(
      session,
      run.native_run_id,
      ids,
      :orphan_resources_reconciled
    )
  end

  defp recover_with(run, lease) do
    case live_pid(ref(run)) do
      pid when is_pid(pid) ->
        run = interrupt(run)
        stop(run, lease, pid)

      nil ->
        case WriterLease.info(lease) do
          {:ok, info} -> recover_absent_native(run, lease, info)
          {:error, reason} -> {:error, reason, uncertain(run, reason)}
        end
    end
  end

  defp recover_absent_native(run, lease, info) do
    cond do
      info.native_down and info.settled ->
        settle_down(interrupt(run), lease)

      is_nil(info.native_pid) and not info.native_attempted and info.origin == :new ->
        abandon_unbound(interrupt(run), lease, :observer_restarted_before_native_start)

      true ->
        {:error, :source_writer_unsettled, uncertain(run, :native_identity_unavailable)}
    end
  end

  defp ensure_claim(run) do
    if run.source_writer_pending and is_binary(run.source_writer_token) do
      run
    else
      Store.append(run.id, "source_writer_reconciliation", %{native_stop_confirmed: false}, %{
        source_writer_pending: true,
        source_writer_token: run.source_writer_token || Ecto.UUID.generate()
      })
    end
  end

  defp interrupt(run) do
    if run.status in Store.active_statuses(),
      do:
        Store.append(run.id, "writer_interrupted", %{replay: false}, %{
          status: "interrupted",
          pending_questions: %{}
        }),
      else: run
  end

  defp settle(run, lease, evidence) do
    with {:ok, evidence} <- settlement_evidence(run, evidence),
         :ok <- WriterLease.release(lease),
         {:ok, current} <-
           Store.update_writer(run, "source_writer_settled", evidence, settlement_updates(run)) do
      {:ok, current}
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp settlement_evidence(run, evidence) do
    case claim_source(run) do
      {:ok, :native} -> {:ok, evidence}
      {:ok, :operator} -> operator_stop_evidence(evidence)
      {:error, _reason} = error -> error
    end
  end

  defp operator_stop_evidence(%{native_stop_confirmed: true} = evidence) do
    {:ok,
     Map.merge(evidence, %{
       operator_reconciled: true,
       native_stop_confirmed: false,
       restored_owner_stop_confirmed: true
     })}
  end

  defp operator_stop_evidence(_unconfirmed), do: {:error, :native_stop_unconfirmed}

  defp settlement_updates(run) do
    updates = %{
      source_writer_pending: false,
      source_writer_token: nil,
      source_writer_origin: nil
    }

    updates =
      if is_map(run.source_writer_origin) do
        status = if run.status in Store.active_statuses(), do: "interrupted", else: run.status
        Map.merge(updates, %{status: status, pending_questions: %{}})
      else
        updates
      end

    if run.summary == @uncertain_summary,
      do:
        Map.put(
          updates,
          :summary,
          "Native execution was interrupted; its source writer is now settled without replay."
        ),
      else: updates
  end

  defp verify_native(run, native_pid) do
    with true <- is_pid(native_pid) and live_pid(ref(run)) == native_pid,
         {:ok, info} <- OhMyJido.inspect_session(ref(run)),
         {:ok, canonical} <- Workspace.new(run.workspace),
         true <- info.id == run.session_id and info.workspace == canonical,
         true <-
           is_nil(info.active_run) or is_nil(run.native_run_id) or
             info.active_run == run.native_run_id do
      :ok
    else
      _invalid -> {:error, :native_identity_mismatch}
    end
  end
end
