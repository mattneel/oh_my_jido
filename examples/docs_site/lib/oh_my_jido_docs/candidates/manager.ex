defmodule OhMyJidoDocs.Candidates.Manager do
  @moduledoc false

  use GenServer
  import Ecto.Query
  require Logger

  alias OhMyJidoDocs.{Candidates, Content, Repo, Workspaces}
  alias OhMyJidoDocs.Candidates.{Candidate, Deployment, EffectLease, Execution, Runner}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case Workspaces.reconcile_staging() do
      {:ok, _receipt} -> {:ok, %{tasks: %{}, keys: %{}}, {:continue, :reconcile}}
      {:error, reason} -> {:stop, {:workspace_recovery_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile()
    {:noreply, state}
  end

  @impl true
  def handle_call({:start, kind, id}, _from, state) when kind in [:check, :preview] do
    start_effect(kind, id, nil, state)
  end

  def handle_call({:deploy, id, digest}, _from, state) do
    start_effect(:deploy, id, digest, state)
  end

  def handle_call(:reconcile_process_cleanup, _from, state) do
    result =
      if map_size(state.tasks) == 0 do
        with :ok <- terminate_orphan_tasks(), do: EffectLease.reconcile()
      else
        {:error, :candidate_resource_limit}
      end

    {:reply, result, state}
  end

  def handle_call({:preview_target, id, opts}, _from, state) do
    result =
      with {:ok, ref} <- Map.fetch(state.keys, {:preview, id}),
           {:ok, %{kind: :preview, ready: true, stop_requested: false} = entry} <-
             Map.fetch(state.tasks, ref),
           true <- Process.alive?(entry.task.pid) do
        Candidates.with_candidate(id, &owned_preview_target(&1, entry, opts))
      else
        _ -> {:error, :preview_unavailable}
      end

    {:reply, result, state}
  end

  def handle_call({:stop, kind, id}, _from, state) do
    case Map.fetch(state.keys, {kind, id}) do
      {:ok, ref} ->
        entry = state.tasks[ref]
        send(entry.task.pid, {:cancel, entry.cancel_ref})
        entry = Map.put(entry, :stop_requested, true)
        attrs = stopping_attrs(kind)
        result = Candidates.with_candidate(id, &Candidates.update(&1, attrs))
        {:reply, result, put_in(state.tasks[ref], entry)}

      :error ->
        {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_info({:process_started, kind, id, attempt_id, process}, state) do
    with {:ok, ref} <- Map.fetch(state.keys, {kind, id}),
         %{attempt_id: ^attempt_id} = current <- state.tasks[ref] do
      entry = Map.put(current, :process, process)

      result =
        if process["lease_persistence_failed"],
          do: {:error, :process_lease_unavailable},
          else: persist_process(kind, id, process, entry)

      case result do
        {:ok, _candidate} ->
          schedule_preview_readiness(kind, ref)
          {:noreply, put_in(state.tasks[ref], entry)}

        {:error, _reason} ->
          send(entry.task.pid, {:cancel, entry.cancel_ref})
          Runner.stop(process)
          {:noreply, put_in(state.tasks[ref], %{entry | stop_requested: true})}
      end
    else
      _ ->
        Runner.stop(process)
        {:noreply, state}
    end
  end

  def handle_info({:process_scope, kind, id, attempt_id, process}, state) do
    with {:ok, ref} <- Map.fetch(state.keys, {kind, id}),
         %{attempt_id: ^attempt_id, process: previous} = current <- state.tasks[ref],
         true <- is_map(previous) and previous["launch_id"] == process["launch_id"] do
      entry = %{current | process: process}

      case persist_process(kind, id, process, entry) do
        {:ok, _candidate} ->
          {:noreply, put_in(state.tasks[ref], entry)}

        {:error, _reason} ->
          send(entry.task.pid, {:cancel, entry.cancel_ref})
          Runner.stop(process)
          {:noreply, put_in(state.tasks[ref], %{entry | stop_requested: true})}
      end
    else
      _ ->
        Runner.stop(process)
        {:noreply, state}
    end
  end

  def handle_info({:preview_ready, ref}, state) do
    case Map.fetch(state.tasks, ref) do
      {:ok, %{kind: :preview, ready: false, stop_requested: false} = entry} ->
        cond do
          System.monotonic_time(:millisecond) >= entry.ready_deadline ->
            send(entry.task.pid, {:cancel, entry.cancel_ref})
            entry = %{entry | readiness_failed: true, stop_requested: true}

            Candidates.with_candidate(
              entry.id,
              &Candidates.update(&1, %{preview_status: "timed_out", preview_url: nil})
            )

            {:noreply, put_in(state.tasks[ref], entry)}

          Runner.listener_owned?(entry.process, entry.spec.port) and
            Execution.ready?(entry.spec.port) and
              Runner.listener_owned?(entry.process, entry.spec.port) ->
            Candidates.with_candidate(entry.id, &persist_ready_preview(&1, entry.spec))

            {:noreply, put_in(state.tasks[ref], %{entry | ready: true})}

          true ->
            Process.send_after(self(), {:preview_ready, ref}, 200)
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.tasks, ref) do
      {:ok, entry} ->
        Process.demonitor(ref, [:flush])
        finish(entry, result)
        settle_lease(entry, result)
        {:noreply, forget(state, ref, entry)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.tasks, ref) do
      {:ok, entry} ->
        current =
          case EffectLease.stop_current(entry.lease) do
            {:ok, receipt} ->
              receipt

            {:error, _} ->
              %{
                "cleanup" => %{
                  "status" => "uncertain",
                  "reason" => "current_process_lease_unavailable"
                }
              }
          end

        receipt =
          Map.merge(current, %{
            "status" => "failed",
            "reason" => "supervised_task_exited",
            "output" => "The supervised effect task exited before returning a complete receipt.",
            "remote_effect" =>
              if(entry.kind == :deploy,
                do:
                  if(get_in(current, ["cleanup", "status"]) == "not_started",
                    do: "not_started",
                    else: "unknown"
                  ),
                else: "not_applicable"
              )
          })

        finish(entry, receipt)
        settle_lease(entry, receipt)

        {:noreply, forget(state, ref, entry)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, entry} ->
      send(entry.task.pid, {:cancel, entry.cancel_ref})
      if entry.process, do: Runner.stop(entry.process)
      Task.shutdown(entry.task, :brutal_kill)
    end)

    :ok
  end

  defp start_effect(kind, id, digest, state) do
    with :ok <- capacity(kind, id, state),
         true <- is_pid(Process.whereis(OhMyJidoDocs.CandidateTasks)),
         {:ok, {candidate, spec}} <- prepare_effect(kind, id, digest) do
      owner = self()
      cancel_ref = make_ref()
      attempt_id = effect_attempt_id(candidate, kind)

      entry = %{
        id: id,
        kind: kind,
        digest: candidate.digest,
        task: nil,
        cancel_ref: cancel_ref,
        process: nil,
        lease: nil,
        attempt_id: attempt_id,
        spec: spec,
        attempt: attempt(candidate, kind),
        preview_attempt: candidate.preview_receipt["attempt_id"],
        ready: false,
        readiness_failed: false,
        ready_deadline:
          System.monotonic_time(:millisecond) +
            setting(:candidate_preview_ready_timeout_ms, 30_000),
        stop_requested: false
      }

      acquire_effect_lease(candidate, entry, owner, state)
    else
      false -> {:reply, {:error, :task_supervisor_unavailable}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp schedule_preview_readiness(kind, ref) do
    if kind == :preview, do: Process.send_after(self(), {:preview_ready, ref}, 50)
  end

  defp persist_ready_preview(candidate, spec) do
    Candidates.update(candidate, %{
      preview_status: "running",
      preview_url: spec.url,
      preview_receipt:
        Map.merge(candidate.preview_receipt, %{
          "ready_at" => now(),
          "url" => spec.url,
          "digest" => candidate.digest
        })
    })
  end

  defp acquire_effect_lease(candidate, entry, owner, state) do
    case EffectLease.acquire(candidate, entry.kind) do
      {:ok, lease} ->
        start_leased_effect(candidate, %{entry | lease: lease}, owner, state)

      {:error, reason} = error ->
        finish(entry, %{
          "status" => "unavailable",
          "reason" => inspect(reason),
          "output" => "No effect process was started: #{inspect(reason)}",
          "remote_effect" => "not_started",
          "cleanup" => %{"status" => "not_started"}
        })

        {:reply, error, state}
    end
  end

  defp start_leased_effect(candidate, entry, owner, state) do
    callbacks = effect_callbacks(entry, owner)

    case supervised_task(fn ->
           run_effect(
             entry.kind,
             candidate,
             entry.spec,
             owner,
             entry.cancel_ref,
             callbacks,
             entry.lease
           )
         end) do
      {:ok, task} ->
        entry = %{entry | task: task}

        state = %{
          state
          | tasks: Map.put(state.tasks, task.ref, entry),
            keys: Map.put(state.keys, {entry.kind, entry.id}, task.ref)
        }

        {:reply, {:ok, candidate}, state}

      {:error, reason} = error ->
        uncertain = reason == :task_start_uncertain

        receipt = %{
          "status" => if(uncertain, do: "uncertain", else: "unavailable"),
          "reason" => Atom.to_string(reason),
          "output" => "No supervised effect task was confirmed: #{reason}.",
          "remote_effect" => if(uncertain, do: "unknown", else: "not_started"),
          "cleanup" => %{
            "status" => if(uncertain, do: "unconfirmed_no_child_recorded", else: "not_started")
          }
        }

        finish(entry, receipt)
        settle_lease(entry, receipt)
        {:reply, error, state}
    end
  end

  defp effect_callbacks(entry, owner) do
    %{
      before_start: &EffectLease.begin_launch(entry.lease, &1),
      on_start: &record_started_process(entry, owner, &1),
      on_scope: &record_process_scope(entry, owner, &1)
    }
  end

  defp record_started_process(entry, owner, process) do
    case EffectLease.record_process(entry.lease, process) do
      :ok ->
        send(owner, {:process_started, entry.kind, entry.id, entry.attempt_id, process})
        :ok

      {:error, reason} ->
        send(
          owner,
          {:process_started, entry.kind, entry.id, entry.attempt_id,
           Map.put(process, "lease_persistence_failed", true)}
        )

        {:error, reason}
    end
  end

  defp record_process_scope(entry, owner, process) do
    with :ok <- EffectLease.record_process(entry.lease, process) do
      send(owner, {:process_scope, entry.kind, entry.id, entry.attempt_id, process})
      :ok
    end
  end

  defp supervised_task(function) do
    {:ok, Task.Supervisor.async_nolink(OhMyJidoDocs.CandidateTasks, function)}
  rescue
    RuntimeError -> {:error, :candidate_resource_limit}
  catch
    :exit, {:timeout, _call} -> {:error, :task_start_uncertain}
    :exit, _reason -> {:error, :task_supervisor_unavailable}
  end

  defp prepare_effect(:check, id, _digest) do
    Candidates.with_candidate(id, fn candidate ->
      next_attempt = (candidate.check_receipt["attempt"] || 0) + 1
      attempt_id = Ecto.UUID.generate()

      with :ok <- Candidates.effect_available(candidate),
           :ok <- previous_cleanup(candidate.check_receipt),
           :ok <- Candidates.reviewed_source(candidate, candidate.digest),
           :ok <- Execution.check_available(),
           true <- next_attempt <= setting(:candidate_check_attempt_limit, 5),
           {:ok, candidate} <-
             Candidates.update(candidate, %{
               status: "checking",
               check_status: "running",
               check_digest: nil,
               check_output: "",
               approval_digest: nil,
               approved_at: nil,
               check_receipt: %{
                 "status" => "running",
                 "digest" => candidate.digest,
                 "attempt" => next_attempt,
                 "attempt_id" => attempt_id,
                 "execution_root" => Execution.execution_root(candidate, "check", attempt_id),
                 "started_at" => now()
               }
             }) do
        {:ok, {candidate, nil}}
      else
        false -> {:error, :check_attempt_limit}
        {:error, _} = error -> error
      end
    end)
  end

  defp prepare_effect(:preview, id, _digest) do
    Candidates.with_candidate(id, fn candidate ->
      with :ok <- Candidates.effect_available(candidate),
           :ok <- previous_cleanup(candidate.preview_receipt),
           :ok <- Candidates.reviewed_source(candidate, candidate.digest),
           :ok <- Candidates.checked(candidate),
           {:ok, spec} <- Execution.preview_spec(candidate),
           {:ok, candidate} <-
             Candidates.update(candidate, %{
               preview_status: "starting",
               preview_url: nil,
               preview_output: "",
               preview_receipt: %{
                 "status" => "starting",
                 "digest" => candidate.digest,
                 "attempt_id" => Ecto.UUID.generate(),
                 "port" => spec.port,
                 "started_at" => now(),
                 "url" => nil,
                 "preview_root" => spec.preview_root
               }
             }) do
        {:ok, {candidate, spec}}
      end
    end)
  end

  defp prepare_effect(:deploy, id, digest) do
    Candidates.with_candidate(id, fn candidate ->
      attempt_id = Ecto.UUID.generate()

      with :ok <- Candidates.authorized(candidate, digest),
           :ok <- Candidates.verify_effect_base(candidate, deployment: true),
           :ok <- deployment_state(candidate),
           :ok <- Execution.deployment_available(candidate),
           :ok <- adopted_for_deployment(candidate),
           {:ok, candidate} <-
             Candidates.update(candidate, %{
               deployment_status: "running",
               deployment_output: "",
               deployment_receipt: %{
                 "status" => "running",
                 "digest" => digest,
                 "attempt_id" => attempt_id,
                 "execution_root" => Execution.execution_root(candidate, "deploy", attempt_id),
                 "started_at" => now(),
                 "remote_effect" => "not_started"
               }
             }) do
        {:ok, {candidate, nil}}
      end
    end)
  end

  defp owned_preview_target(candidate, entry, opts) do
    receipt = candidate.preview_receipt
    process = receipt["process"]

    with true <- candidate.preview_status == "running" and candidate.preview_url == entry.spec.url,
         true <- candidate.digest == entry.digest,
         :ok <- Candidates.checked(candidate),
         true <- receipt["digest"] == candidate.digest and receipt["port"] == entry.spec.port,
         true <- receipt["url"] == entry.spec.url and is_binary(receipt["attempt_id"]),
         true <- receipt["attempt_id"] == entry.preview_attempt,
         true <- Keyword.get(opts, :digest, candidate.digest) == candidate.digest,
         true <- Keyword.get(opts, :attempt_id, entry.preview_attempt) == entry.preview_attempt,
         true <- is_map(process) and is_map(entry.process),
         true <- process["process_identity"] == entry.process["process_identity"],
         true <- process["os_pid"] == entry.process["os_pid"],
         true <- process["launcher_pid"] == entry.process["launcher_pid"],
         true <- Runner.listener_owned?(entry.process, entry.spec.port) do
      {:ok,
       %{
         url: entry.spec.url,
         candidate_id: candidate.id,
         digest: candidate.digest,
         attempt_id: entry.preview_attempt
       }}
    else
      _ -> {:error, :preview_unavailable}
    end
  end

  defp run_effect(:check, candidate, _spec, owner, cancel, callbacks, _lease),
    do: Execution.check(candidate, owner, cancel, callbacks)

  defp run_effect(:preview, _candidate, spec, owner, cancel, callbacks, _lease) do
    Runner.run(spec.executable, spec.args,
      cwd: spec.cwd,
      env: spec.env,
      redactions: [spec.env["SECRET_KEY_BASE"]],
      timeout_ms: setting(:candidate_preview_lifetime_ms, 900_000),
      max_output_bytes: setting(:candidate_output_limit, 131_072),
      cancel_ref: cancel,
      owner_pid: owner,
      before_start: callbacks.before_start,
      on_start: callbacks.on_start,
      on_scope: callbacks.on_scope
    )
  end

  defp run_effect(:deploy, candidate, _spec, owner, cancel, callbacks, lease) do
    with true <- Process.alive?(owner),
         {:ok, spec} <- Execution.deployment_spec(candidate) do
      receipt =
        Deployment.launch(candidate, spec.context, lease, owner, cancel, fn _current ->
          run_deployment(spec, owner, cancel, callbacks)
        end)
        |> Map.merge(%{
          "context" => spec.context,
          "app" => spec.app,
          "digest" => candidate.digest
        })

      verify_deployment_receipt(receipt, candidate, spec.context)
    else
      false -> Deployment.not_started(:owner_stopped)
      {:error, reason} -> Deployment.not_started(reason)
    end
  end

  defp run_deployment(spec, owner, cancel, callbacks) do
    Runner.run(spec.executable, spec.args,
      cwd: spec.cwd,
      env: spec.env,
      redactions: spec.redactions,
      timeout_ms: setting(:candidate_deploy_timeout_ms, 900_000),
      max_output_bytes: setting(:candidate_output_limit, 131_072),
      cancel_ref: cancel,
      owner_pid: owner,
      before_start: callbacks.before_start,
      on_start: callbacks.on_start,
      on_scope: callbacks.on_scope
    )
    |> deployment_start_receipt()
  end

  defp deployment_start_receipt(receipt) do
    if receipt["effect"] == "not_started",
      do: Map.put(receipt, "remote_effect", "not_started"),
      else: receipt
  end

  defp verify_deployment_receipt(
         %{"remote_effect" => "not_started"} = receipt,
         _candidate,
         _context
       ),
       do: receipt

  defp verify_deployment_receipt(receipt, candidate, context) do
    case Execution.verify_context(candidate, context) do
      :ok ->
        receipt

      {:error, _} ->
        Map.merge(receipt, %{
          "status" => "uncertain",
          "reason" => "deployment_context_changed"
        })
    end
  end

  defp finish(%{kind: :check} = entry, receipt) do
    Candidates.with_candidate(entry.id, fn candidate ->
      receipt =
        candidate.check_receipt
        |> Map.delete("active_process")
        |> Map.merge(receipt)
        |> Map.put("attempt", entry.attempt)

      valid = Candidates.reviewed_source(candidate, entry.digest) == :ok
      passed = receipt["status"] == "passed" and valid and not entry.stop_requested

      status = check_result_status(entry, receipt, valid)

      receipt = Map.put(receipt, "status", status)

      Candidates.update(candidate, %{
        status: if(passed, do: "checked", else: "check_failed"),
        check_status: if(passed, do: "passed", else: status),
        check_digest: if(passed, do: entry.digest, else: nil),
        check_output: receipt["output"] || "",
        check_receipt: receipt
      })
    end)
  end

  defp finish(%{kind: :preview} = entry, receipt) do
    Candidates.with_candidate(entry.id, fn candidate ->
      status =
        cond do
          entry.readiness_failed ->
            "timed_out"

          entry.stop_requested and get_in(receipt, ["cleanup", "status"]) != "confirmed" ->
            "stop_uncertain"

          entry.stop_requested ->
            "stopped"

          receipt["status"] == "passed" ->
            "exited"

          true ->
            receipt["status"]
        end

      Candidates.update(candidate, %{
        preview_status: status,
        preview_url: nil,
        preview_output: receipt["output"] || "",
        preview_receipt:
          Map.merge(candidate.preview_receipt, %{
            "status" => status,
            "process" => receipt,
            "stopped_at" => now()
          })
      })
    end)
  end

  defp finish(%{kind: :deploy} = entry, receipt) do
    Candidates.with_candidate(entry.id, fn candidate ->
      valid =
        Candidates.authorized(candidate, entry.digest) == :ok and
          Candidates.verify_effect_base(candidate, deployment: true) == :ok

      passed =
        receipt["status"] == "passed" and receipt["effect"] == "completed" and
          valid and not entry.stop_requested

      status = deployment_result_status(receipt, passed)
      remote_effect = deployment_remote_effect(receipt, passed)

      receipt =
        candidate.deployment_receipt
        |> Map.merge(receipt)
        |> Map.merge(%{"status" => status, "remote_effect" => remote_effect})

      Candidates.update(candidate, %{
        status: if(passed, do: "deployed", else: candidate.status),
        deployment_status: status,
        deployment_output: receipt["output"] || "",
        deployment_receipt: receipt
      })
    end)
  end

  defp check_result_status(entry, receipt, valid) do
    cond do
      entry.stop_requested -> "cancelled"
      receipt["status"] == "passed" and not valid -> "stale"
      true -> receipt["status"]
    end
  end

  defp deployment_result_status(receipt, passed) do
    if receipt["status"] == "passed" and not passed,
      do: "uncertain",
      else: receipt["status"]
  end

  defp deployment_remote_effect(receipt, passed) do
    cond do
      passed -> "completed"
      receipt["remote_effect"] == "not_started" -> "not_started"
      true -> "unknown"
    end
  end

  defp persist_process(kind, id, process, entry) do
    Candidates.with_candidate(id, fn candidate ->
      case kind do
        :check ->
          Candidates.update(candidate, %{
            check_receipt: Map.put(candidate.check_receipt, "active_process", process)
          })

        :preview ->
          Candidates.update(candidate, %{
            preview_receipt: Map.put(candidate.preview_receipt, "process", process)
          })

        :deploy ->
          Candidates.update(candidate, %{
            deployment_receipt:
              Map.merge(candidate.deployment_receipt, %{
                "process" => process,
                "digest" => entry.digest,
                "remote_effect" => "unknown"
              })
          })
      end
    end)
  end

  defp reconcile do
    active =
      Repo.all(
        from c in Candidate,
          where:
            c.check_status in ["running", "cancelling"] or
              c.preview_status in ["starting", "running", "stopping"] or
              c.deployment_status in ["running", "cancelling"] or
              c.status in ["adopting", "publishing"]
      )

    Enum.each(active, &reconcile_candidate/1)
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      Logger.warning(
        "Candidate recovery did not access its migrated editor database: #{Exception.message(error)}"
      )
  after
    with :ok <- terminate_orphan_tasks() do
      case EffectLease.reconcile() do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Candidate global process lease remains blocked: #{inspect(reason, limit: 8)}"
          )
      end
    end
  end

  defp reconcile_candidate(candidate) do
    attrs = %{}

    attrs =
      if candidate.check_status in ["running", "cancelling"] do
        cleanup = stop_recorded(candidate.check_receipt["active_process"])

        Map.merge(attrs, %{
          check_status: "interrupted",
          check_digest: nil,
          check_receipt:
            Map.merge(candidate.check_receipt, %{
              "status" => "interrupted",
              "cleanup" => cleanup
            })
        })
      else
        attrs
      end

    attrs =
      if candidate.preview_status in ["starting", "running", "stopping"] do
        cleanup = stop_recorded(candidate.preview_receipt["process"])

        Map.merge(attrs, %{
          preview_status: "interrupted",
          preview_url: nil,
          preview_receipt:
            Map.merge(candidate.preview_receipt, %{
              "status" => "interrupted",
              "cleanup" => cleanup
            })
        })
      else
        attrs
      end

    attrs =
      if candidate.deployment_status in ["running", "cancelling"] do
        cleanup = stop_recorded(candidate.deployment_receipt["process"])

        Map.merge(attrs, %{
          deployment_status: "uncertain",
          deployment_receipt:
            Map.merge(candidate.deployment_receipt, %{
              "status" => "uncertain",
              "remote_effect" => "unknown",
              "cleanup" => cleanup
            })
        })
      else
        attrs
      end

    attrs =
      if candidate.adoption_status == "adopting" do
        Map.merge(attrs, %{
          status: "effect_uncertain",
          adoption_status: "uncertain",
          adoption_receipt:
            Map.merge(candidate.adoption_receipt, %{
              "status" => "uncertain",
              "reason" => "editor_restarted_during_source_adoption"
            })
        })
      else
        attrs
      end

    attrs =
      if candidate.publication_receipt["status"] == "pending" do
        Map.merge(attrs, %{
          status: "effect_uncertain",
          publication_receipt:
            Map.merge(candidate.publication_receipt, %{
              "status" => "uncertain",
              "observed_public_digest" => Content.current_digest(),
              "source_remains_adopted" => candidate.adoption_status == "adopted",
              "reason" => "editor_restarted_during_publication"
            })
        })
      else
        attrs
      end

    Candidates.update(candidate, attrs)
  end

  defp terminate_orphan_tasks do
    children =
      if is_pid(Process.whereis(OhMyJidoDocs.CandidateTasks)),
        do: Task.Supervisor.children(OhMyJidoDocs.CandidateTasks),
        else: []

    Enum.reduce(children, :ok, fn pid, outcome ->
      case Task.Supervisor.terminate_child(OhMyJidoDocs.CandidateTasks, pid) do
        :ok ->
          outcome

        {:error, :not_found} ->
          outcome
      end
    end)
  end

  defp stop_recorded(nil), do: %{"status" => "unconfirmed_no_child_recorded"}
  defp stop_recorded(process), do: Runner.stop(process)

  defp capacity(kind, id, state) do
    count = Enum.count(state.tasks, fn {_ref, entry} -> entry.kind == kind end)
    limit = if kind == :check, do: setting(:candidate_max_checks, 1), else: 1

    cond do
      Enum.any?(state.tasks, fn {_ref, entry} -> entry.id == id end) ->
        {:error, :candidate_busy}

      map_size(state.tasks) >= setting(:candidate_max_effects, 1) ->
        {:error, :candidate_resource_limit}

      count >= limit ->
        {:error, :candidate_resource_limit}

      true ->
        EffectLease.available()
    end
  end

  defp effect_attempt_id(candidate, :check), do: candidate.check_receipt["attempt_id"]
  defp effect_attempt_id(candidate, :preview), do: candidate.preview_receipt["attempt_id"]
  defp effect_attempt_id(candidate, :deploy), do: candidate.deployment_receipt["attempt_id"]

  defp settle_lease(%{lease: nil}, _receipt), do: :ok

  defp settle_lease(entry, receipt) do
    case EffectLease.complete(entry.lease, receipt) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Candidate process lease was not released: #{inspect(reason, limit: 8)}")
    end
  end

  defp previous_cleanup(receipt) do
    cleanup = previous_cleanup_proof(receipt)

    cond do
      is_map(cleanup) and cleanup["status"] not in ["confirmed", "not_started"] ->
        {:error, :previous_process_cleanup_unconfirmed}

      is_nil(cleanup) and is_map(receipt["active_process"]) ->
        {:error, :previous_process_cleanup_unconfirmed}

      true ->
        :ok
    end
  end

  defp previous_cleanup_proof(receipt) do
    receipt["cleanup"] ||
      get_in(receipt, ["process", "cleanup"]) ||
      (List.last(receipt["steps"] || []) || %{})["cleanup"]
  end

  defp adopted_for_deployment(%{adoption_status: "adopted"}), do: :ok
  defp adopted_for_deployment(_candidate), do: {:error, :source_adoption_required}

  defp deployment_state(%{deployment_status: "passed"}), do: {:error, :already_deployed}

  defp deployment_state(%{deployment_receipt: %{"remote_effect" => "unknown"}}),
    do: {:error, :deployment_outcome_uncertain}

  defp deployment_state(_candidate), do: :ok

  defp stopping_attrs(:check), do: %{check_status: "cancelling"}
  defp stopping_attrs(:preview), do: %{preview_status: "stopping", preview_url: nil}
  defp stopping_attrs(:deploy), do: %{deployment_status: "cancelling"}

  defp attempt(candidate, :check), do: candidate.check_receipt["attempt"]
  defp attempt(_candidate, _kind), do: nil

  defp forget(state, ref, entry) do
    %{
      state
      | tasks: Map.delete(state.tasks, ref),
        keys: Map.delete(state.keys, {entry.kind, entry.id})
    }
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
  defp setting(key, default), do: Application.get_env(:oh_my_jido_docs, key, default)
end
