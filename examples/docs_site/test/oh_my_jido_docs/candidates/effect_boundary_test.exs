defmodule OhMyJidoDocs.Candidates.EffectBoundaryTest do
  use OhMyJidoDocs.DataCase, async: false

  import OhMyJidoDocs.CandidateFixtures

  alias OhMyJidoDocs.{Candidates, Workspaces}
  alias OhMyJidoDocs.Candidates.{Deployment, EffectLease, Execution, Manager, Runner, Source}

  @moduletag :candidate_integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup %{tmp_dir: temporary} do
    fixture = setup_fixture(temporary)

    on_exit(fn ->
      # This only retries real identity-checked cleanup. It cannot force-clear a
      # corrupt ownership record or pretend that a child was stopped.
      Candidates.reconcile_process_cleanup()
    end)

    fixture
  end

  test "a reserved deployment excludes another adoption through staging and the real child",
       fixture do
    first = reviewed_candidate("# Approved first\n")
    assert {:ok, first} = Candidates.adopt(first.id, first.digest)
    second = reviewed_candidate("# Reviewed successor\n")
    before = canonical_pointer(fixture)
    {first, lease} = reserve_deployment(first)
    context = stage_context(first)

    other = Task.async(fn -> Candidates.adopt(second.id, second.digest) end)
    assert {:error, :source_deployment_in_progress} = Task.await(other, 30_000)
    assert canonical_pointer(fixture) == before

    marker = Path.join(context["tmp"], "actual-deployment-boundary")
    secret = "only-this-local-child-#{Ecto.UUID.generate()}"

    receipt =
      Deployment.launch(first, context, lease, self(), make_ref(), fn _current ->
        assert {:error, :workspace_busy} =
                 Task.async(fn ->
                   Workspaces.with_workspace_lease(first.workspace_path, fn ->
                     :unexpected_writer
                   end)
                 end)
                 |> Task.await(5_000)

        run_marker(context, marker, secret, lease)
      end)

    assert receipt["status"] == "passed"
    assert receipt["effect"] == "completed"
    assert receipt["cleanup"]["status"] == "confirmed"
    assert receipt["output"] =~ "[REDACTED]"
    refute receipt["output"] =~ secret
    assert File.read!(marker) == "real isolated child"
    assert :ok = EffectLease.complete(lease, receipt)
    assert {:ok, _} = Candidates.adopt(second.id, second.digest)
  end

  test "fresh canonical authorization after staging prevents an obsolete real command", fixture do
    first = reviewed_candidate("# First reviewed source\n")
    assert {:ok, first} = Candidates.adopt(first.id, first.digest)
    first_pointer = canonical_pointer(fixture)
    second = reviewed_candidate("# Later canonical source\n")
    assert {:ok, _} = Candidates.adopt(second.id, second.digest)
    second_pointer = canonical_pointer(fixture)

    # Controlled protected-metadata corruption models an unexpected authority
    # change despite the normal adoption exclusion tested above. Both pointers
    # were produced by real conflict-checked source adoptions, not fabricated.
    replace_canonical_pointer(fixture, first_pointer)
    {first, lease} = reserve_deployment(first)
    context = stage_context(first)
    replace_canonical_pointer(fixture, second_pointer)
    marker = Path.join(context["tmp"], "stale-command")

    receipt =
      Deployment.launch(first, context, lease, self(), make_ref(), fn _current ->
        run_marker(context, marker, "no-external-credential", lease)
      end)

    assert receipt["status"] == "unavailable"
    assert receipt["reason"] =~ "base_conflict"
    assert receipt["remote_effect"] == "not_started"
    assert receipt["cleanup"]["status"] == "not_started"
    refute File.exists?(marker)
    assert canonical_pointer(fixture) == second_pointer
    assert :ok = EffectLease.complete(lease, receipt)
  end

  test "matching cancellation queued during staging never invokes the credentialed command" do
    candidate = reviewed_candidate("# Cancelled deployment source\n")
    assert {:ok, candidate} = Candidates.adopt(candidate.id, candidate.digest)
    {candidate, lease} = reserve_deployment(candidate)
    context = stage_context(candidate)
    marker = Path.join(context["tmp"], "cancelled-command")
    cancel_ref = make_ref()
    send(self(), {:cancel, cancel_ref})

    receipt =
      Deployment.launch(candidate, context, lease, self(), cancel_ref, fn _current ->
        run_marker(context, marker, "no-external-credential", lease)
      end)

    assert receipt["status"] == "cancelled"
    assert receipt["remote_effect"] == "not_started"
    assert receipt["effect"] == "not_started"
    assert receipt["cleanup"]["status"] == "not_started"
    assert is_nil(receipt["os_pid"])
    refute File.exists?(marker)
    assert :ok = EffectLease.complete(lease, receipt)
    assert :ok = EffectLease.available()
  end

  test "a drifted editable workspace is rejected again after the immutable copy was staged" do
    candidate = reviewed_candidate("# Before drift\n")
    assert {:ok, candidate} = Candidates.adopt(candidate.id, candidate.digest)
    {candidate, lease} = reserve_deployment(candidate)
    context = stage_context(candidate)

    File.write!(
      Path.join(candidate.workspace_path, "priv/docs/index.md"),
      "# Late unreviewed edit\n"
    )

    marker = Path.join(context["tmp"], "drifted-command")

    receipt =
      Deployment.launch(candidate, context, lease, self(), make_ref(), fn _current ->
        run_marker(context, marker, "no-external-credential", lease)
      end)

    assert receipt["status"] == "unavailable"
    assert receipt["reason"] =~ "workspace_changed"
    assert receipt["remote_effect"] == "not_started"
    refute File.exists?(marker)
    assert :ok = EffectLease.complete(lease, receipt)
  end

  test "unconfirmed real process ownership blocks different candidates and survives Manager restart" do
    candidate = reviewed_candidate("# Process ownership\n")
    {run, workspace} = run_workspace()
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Other candidate\n")
    assert {:ok, other} = Candidates.prepare(run.id)
    assert {:ok, lease} = EffectLease.acquire(candidate, :check)
    context = candidate.check_receipt["context"]
    {:ok, elixir} = Runner.available("elixir")
    parent = self()

    child =
      Task.async(fn ->
        Runner.run(elixir, ["-e", "IO.puts(\"owned real child\"); Process.sleep(750)"],
          cwd: context["app"],
          env: Execution.environment(context, "prod"),
          owner_pid: parent,
          timeout_ms: 20_000,
          before_start: fn launch -> EffectLease.begin_launch(lease, launch) end,
          on_start: fn process ->
            assert :ok = EffectLease.record_process(lease, process)
            send(parent, {:owned_child_started, process})
            :ok
          end
        )
      end)

    assert_receive {:owned_child_started, process}, 10_000
    mismatched = put_in(process, ["process_identity", "boot_id"], "not-the-recorded-boot")
    stored = File.read!(EffectLease.path()) |> Jason.decode!()

    File.write!(
      EffectLease.path(),
      Jason.encode!(
        put_in(stored, ["process", "process_identity", "boot_id"], "not-the-recorded-boot")
      )
    )

    cleanup = Runner.stop(mismatched)
    assert cleanup["status"] == "uncertain"
    assert :ok = EffectLease.complete(lease, Map.put(mismatched, "cleanup", cleanup))
    assert {:error, :global_process_cleanup_unconfirmed} = Candidates.start_check(other.id)
    assert Candidates.get!(other.id).check_status == "pending"

    previous = Process.whereis(Manager)
    monitor = Process.monitor(previous)
    Process.exit(previous, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^previous, :killed}, 5_000
    await_manager(previous, System.monotonic_time(:millisecond) + 10_000)
    assert {:error, :global_process_cleanup_unconfirmed} = Candidates.start_check(other.id)
    assert File.read!(EffectLease.path()) |> Jason.decode!() |> Map.fetch!("state") == "blocked"

    finished = Task.await(child, 30_000)
    assert finished["cleanup"]["status"] == "confirmed"
    # An operator repairing the protected record restores observed, authentic
    # identity; reconciliation still invokes Runner.stop and verifies it.
    assert :ok = EffectLease.record_process(lease, finished)
    assert {:ok, cleared} = Candidates.reconcile_process_cleanup()
    assert cleared["cleanup"]["status"] == "confirmed"
    recovered = Candidates.get!(candidate.id)
    assert recovered.check_receipt["cleanup"]["status"] == "confirmed"
    assert recovered.check_receipt["launch_id"] == finished["launch_id"]
    assert recovered.check_receipt["active_process"]["launch_id"] == finished["launch_id"]
    refute File.exists?(EffectLease.path())
    assert {:ok, _} = Candidates.start_check(other.id)

    assert await(other.id, &(&1.check_status not in ["pending", "running", "cancelling"])).check_status ==
             "passed"
  end

  test "restart recovery persists the leased keeper generation before clearing capacity" do
    candidate = reviewed_candidate("# Restart before process_started delivery\n")
    context = candidate.check_receipt["context"]
    attempt_id = Ecto.UUID.generate()

    assert {:ok, candidate} =
             Candidates.with_candidate(candidate.id, fn current ->
               Candidates.update(current, %{
                 status: "checking",
                 check_status: "running",
                 check_digest: nil,
                 check_receipt: %{
                   "status" => "running",
                   "attempt" => 2,
                   "attempt_id" => attempt_id
                 }
               })
             end)

    assert {:ok, lease} = EffectLease.acquire(candidate, :check)
    {:ok, elixir} = Runner.available("elixir")
    previous = Process.whereis(Manager)
    parent = self()
    marker = Path.join(context["tmp"], "never-dispatched-during-manager-restart")

    task =
      Task.Supervisor.async_nolink(OhMyJidoDocs.CandidateTasks, fn ->
        Runner.run(
          elixir,
          ["-e", "File.write!(System.fetch_env!(\"RESTART_MARKER\"), \"started\")"],
          cwd: context["app"],
          env: Map.put(Execution.environment(context, "prod"), "RESTART_MARKER", marker),
          owner_pid: previous,
          timeout_ms: 20_000,
          before_start: fn launch -> EffectLease.begin_launch(lease, launch) end,
          on_start: fn process ->
            assert :ok = EffectLease.record_process(lease, process)
            send(parent, {:lease_durable_before_manager_receipt, process})

            receive do
              :unexpected_dispatch -> :ok
            end
          end
        )
      end)

    assert_receive {:lease_durable_before_manager_receipt, process}, 10_000
    refute Candidates.get!(candidate.id).check_receipt["active_process"]
    stored = File.read!(EffectLease.path()) |> Jason.decode!()
    assert stored["generation"] == process["launch_id"]
    assert stored["process"]["process_identity"] == process["process_identity"]
    refute File.exists?(process["process_keeper"]["status_path"] <> ".ack")
    monitor = Process.monitor(previous)
    Process.exit(previous, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^previous, :killed}, 5_000
    await_manager(previous, System.monotonic_time(:millisecond) + 10_000)
    Process.demonitor(task.ref, [:flush])

    recovered = Candidates.get!(candidate.id)
    assert recovered.check_status == "interrupted"
    assert recovered.check_receipt["attempt_id"] == attempt_id
    assert recovered.check_receipt["launch_id"] == process["launch_id"]
    assert recovered.check_receipt["cleanup"]["status"] == "not_started"
    assert recovered.check_receipt["active_process"]["launch_id"] == process["launch_id"]
    refute File.exists?(EffectLease.path())
    refute File.exists?(marker)
    assert {:ok, _} = Candidates.start_check(candidate.id)

    assert await(candidate.id, &(&1.check_status not in ["pending", "running", "cancelling"])).check_status ==
             "passed"

    refute File.exists?(marker)
  end

  test "durable scope updates retain an observed Port child after a delayed initial receipt" do
    candidate = reviewed_candidate("# Descendant scope ownership\n")
    context = candidate.check_receipt["context"]
    assert {:ok, lease} = EffectLease.acquire(candidate, :check)
    assert {:ok, elixir} = Runner.available("elixir")
    assert {:ok, sleep} = Runner.available("sleep")
    parent = self()
    cancel_ref = make_ref()
    marker = Path.join(context["tmp"], "owned-port-child")

    child =
      Task.async(fn ->
        Runner.run(
          elixir,
          [
            "-e",
            """
            port = Port.open(
              {:spawn_executable, System.fetch_env!("OWNED_SLEEP")},
              [:binary, :in, :exit_status, :use_stdio, args: ["60"]]
            )
            {:os_pid, pid} = Port.info(port, :os_pid)
            File.write!(System.fetch_env!("OWNED_PID_FILE"), Integer.to_string(pid))
            Process.sleep(:infinity)
            """
          ],
          cwd: context["app"],
          env:
            Execution.environment(context, "prod")
            |> Map.put("OWNED_SLEEP", sleep)
            |> Map.put("OWNED_PID_FILE", marker),
          owner_pid: parent,
          cancel_ref: cancel_ref,
          timeout_ms: 20_000,
          before_start: fn launch -> EffectLease.begin_launch(lease, launch) end,
          on_start: fn process ->
            assert :ok = EffectLease.record_process(lease, process)
            send(parent, {:initial_scope_receipt, process})
            :ok
          end,
          on_scope: fn process ->
            assert :ok = EffectLease.record_process(lease, process)
            send(parent, {:owned_scope_receipt, process})
            :ok
          end
        )
      end)

    assert_receive {:initial_scope_receipt, initial}, 10_000
    wait_for_file(marker, System.monotonic_time(:millisecond) + 10_000)
    descendant = File.read!(marker) |> String.to_integer()
    observed = await_owned_scope(descendant, System.monotonic_time(:millisecond) + 10_000)
    assert observed["scope_observed"]
    assert observed["owned_processes_complete"]

    assert :ok = EffectLease.record_process(lease, initial)
    retained = File.read!(EffectLease.path()) |> Jason.decode!()
    assert retained["process"]["scope_observed"]
    assert Enum.any?(retained["process"]["owned_processes"], &(&1["pid"] == descendant))
    assert retained["process"]["process_keeper"] == observed["process_keeper"]

    send(child.pid, {:cancel, cancel_ref})
    finished = Task.await(child, 30_000)
    assert finished["cleanup"]["status"] == "confirmed", inspect(finished)
    assert :ok = EffectLease.complete(lease, finished)
    refute File.exists?(EffectLease.path())

    journal =
      EffectLease.path()
      |> Path.dirname()
      |> Path.join("process-lease-receipt.json")
      |> File.read!()
      |> Jason.decode!()

    assert journal["state"] == "released"
    assert journal["cleanup"]["authority"] == "linux_child_subreaper_waitpid"
    assert journal["cleanup"]["all_children_reaped"]
    assert Enum.any?(journal["process"]["owned_processes"], &(&1["pid"] == descendant))
    assert journal["process"]["owned_processes_complete"]
  end

  test "prior cleanup cannot clear a new keeper generation before durable dispatch acknowledgement" do
    candidate = reviewed_candidate("# Real multi-step ownership\n")
    context = candidate.check_receipt["context"]
    {other_run, other_workspace} = run_workspace()
    write!(Path.join(other_workspace, "priv/docs/index.md"), "# Other pending check\n")
    assert {:ok, other} = Candidates.prepare(other_run.id)
    attempt_id = Ecto.UUID.generate()

    assert {:ok, candidate} =
             Candidates.with_candidate(candidate.id, fn current ->
               Candidates.update(current, %{
                 status: "checking",
                 check_status: "running",
                 check_digest: nil,
                 check_receipt: %{"attempt" => 2, "attempt_id" => attempt_id}
               })
             end)

    assert {:ok, lease} = EffectLease.acquire(candidate, :check)
    parent = self()
    marker = Path.join(context["tmp"], "second-generation-ran")

    :sys.replace_state(Manager, fn state ->
      assert map_size(state.tasks) == 0
      owner = self()

      task =
        Task.Supervisor.async_nolink(OhMyJidoDocs.CandidateTasks, fn ->
          receive do
            :start_real_steps -> :ok
          end

          multi_step_children(candidate, context, lease, owner, parent, marker)
        end)

      entry = %{
        id: candidate.id,
        kind: :check,
        digest: candidate.digest,
        task: task,
        cancel_ref: make_ref(),
        process: nil,
        lease: lease,
        attempt_id: attempt_id,
        spec: nil,
        attempt: 2,
        preview_attempt: nil,
        ready: false,
        readiness_failed: false,
        ready_deadline: 0,
        stop_requested: false
      }

      send(parent, {:real_multi_step_task, task.pid, task.ref})

      %{
        state
        | tasks: Map.put(state.tasks, task.ref, entry),
          keys: Map.put(state.keys, {:check, candidate.id}, task.ref)
      }
    end)

    assert_receive {:real_multi_step_task, task, ref}, 5_000
    send(task, :start_real_steps)
    assert_receive {:first_real_step_complete, first}, 10_000
    assert first["cleanup"]["status"] == "confirmed"
    assert :sys.get_state(Manager).tasks[ref].process["launch_id"] == first["launch_id"]
    send(task, :start_second_step)
    assert_receive {:second_real_callback_gated, callback, current}, 10_000
    keeper = current["process_keeper"]
    wait_for_file(keeper["status_path"], System.monotonic_time(:millisecond) + 10_000)
    status = File.read!(keeper["status_path"]) |> Jason.decode!()
    assert status["launch_id"] == current["launch_id"]
    refute status["main_started"]
    assert status["main_identity"] == nil
    assert status["main_exit_status"] == nil
    refute File.exists?(keeper["status_path"] <> ".ack")
    refute File.exists?(marker)
    refute current["launch_id"] == first["launch_id"]
    stored = File.read!(EffectLease.path()) |> Jason.decode!()
    assert stored["generation"] == current["launch_id"]
    assert stored["process"] == nil

    assert {:error, :process_launch_generation_mismatch} =
             EffectLease.record_process(lease, first)

    # The actual earlier child's confirmed receipt cannot release a later
    # trusted keeper; its authored target remains fenced behind durable ACK.
    assert :ok = EffectLease.complete(lease, first)
    retained = File.read!(EffectLease.path()) |> Jason.decode!()
    assert retained["state"] == "blocked"
    assert retained["generation"] == current["launch_id"]
    assert retained["cleanup"]["reason"] == "cleanup_attestation_not_current"
    monitor = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 5_000
    failed = await(candidate.id, &(&1.check_status == "failed"))
    assert failed.check_receipt["launch_id"] == current["launch_id"]
    assert failed.check_receipt["cleanup"]["status"] == "uncertain"
    assert {:error, :global_process_cleanup_unconfirmed} = Candidates.start_check(other.id)
    assert Candidates.get!(other.id).check_status == "pending"

    # Recovery verifies the exact current keeper's authenticated no-dispatch
    # proof and actual exit, even if the independent watchdog finished first.
    assert :ok = EffectLease.record_process(lease, current)
    assert {:ok, cleared} = Candidates.reconcile_process_cleanup()
    assert cleared["generation"] == current["launch_id"]
    assert cleared["cleanup"]["status"] == "not_started"
    recovered = Candidates.get!(candidate.id)
    assert recovered.check_receipt["attempt_id"] == attempt_id
    assert recovered.check_receipt["launch_id"] == current["launch_id"]
    assert recovered.check_receipt["cleanup"]["status"] == "not_started"
    assert recovered.check_receipt["active_process"]["launch_id"] == current["launch_id"]
    if Process.alive?(callback), do: Process.exit(callback, :kill)
    refute File.exists?(marker)
    assert {:ok, _} = Candidates.start_check(other.id)

    assert await(other.id, &(&1.check_status not in ["pending", "running", "cancelling"])).check_status ==
             "passed"
  end

  defp reviewed_candidate(markdown) do
    {run, workspace} = run_workspace()
    File.write!(Path.join(workspace, "priv/docs/index.md"), markdown)
    assert {:ok, candidate} = Candidates.prepare(run.id)
    checked = check!(candidate)
    assert {:ok, approved} = Candidates.approve(checked.id, checked.digest)
    approved
  end

  defp reserve_deployment(candidate) do
    assert {:ok, candidate} =
             Candidates.with_candidate(candidate.id, fn current ->
               Candidates.update(current, %{
                 deployment_receipt: %{"attempt_id" => Ecto.UUID.generate()}
               })
             end)

    assert {:ok, lease} = EffectLease.acquire(candidate, :deploy)
    {candidate, lease}
  end

  defp stage_context(candidate) do
    # Actual confined immutable filesystem staging, without configuring a fake
    # Fly executable, contacting a provider, or executing any authored host code.
    root =
      Execution.execution_root(candidate, "deploy", candidate.deployment_receipt["attempt_id"])

    source = Path.join(root, "source")
    app = Path.join(source, candidate.app_relative)
    assert :ok = File.mkdir_p(root)
    assert :ok = Source.copy(candidate.source_path, source, candidate.manifest)
    assert :ok = Source.read_only(source, candidate.manifest)

    context = %{
      "root" => root,
      "source" => source,
      "app" => app,
      "deps" => Path.join(app, "deps"),
      "readonly" => true
    }

    context =
      Enum.reduce(~w(home tmp mix_home hex_home rustler_cache make_cache), context, fn key,
                                                                                       context ->
        directory = Path.join(root, key)
        File.mkdir_p!(directory)
        Map.put(context, key, directory)
      end)

    assert :ok = Execution.verify_context(candidate, context)
    context
  end

  defp run_marker(context, marker, secret, lease) do
    {:ok, elixir} = Runner.available("elixir")

    Runner.run(
      elixir,
      [
        "-e",
        "File.write!(System.fetch_env!(\"MARKER\"), \"real isolated child\"); IO.puts(System.fetch_env!(\"LOCAL_CHILD_SECRET\"))"
      ],
      cwd: context["app"],
      env:
        Execution.environment(context, "prod")
        |> Map.put("MARKER", marker)
        |> Map.put("LOCAL_CHILD_SECRET", secret),
      redactions: [secret],
      owner_pid: self(),
      timeout_ms: 20_000,
      before_start: fn launch -> EffectLease.begin_launch(lease, launch) end,
      on_start: fn process -> assert :ok = EffectLease.record_process(lease, process) end,
      on_scope: fn process -> assert :ok = EffectLease.record_process(lease, process) end
    )
  end

  defp pointer_path(fixture), do: Path.join(fixture.temporary, "data/source/current.json")
  defp canonical_pointer(fixture), do: File.read!(pointer_path(fixture))

  defp replace_canonical_pointer(fixture, bytes) do
    path = pointer_path(fixture)
    temporary = path <> ".fixture-replacement"
    File.write!(temporary, bytes, [:exclusive])
    File.chmod!(temporary, 0o444)
    File.rename!(temporary, path)
  end

  defp multi_step_children(candidate, context, lease, owner, parent, marker) do
    {:ok, elixir} = Runner.available("elixir")

    base = [
      cwd: context["app"],
      env: Execution.environment(context, "prod"),
      owner_pid: owner,
      timeout_ms: 20_000,
      before_start: fn launch -> EffectLease.begin_launch(lease, launch) end,
      on_scope: fn process -> assert :ok = EffectLease.record_process(lease, process) end
    ]

    first =
      Runner.run(
        elixir,
        ["-e", "IO.puts(\"first actual child\"); Process.sleep(50)"],
        Keyword.put(base, :on_start, fn process ->
          assert :ok = EffectLease.record_process(lease, process)

          send(
            owner,
            {:process_started, :check, candidate.id, candidate.check_receipt["attempt_id"],
             process}
          )

          :ok
        end)
      )

    send(parent, {:first_real_step_complete, first})

    receive do
      :start_second_step -> :ok
    end

    second =
      Runner.run(
        elixir,
        [
          "-e",
          "File.write!(System.fetch_env!(\"SECOND_MARKER\"), \"second actual child\"); Process.sleep(:infinity)"
        ],
        base
        |> Keyword.put(
          :env,
          Map.put(Execution.environment(context, "prod"), "SECOND_MARKER", marker)
        )
        |> Keyword.put(:on_start, fn process ->
          send(parent, {:second_real_callback_gated, self(), process})

          receive do
            :release_second_callback -> :ok
          end

          assert :ok = EffectLease.record_process(lease, process)

          send(
            owner,
            {:process_started, :check, candidate.id, candidate.check_receipt["attempt_id"],
             process}
          )

          :ok
        end)
      )

    %{
      "status" => second["status"],
      "steps" => [first, second],
      "output" => first["output"] <> second["output"]
    }
  end

  defp await_owned_scope(pid, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:owned_scope_receipt, process} ->
        if Enum.any?(process["owned_processes"], &(&1["pid"] == pid)) do
          process
        else
          await_owned_scope(pid, deadline)
        end
    after
      remaining -> flunk("real descendant ownership was not durably observed")
    end
  end

  defp wait_for_file(file, deadline) do
    cond do
      File.regular?(file) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("actual child did not create its marker")

      true ->
        receive do
        after
          10 -> wait_for_file(file, deadline)
        end
    end
  end

  defp await_manager(previous, deadline) do
    current = Process.whereis(Manager)

    cond do
      is_pid(current) and current != previous ->
        assert {:error, :preview_unavailable} = Candidates.preview_target(Ecto.UUID.generate())
        current

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("candidate Manager did not restart")

      true ->
        receive do
        after
          10 -> await_manager(previous, deadline)
        end
    end
  end
end
