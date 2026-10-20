Code.require_file("density_native.exs", __DIR__)
Code.require_file("density_metrics.exs", __DIR__)

defmodule OhMyJido.Bench.Density do
  @moduledoc false

  alias OhMyJido.Bench.Density.{Metrics, Native}
  alias OhMyJido.Runtime

  @runtime __MODULE__.Instance
  @drivers __MODULE__.Callers
  @storage __MODULE__.Storage
  @cleanup_ms 15_000

  def main(arguments) do
    config = options(arguments)

    if File.exists?(config.output),
      do: raise(ArgumentError, "density evidence already exists; choose a new output path")

    host = Metrics.host()
    {:ok, %{capabilities: %{tools: %{enabled: true}}}} = OhMyJido.Models.describe(Native.model())

    unless Enum.all?(host.executables, fn {_name, executable} -> is_binary(executable) end) do
      raise ArgumentError, "density workload requires sh, setsid, mkfifo, cat, kill and sleep"
    end

    unless is_nil(Process.whereis(@runtime)) and is_nil(Process.whereis(@drivers)) and
             is_nil(Process.whereis(Native.finch())) do
      raise ArgumentError, "a density benchmark is already running in this VM"
    end

    gateway_warmup = warmup_gateway(config)

    cwd = File.cwd!()
    environment = Metrics.environment_fingerprint()
    origin = Metrics.now()
    before = Metrics.snapshot(nil, origin)
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(System.tmp_dir!(), "omj-density-#{suffix}")
    File.mkdir!(root)

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Task.Supervisor, name: @drivers, max_children: config.active + 2}
        ],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)

    observer = self()
    deadline = origin + config.deadline_ms * 1_000

    worker =
      Task.Supervisor.async_nolink(@drivers, fn ->
        initialize_storage!()

        run_populations(supervisor, observer, root, config, deadline)
      end)

    {populations, errors} = collect(worker, deadline, [])
    shutdown = shutdown(supervisor, worker)
    removed = File.rm_rf(root)
    after_sample = Metrics.snapshot(nil, origin)

    cleanup = %{
      supervisor_stopped: shutdown,
      runtime_stopped: is_nil(Process.whereis(@runtime)),
      driver_supervisor_stopped: is_nil(Process.whereis(@drivers)),
      gateway_stopped: is_nil(Process.whereis(Native.finch())),
      disposable_root_removed: match?({:ok, _paths}, removed) and not File.exists?(root),
      host_cwd_unchanged: File.cwd!() == cwd,
      host_environment_unchanged: Metrics.environment_fingerprint() == environment,
      os_live_descendants_before: before.os.live_descendant_count,
      os_live_descendants_after: after_sample.os.live_descendant_count,
      os_descendants_returned_to_baseline:
        before.os.live_descendant_count == after_sample.os.live_descendant_count and
          before.os.live_descendants == after_sample.os.live_descendants
    }

    complete = length(populations) == length(config.populations)

    successful =
      complete and errors == [] and Enum.all?(populations, &(&1.result == "passed")) and
        Enum.all?(
          Map.take(cleanup, [
            :supervisor_stopped,
            :runtime_stopped,
            :driver_supervisor_stopped,
            :gateway_stopped,
            :disposable_root_removed,
            :host_cwd_unchanged,
            :host_environment_unchanged,
            :os_descendants_returned_to_baseline
          ]),
          fn {_key, value} -> value end
        )

    report = %{
      schema: "oh_my_jido.density",
      schema_version: 1,
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      result: if(successful, do: "passed", else: if(complete, do: "failed", else: "partial")),
      host: host,
      configuration: Map.drop(config, [:output]),
      workload: %{
        model_boundary:
          "installed Jido.AI.Test explicit ReAct script over loopback HTTP/SSE; no external provider",
        request_transformer: Atom.to_string(Native.Transformer),
        gateway_warmup:
          "one bounded native scripted request initializes VM-owned OTP resolver infrastructure before the empty-runtime baseline; temporary session, checkpoint, runtime and workspace are retired",
        gateway_pool_scope:
          "one benchmark-owned native Finch per population; ephemeral scripted endpoint pools are stopped with that supervised child, never retained in the host's shared Finch",
        model_latency:
          "simulated gateway sleep after successful Models.Transformer delegation, inside native runner",
        tool_latency: "bounded host authorization sleep plus actual filesystem and shell work",
        steps: [
          "read input.txt",
          "snapshot-guarded write output.txt",
          "scoped shell verifies and processes output"
        ],
        fresh_session_per_job: true,
        host_module: Atom.to_string(Native.Host),
        model_label: Native.model(),
        permissions: ["read", "edit", "exec"],
        action_modules: Enum.map(Native.tools(), &Atom.to_string/1),
        history_policy: "fresh native session for every job; replacement is outside run latency",
        queue_policy:
          "no backlog; each wave immediately offers all calls; Task.Supervisor capacity is rejection, not queue",
        percentile_method: "nearest rank over observed values; null for an empty distribution",
        memory_scope:
          "OS VmRSS is BEAM resident memory; erlang.memory is VM-accounted allocated memory, not RSS",
        descendant_rss_scope:
          "sum of observed live descendant RSS; shared pages are not deduplicated",
        sampling_scope:
          "VM-wide counters and runtime supervisor-tree mailboxes; sampled peaks can miss transients",
        cleanup_deadline_ms: @cleanup_ms
      },
      before: before,
      gateway_warmup: gateway_warmup,
      after: after_sample,
      populations: populations,
      errors: errors,
      cleanup: cleanup,
      elapsed_ms: Metrics.elapsed(origin)
    }

    publish(config.output, report)

    IO.puts(
      Jason.encode!(%{result: report.result, evidence_file: config.output, schema_version: 1})
    )

    if not successful, do: System.halt(1)
  end

  defp options(arguments) do
    arguments =
      case arguments do
        ["--" | rest] -> rest
        rest -> rest
      end

    {opts, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [
          populations: :string,
          active: :integer,
          rounds: :integer,
          idle_ms: :integer,
          sample_ms: :integer,
          model_ms: :string,
          tool_ms: :string,
          process_ms: :string,
          run_timeout_ms: :integer,
          tool_timeout_ms: :integer,
          deadline_ms: :integer,
          output: :string
        ]
      )

    if rest != [] or invalid != [], do: raise(ArgumentError, "unknown or invalid density options")

    stamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

    config = %{
      populations: integer_list(Keyword.get(opts, :populations, "1,10,100,500"), 1..500),
      active: Keyword.get(opts, :active, 8),
      rounds: Keyword.get(opts, :rounds, 6),
      idle_ms: Keyword.get(opts, :idle_ms, 250),
      sample_ms: Keyword.get(opts, :sample_ms, 25),
      model_ms: integer_list(Keyword.get(opts, :model_ms, "120,240,180,300"), 0..2_000),
      tool_ms: integer_list(Keyword.get(opts, :tool_ms, "10,20,10"), 0..2_000),
      process_ms: integer_list(Keyword.get(opts, :process_ms, "80,160,120,240"), 0..2_000),
      run_timeout_ms: Keyword.get(opts, :run_timeout_ms, 15_000),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, 5_000),
      deadline_ms: Keyword.get(opts, :deadline_ms, 180_000),
      output: Keyword.get(opts, :output, "bench/results/density-#{stamp}.json")
    }

    valid =
      config.active in 1..64 and config.rounds in 1..1_000 and
        config.idle_ms in 25..10_000 and config.sample_ms in 5..1_000 and
        config.tool_timeout_ms in 500..60_000 and config.run_timeout_ms in 1_000..120_000 and
        config.deadline_ms in 5_000..3_600_000 and length(config.tool_ms) == 3 and
        config.run_timeout_ms > config.tool_timeout_ms and
        config.deadline_ms > config.run_timeout_ms and
        Enum.max(config.process_ms) < config.tool_timeout_ms and
        length(config.populations) == length(Enum.uniq(config.populations))

    unless valid, do: raise(ArgumentError, "density options exceed explicit benchmark limits")

    [read, edit, exec] = config.tool_ms
    %{config | tool_ms: %{read: read, edit: edit, exec: exec}}
  end

  defp integer_list(value, range) do
    values =
      String.split(value, ",", trim: true)
      |> Enum.map(fn text ->
        case Integer.parse(text) do
          {integer, ""} -> integer
          _invalid -> raise ArgumentError, "density lists must contain integers"
        end
      end)

    unless values != [] and length(values) <= 16 and Enum.all?(values, &(&1 in range)) do
      raise ArgumentError, "density list is empty or outside its supported range"
    end

    values
  end

  defp warmup_gateway(config) do
    started = Metrics.now()
    descendants_before = Metrics.snapshot(nil, started).os.live_descendants
    initialization_timeout = config.run_timeout_ms + @cleanup_ms
    deadline = started + initialization_timeout * 1_000
    task = Task.async(fn -> warmup_gateway_request(config) end)
    remaining = max(div(deadline - Metrics.now(), 1_000), 0)
    {supervisor, root, model_calls} = Task.await(task, remaining)
    true = await_teardown(supervisor, task.pid, deadline)
    false = File.exists?(root)

    %{
      result: "passed",
      elapsed_ms: Metrics.elapsed(started),
      request_timeout_ms: config.run_timeout_ms,
      initialization_timeout_ms: initialization_timeout,
      source:
        "native Jido.AI.Test.ReActScript -> MockLLM loopback HTTP/SSE through ReqLLM; OTP native resolver is VM-owned",
      live_descendants_before: descendants_before,
      live_descendants_after: Metrics.snapshot(nil, started).os.live_descendants,
      model_calls: model_calls,
      session_stopped: true,
      checkpoint_removed: true,
      runtime_stopped: true,
      gateway_stopped: is_nil(Process.whereis(Native.finch())),
      disposable_root_removed: true
    }
  end

  defp warmup_gateway_request(config) do
    initialize_storage!()
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(System.tmp_dir!(), "omj-density-gateway-warmup-#{suffix}")
    File.mkdir!(root)

    try do
      {:ok, supervisor} =
        Supervisor.start_link(
          [Native.gateway_child_spec(), {Runtime, runtime_options(config)}],
          strategy: :one_for_one
        )

      try do
        {supervisor, root, warmup_native_session(root, config)}
      after
        Supervisor.stop(supervisor, :normal, @cleanup_ms)
      end
    after
      File.rm_rf!(root)
    end
  end

  defp warmup_native_session(root, config) do
    metadata = Native.metadata("gateway-warmup", self(), config)

    {:ok, session} =
      OhMyJido.start_session(@runtime,
        id: "gateway-warmup",
        workspace: root,
        model: Native.model(),
        tools: [],
        permissions: [],
        metadata: metadata
      )

    {query, options} = Native.warmup_script()
    {:ok, run} = OhMyJido.prompt(session, query, options)

    {:ok, %{status: :completed, answer: answer, tools: []}} =
      OhMyJido.await(session, run, timeout: config.run_timeout_ms)

    true = answer == Native.final_answer("gateway-warmup")
    [%{iteration: 1}] = model_calls = warmup_model_calls([])
    :ok = OhMyJido.stop_session(session)
    :ok = delete_checkpoint(session.id)

    {:error, :not_found} =
      Jido.Persistence.ETS.get(
        OhMyJido.Persistence.session_key({@runtime, session.id}),
        table: @storage
      )

    model_calls
  end

  defp warmup_model_calls(calls) do
    receive do
      {:density_delay, "gateway-warmup", :model, iteration, requested, elapsed} ->
        call = %{iteration: iteration, requested_ms: requested, elapsed_ms: elapsed}
        warmup_model_calls([call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp initialize_storage! do
    # Only this benchmark's dedicated native storage tables lose their heir.
    # The owning workload/warmup Task must delete them on exit, not transfer
    # temporary checkpoint tables into the host Jido application.
    {:error, :not_found} = Jido.Persistence.ETS.get(<<>>, table: @storage)

    for table <- :ets.all(),
        :ets.info(table, :owner) == self(),
        String.starts_with?(Atom.to_string(:ets.info(table, :name)), "#{@storage}_") do
      :ets.setopts(table, {:heir, :none})
    end
  end

  defp runtime_options(config) do
    [
      name: @runtime,
      host: {Native.Host, []},
      request_transformer: Native.Transformer,
      allow_test_scripts: true,
      default_role: :coding,
      model_roles: %{coding: Native.model()},
      tools: Native.tools(),
      storage: {Jido.Persistence.ETS, table: @storage},
      max_sessions: Enum.max(config.populations),
      max_active: config.active,
      max_processes: config.active,
      max_subagents: 1,
      max_jido_tasks: 1_000,
      max_resources: 16,
      max_runs: 16,
      max_effects: 32,
      max_secrets: 1,
      max_iterations: 8,
      event_limit: 64,
      subscriber_limit: 16,
      max_pending_questions: 1,
      question_timeout_ms: config.tool_timeout_ms,
      run_timeout_ms: config.run_timeout_ms,
      tool_timeout_ms: config.tool_timeout_ms,
      limits: %{
        process_timeout_ms: config.tool_timeout_ms,
        max_output_bytes: 4_096,
        max_file_bytes: 8_192,
        max_read_bytes: 8_192
      },
      context_policy: [max_messages: 80, keep_recent: 16, max_bytes: 120_000],
      eval: [backends: %{}, max_kernels: 1]
    ]
  end

  defp run_populations(supervisor, observer, root, config, deadline) do
    Enum.each(config.populations, fn population ->
      ensure_time!(deadline)

      child =
        Supervisor.child_spec({Runtime, runtime_options(config)}, shutdown: div(@cleanup_ms, 2))

      {:ok, _gateway_pid} = Supervisor.start_child(supervisor, Native.gateway_child_spec())
      {:ok, _runtime_pid} = Supervisor.start_child(supervisor, child)

      report =
        try do
          population(population, root, config, deadline)
        rescue
          error -> %{population: population, result: "failed", error: exception_code(error)}
        catch
          kind, _reason ->
            %{
              population: population,
              result: "failed",
              error: %{code: "population_exit", kind: Atom.to_string(kind)}
            }
        after
          stop_registered_sessions()
          Supervisor.terminate_child(supervisor, @runtime)
          Supervisor.delete_child(supervisor, @runtime)
          Supervisor.terminate_child(supervisor, Native.finch())
          Supervisor.delete_child(supervisor, Native.finch())
          Jido.AI.Test.reset_react_scripts()
        end

      send(observer, {:density_population, report})
    end)

    :ok
  end

  defp population(count, root, config, deadline) do
    origin = Metrics.now()
    baseline = Metrics.snapshot(@runtime, origin)
    slots = Enum.map(1..count, &start_slot(count, &1, 0, root, config, deadline))
    idle_samples = sample_idle(config.idle_ms, config.sample_ms, origin, [])
    idle = List.last(idle_samples)

    idle_ok =
      idle.session_coordinator_count == count and idle.native_agent_supervisor_count == count and
        idle.leases.model == 0 and idle.leases.process == 0

    session_admission = session_capacity_probe(count, root, config, deadline)

    levels =
      [1, min(config.active, count), min(config.active + 1, count)] |> Enum.uniq() |> Enum.sort()

    {slots, load_reports} =
      Enum.reduce(levels, {slots, []}, fn offered, {slots, reports} ->
        {slots, waves} =
          Enum.reduce(1..config.rounds, {slots, []}, fn round, {current, waves} ->
            ensure_time!(deadline)
            selected = Enum.take(current, offered)

            {jobs, samples, duration_ms} =
              run_wave(selected, offered, round, config, deadline, origin)

            replacements =
              Enum.map(selected, fn slot ->
                retire_slot!(slot)
                start_slot(count, slot.slot, slot.generation + 1, root, config, deadline)
              end)

            current = replacements ++ Enum.drop(current, offered)

            wave = %{
              round: round,
              offered_concurrency: offered,
              elapsed_ms: duration_ms,
              jobs: jobs,
              pressure: Metrics.pressure_summary(samples),
              samples: samples
            }

            {current, [wave | waves]}
          end)

        waves = Enum.reverse(waves)
        jobs = Enum.flat_map(waves, & &1.jobs)
        samples = Enum.flat_map(waves, & &1.samples)

        report = %{
          offered_concurrency: offered,
          rounds: config.rounds,
          admission: admission_summary(jobs),
          latency_ms: latency_summary(jobs),
          errors: error_counts(jobs),
          pressure: Metrics.pressure_summary(samples),
          waves: waves
        }

        {slots, [report | reports]}
      end)

    Enum.each(slots, &retire_slot!/1)
    after_sessions = Metrics.snapshot(@runtime, origin)
    loads = Enum.reverse(load_reports)
    jobs = Enum.flat_map(loads, fn load -> Enum.flat_map(load.waves, & &1.jobs) end)
    model_rejections = Enum.filter(loads, &(&1.admission.model_capacity_rejections > 0))
    session_probe_ok = session_admission.status in ["capacity_rejected", "not_exercised"]

    admission_ok =
      Enum.all?(loads, fn load ->
        Enum.all?(load.waves, fn wave ->
          admission = admission_summary(wave.jobs)
          expected = min(wave.offered_concurrency, config.active)

          admission.admitted == expected and admission.completed == expected and
            admission.model_capacity_rejections == wave.offered_concurrency - expected and
            admission.failed_or_unobserved == 0
        end)
      end)

    within_limits? = fn sample ->
      is_integer(sample.leases.model) and sample.leases.model <= config.active and
        is_integer(sample.leases.process) and sample.leases.process <= config.active and
        is_integer(sample.session_coordinator_count) and sample.session_coordinator_count <= count
    end

    bounds_ok =
      Enum.all?(idle_samples, within_limits?) and
        Enum.all?(loads, fn load ->
          Enum.all?(load.waves, fn wave -> Enum.all?(wave.samples, within_limits?) end)
        end)

    clean =
      after_sessions.session_coordinator_count == 0 and
        after_sessions.native_agent_supervisor_count == 0 and
        after_sessions.leases.model == 0 and after_sessions.leases.process == 0

    %{
      population: count,
      result:
        if(
          idle_ok and session_probe_ok and admission_ok and bounds_ok and clean and
            error_counts(jobs) == %{},
          do: "passed",
          else: "failed"
        ),
      elapsed_ms: Metrics.elapsed(origin),
      limits: %{
        max_sessions: Enum.max(config.populations),
        max_active: config.active,
        max_processes: config.active,
        max_subagents: 1,
        max_jido_tasks: 1_000,
        run_timeout_ms: config.run_timeout_ms,
        tool_timeout_ms: config.tool_timeout_ms,
        max_iterations: 8,
        max_runs_per_session: 16,
        max_effects_per_session: 32,
        event_limit: 64,
        subscriber_limit: 16,
        eval_backends: [],
        max_resources_per_session: 16,
        max_secrets_per_session: 1,
        max_pending_questions: 1,
        question_timeout_ms: config.tool_timeout_ms,
        process_timeout_ms: config.tool_timeout_ms,
        max_output_bytes: 4_096,
        max_file_bytes: 8_192,
        max_read_bytes: 8_192,
        context_policy: %{max_messages: 80, keep_recent: 16, max_bytes: 120_000},
        storage:
          "dedicated Jido.Persistence.ETS records; checkpoints removed on session retirement"
      },
      baseline: baseline,
      idle: %{
        invariant_passed: idle_ok,
        sample: idle,
        samples: idle_samples,
        delta_from_empty_runtime: Metrics.memory_delta(idle, baseline),
        pressure: Metrics.pressure_summary(idle_samples)
      },
      active: loads,
      saturation: %{
        session_admission: session_admission,
        first_observed_model_rejection_concurrency:
          case model_rejections do
            [first | _rest] -> first.offered_concurrency
            [] -> nil
          end,
        max_sampled_model_leases:
          loads
          |> Enum.map(& &1.pressure.model_leases.max)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(fn -> nil end),
        model_limit_exercised: model_rejections != [],
        oversubscription_offered: Enum.any?(levels, &(&1 > config.active)),
        admission_protocol_passed: admission_ok,
        resource_bounds_passed: bounds_ok,
        queued_work_count: 0,
        capacity_mechanism:
          "immediate Task.Supervisor max_children rejection; no native admission queue"
      },
      cleanup: %{population_removed: clean, after_sessions: after_sessions}
    }
  end

  defp start_slot(population, slot, generation, root, config, deadline) do
    ensure_time!(deadline)
    token = "p#{population}-s#{slot}-g#{generation}"
    workspace = Path.join(root, token)
    Native.prepare_workspace(workspace)
    metadata = Native.metadata(token, self(), config)

    {:ok, session} =
      OhMyJido.start_session(@runtime,
        id: token,
        workspace: workspace,
        permissions: [:read, :edit, :exec],
        model: Native.model(),
        tools: Native.tools(),
        metadata: metadata
      )

    {:ok, %{status: :idle, agent_pid: agent}} = OhMyJido.inspect_session(session)
    true = is_pid(agent) and Process.alive?(agent)

    %{
      slot: slot,
      generation: generation,
      token: token,
      workspace: workspace,
      metadata: metadata,
      session: session
    }
  end

  defp retire_slot!(slot) do
    :ok = OhMyJido.stop_session(slot.session)
    :ok = delete_checkpoint(slot.session.id)
    {:ok, _paths} = File.rm_rf(slot.workspace)
  end

  defp delete_checkpoint(id) do
    key = OhMyJido.Persistence.session_key({@runtime, id})
    Jido.Persistence.ETS.delete(key, table: @storage)
  end

  defp stop_registered_sessions do
    if Process.whereis(Runtime.registry(@runtime)) do
      Enum.each(OhMyJido.list_sessions(@runtime), fn session ->
        OhMyJido.stop_session(session)
        delete_checkpoint(session.id)
      end)
    end
  end

  defp session_capacity_probe(count, root, config, deadline) do
    if count == Enum.max(config.populations) do
      ensure_time!(deadline)
      started = Metrics.now()

      result =
        OhMyJido.start_session(@runtime,
          id: "density-over-session-limit",
          workspace: root,
          model: Native.model(),
          tools: [],
          permissions: []
        )

      elapsed = Metrics.elapsed(started)

      case result do
        {:error, {:capacity, :sessions}} ->
          %{
            status: "capacity_rejected",
            offered_sessions: count + 1,
            admitted_sessions: count,
            latency_ms: elapsed
          }

        {:ok, session} ->
          OhMyJido.stop_session(session)
          delete_checkpoint(session.id)
          %{status: "unexpected_admission", offered_sessions: count + 1, latency_ms: elapsed}

        {:error, reason} ->
          %{
            status: "unexpected_rejection",
            offered_sessions: count + 1,
            reason: reason_code(reason),
            latency_ms: elapsed
          }
      end
    else
      %{status: "not_exercised", reason: "population is below the configured session ceiling"}
    end
  end

  defp sample_idle(duration_ms, sample_ms, origin, samples) do
    until = Metrics.now() + duration_ms * 1_000
    collect_idle(until, sample_ms, origin, samples)
  end

  defp collect_idle(until, sample_ms, origin, samples) do
    sample = Metrics.snapshot(@runtime, origin)
    samples = [sample | samples]

    if Metrics.now() >= until do
      Enum.reverse(samples)
    else
      Process.sleep(min(sample_ms, max(div(until - Metrics.now(), 1_000), 1)))
      collect_idle(until, sample_ms, origin, samples)
    end
  end

  defp run_wave(slots, offered, round, config, deadline, origin) do
    batch = make_ref()
    observer = self()
    started = Metrics.now()

    pending =
      Map.new(slots, fn slot ->
        {query, opts} = Native.script(slot.token, slot.metadata, config.tool_timeout_ms)

        {:ok, pid} =
          Task.Supervisor.start_child(@drivers, fn ->
            receive do
              {:density_start, ^batch, dispatched} ->
                result = run_job(slot, query, opts, config, observer, batch, dispatched, origin)
                send(observer, {:density_job, batch, slot.token, result})
            after
              config.run_timeout_ms -> :ok
            end
          end)

        {slot.token, %{pid: pid, monitor: Process.monitor(pid)}}
      end)

    dispatched = Metrics.now()

    Enum.each(pending, fn {_token, entry} ->
      send(entry.pid, {:density_start, batch, dispatched})
    end)

    state = %{pending: pending, jobs: %{}, delays: %{}, host_errors: %{}, samples: []}
    wave_deadline = min(deadline, started + (config.run_timeout_ms + 2_000) * 1_000)
    state = collect_wave(batch, state, wave_deadline, Metrics.now(), config.sample_ms, origin)
    Jido.AI.Test.reset_react_scripts()

    jobs =
      Enum.map(slots, fn slot ->
        job = Map.fetch!(state.jobs, slot.token)
        delays = Map.get(state.delays, slot.token, []) |> Enum.reverse()
        host_errors = Map.get(state.host_errors, slot.token, []) |> Enum.reverse()
        model_count = Enum.count(delays, &(&1.kind == "model"))
        tool_count = Enum.count(delays, &(&1.kind == "tool_authorization"))

        fixture_ok =
          job.admission == "rejected" or
            (model_count == 4 and tool_count == 3 and host_errors == [])

        job =
          Map.merge(job, %{
            offered_concurrency: offered,
            round: round,
            delay_observations: delays,
            unexpected_host_calls: host_errors,
            requested_process_ms: slot.metadata.density_benchmark.process_ms
          })

        if not fixture_ok and job.status == "completed" do
          %{
            job
            | status: "workload_error",
              error: %{code: "native_fixture_boundary_not_observed"}
          }
        else
          job
        end
      end)

    {jobs, Enum.reverse(state.samples), Metrics.elapsed(started)}
  end

  defp collect_wave(
         _batch,
         %{pending: pending} = state,
         _deadline,
         _next_sample,
         _sample_ms,
         origin
       )
       when map_size(pending) == 0 do
    sample = Metrics.snapshot(@runtime, origin) |> Map.put(:in_flight_driver_attempts, 0)
    %{state | samples: [sample | state.samples]} |> drain_observations()
  end

  defp collect_wave(batch, state, deadline, next_sample, sample_ms, origin) do
    now = Metrics.now()

    {state, next_sample} =
      if now >= next_sample do
        sample =
          Metrics.snapshot(@runtime, origin)
          |> Map.put(:in_flight_driver_attempts, map_size(state.pending))

        {%{state | samples: [sample | state.samples]}, Metrics.now() + sample_ms * 1_000}
      else
        {state, next_sample}
      end

    if Metrics.now() >= deadline do
      Enum.each(state.pending, fn {_token, entry} ->
        Task.Supervisor.terminate_child(@drivers, entry.pid)
        Process.demonitor(entry.monitor, [:flush])
      end)

      jobs =
        Enum.reduce(state.pending, state.jobs, fn {token, _entry}, jobs ->
          job = Map.get(jobs, token, empty_job(token))

          Map.put(jobs, token, %{
            job
            | status: "timed_out",
              error: %{code: "wave_deadline_exceeded"}
          })
        end)

      collect_wave(
        batch,
        %{state | pending: %{}, jobs: jobs},
        deadline,
        next_sample,
        sample_ms,
        origin
      )
    else
      wait_ms = max(div(min(next_sample, deadline) - Metrics.now(), 1_000), 0)

      state =
        receive do
          {:density_job, ^batch, token, job} ->
            case Map.pop(state.pending, token) do
              {nil, _pending} ->
                state

              {entry, pending} ->
                Process.demonitor(entry.monitor, [:flush])
                %{state | pending: pending, jobs: Map.put(state.jobs, token, job)}
            end

          {:density_admitted, ^batch, token, job} ->
            %{state | jobs: Map.put(state.jobs, token, job)}

          {:density_delay, token, kind, step, requested, elapsed} ->
            record_delay(state, token, kind, step, requested, elapsed)

          {:density_host_error, token, kind} ->
            record_host_error(state, token, kind)

          {:DOWN, monitor, :process, _pid, _reason} ->
            case Enum.find(state.pending, fn {_token, entry} -> entry.monitor == monitor end) do
              nil ->
                state

              {token, _entry} ->
                job = Map.get(state.jobs, token, empty_job(token))

                %{
                  state
                  | pending: Map.delete(state.pending, token),
                    jobs:
                      Map.put(state.jobs, token, %{
                        job
                        | status: "worker_error",
                          error: %{code: "driver_worker_down"}
                      })
                }
            end
        after
          wait_ms -> state
        end

      collect_wave(batch, state, deadline, next_sample, sample_ms, origin)
    end
  end

  defp record_delay(state, token, kind, step, requested, elapsed) do
    observation = %{
      kind: Atom.to_string(kind),
      step: to_string(step),
      requested_ms: requested,
      observed_ms: elapsed
    }

    %{state | delays: Map.update(state.delays, token, [observation], &[observation | &1])}
  end

  defp record_host_error(state, token, kind) do
    value = Atom.to_string(kind)
    %{state | host_errors: Map.update(state.host_errors, token, [value], &[value | &1])}
  end

  defp drain_observations(state) do
    receive do
      {:density_delay, token, kind, step, requested, elapsed} ->
        record_delay(state, token, kind, step, requested, elapsed) |> drain_observations()

      {:density_host_error, token, kind} ->
        record_host_error(state, token, kind) |> drain_observations()
    after
      0 -> state
    end
  end

  defp run_job(slot, query, opts, config, observer, batch, dispatched, origin) do
    started = Metrics.now()

    job =
      empty_job(slot.token)
      |> Map.merge(%{
        offered_at_ms: (started - origin) / 1_000,
        driver_dispatch_ms: (started - dispatched) / 1_000
      })

    case OhMyJido.prompt(slot.session, query, opts) do
      {:ok, run} ->
        job = %{job | admission: "admitted", admission_ms: Metrics.elapsed(started), run_id: run}
        send(observer, {:density_admitted, batch, slot.token, job})
        outcome = OhMyJido.await(slot.session, run, timeout: config.run_timeout_ms)
        job = %{job | run_latency_ms: Metrics.elapsed(started)}
        {checks, tool_evidence} = workload_checks(slot, run, outcome)

        native_status =
          case outcome do
            {_kind, %{status: status}} -> Atom.to_string(status)
            {:error, :timeout} -> "await_timeout"
            {:error, _reason} -> "await_error"
          end

        valid = Enum.all?(checks, fn {_name, value} -> value end)

        status =
          if valid,
            do: "completed",
            else: if(native_status == "completed", do: "workload_error", else: "run_error")

        error =
          if valid,
            do: nil,
            else: %{
              code:
                if(native_status == "completed",
                  do: "workload_invariant_failed",
                  else: "native_run_not_completed"
                )
            }

        %{
          job
          | status: status,
            native_status: native_status,
            checks: checks,
            tool_evidence: tool_evidence,
            error: error
        }

      {:error, reason} ->
        %{
          job
          | admission: "rejected",
            admission_ms: Metrics.elapsed(started),
            status: "admission_rejected",
            error: reason_code(reason)
        }
    end
  rescue
    error ->
      empty_job(slot.token) |> Map.merge(%{status: "worker_error", error: exception_code(error)})
  catch
    kind, _reason ->
      empty_job(slot.token)
      |> Map.merge(%{
        status: "worker_error",
        error: %{code: "driver_exit", kind: Atom.to_string(kind)}
      })
  end

  defp workload_checks(slot, run, outcome) do
    expected_answer = Native.final_answer(slot.token)

    snapshot =
      case OhMyJido.inspect_session(slot.session) do
        {:ok, value} -> value
        _error -> %{}
      end

    effects = snapshot |> Map.get(:effects, %{}) |> Map.values() |> Enum.filter(&(&1.run == run))

    result = fn name ->
      case Enum.find(effects, &(&1.name == name and &1.status == :completed)) do
        %{result: {:ok, value}} when is_map(value) -> value
        %{result: {:ok, value, _effects}} when is_map(value) -> value
        _other -> %{}
      end
    end

    read = result.("read")
    write = result.("write")
    shell = result.("shell")

    events =
      case OhMyJido.events(slot.session) do
        list when is_list(list) -> list
        _error -> []
      end

    events = Enum.filter(events, &(&1.run_id == run))

    started_tools =
      events |> Enum.filter(&(&1.kind == :tool_started)) |> Enum.map(& &1.payload.tool_name)

    completed_tools =
      events |> Enum.filter(&(&1.kind == :tool_completed)) |> Enum.map(& &1.payload.tool_name)

    checks = %{
      native_terminal_completed: match?({:ok, %{status: :completed}}, outcome),
      expected_native_answer: match?({:ok, %{answer: ^expected_answer}}, outcome),
      native_model_turns: Enum.count(events, &(&1.kind == :llm_started)) == 4,
      native_tool_trace:
        started_tools == ["read", "write", "shell"] and completed_tools == started_tools,
      complete_effect_records:
        length(effects) == 3 and Enum.all?(effects, &(&1.status == :completed)),
      read_exact: read[:content] == Native.input(),
      guarded_write_observed:
        write[:snapshot] == OhMyJido.Files.snapshot(Native.content(slot.token)) and
          write[:previous_snapshot] == "missing" and write[:created] == true,
      write_exact:
        File.read(Path.join(slot.workspace, "output.txt")) == {:ok, Native.content(slot.token)},
      shell_exit_zero: shell[:status] == :exited and shell[:exit_status] == 0,
      shell_streams_exact:
        shell[:stdout] == "density stdout:#{slot.token}\n" and
          shell[:stderr] == "density stderr\n",
      shell_cleanup_confirmed: shell[:cleanup] == :confirmed and shell[:effect] == :completed,
      child_cwd_scoped:
        File.read(Path.join(slot.workspace, "child-cwd.txt")) ==
          {:ok, Path.join(slot.workspace, "nested") <> "\n"},
      child_env_scoped:
        File.read(Path.join(slot.workspace, "child-env.txt")) == {:ok, slot.token <> "\n"},
      shell_processed_written_file:
        File.read(Path.join(slot.workspace, "receipt.txt")) == {:ok, "processed:#{slot.token}\n"}
    }

    evidence = %{
      completed_effect_count: Enum.count(effects, &(&1.status == :completed)),
      read_snapshot_sha256: read[:snapshot],
      written_snapshot_sha256: write[:snapshot],
      written_bytes: write[:bytes_written],
      process_duration_ms: shell[:duration_ms],
      process_exit_status: shell[:exit_status],
      process_status: if(shell[:status], do: Atom.to_string(shell.status)),
      process_cleanup: if(shell[:cleanup], do: Atom.to_string(shell.cleanup)),
      process_effect: if(shell[:effect], do: Atom.to_string(shell.effect)),
      stdout_bytes: if(is_binary(shell[:stdout]), do: byte_size(shell.stdout)),
      stderr_bytes: if(is_binary(shell[:stderr]), do: byte_size(shell.stderr))
    }

    {checks, evidence}
  end

  defp empty_job(token) do
    %{
      job_id: token,
      run_id: nil,
      offered_at_ms: nil,
      driver_dispatch_ms: nil,
      admission: "unknown",
      admission_ms: nil,
      run_latency_ms: nil,
      native_status: nil,
      status: "unknown",
      error: nil,
      checks: %{},
      tool_evidence: %{}
    }
  end

  defp admission_summary(jobs) do
    %{
      offered: length(jobs),
      admitted: Enum.count(jobs, &(&1.admission == "admitted")),
      rejected: Enum.count(jobs, &(&1.admission == "rejected")),
      model_capacity_rejections:
        Enum.count(jobs, &(&1.error == %{code: "capacity", resource: "model"})),
      completed: Enum.count(jobs, &(&1.status == "completed")),
      failed_or_unobserved:
        Enum.count(jobs, &(&1.status not in ["completed", "admission_rejected"])),
      queued: 0
    }
  end

  defp latency_summary(jobs) do
    %{
      admitted_run:
        jobs
        |> Enum.filter(&(&1.admission == "admitted"))
        |> numeric_values(:run_latency_ms)
        |> Metrics.distribution(),
      completed_run:
        jobs
        |> Enum.filter(&(&1.status == "completed"))
        |> numeric_values(:run_latency_ms)
        |> Metrics.distribution(),
      admitted_call:
        jobs
        |> Enum.filter(&(&1.admission == "admitted"))
        |> numeric_values(:admission_ms)
        |> Metrics.distribution(),
      rejected_call:
        jobs
        |> Enum.filter(&(&1.admission == "rejected"))
        |> numeric_values(:admission_ms)
        |> Metrics.distribution(),
      driver_dispatch: numeric_values(jobs, :driver_dispatch_ms) |> Metrics.distribution()
    }
  end

  defp numeric_values(jobs, key),
    do: jobs |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1)

  defp error_counts(jobs) do
    jobs
    |> Enum.reject(
      &(&1.status == "completed" or
          (&1.status == "admission_rejected" and
             &1.error == %{code: "capacity", resource: "model"}))
    )
    |> Enum.map(fn job -> if job.error, do: job.error.code, else: "unobserved_job" end)
    |> Enum.frequencies()
  end

  defp reason_code({:capacity, resource}),
    do: %{code: "capacity", resource: Atom.to_string(resource)}

  defp reason_code(reason) when is_atom(reason), do: %{code: Atom.to_string(reason)}
  defp reason_code(_reason), do: %{code: "native_rejection"}

  defp exception_code(error),
    do: %{code: "benchmark_exception", type: Atom.to_string(error.__struct__)}

  defp ensure_time!(deadline) do
    if Metrics.now() >= deadline, do: raise(RuntimeError, "density benchmark deadline exceeded")
  end

  defp collect(worker, deadline, populations) do
    remaining = max(div(deadline - Metrics.now(), 1_000), 0)

    receive do
      {:density_population, report} ->
        collect(worker, deadline, [report | populations])

      {ref, :ok} when ref == worker.ref ->
        Process.demonitor(ref, [:flush])
        {Enum.reverse(populations), []}

      {:DOWN, ref, :process, _pid, _reason} when ref == worker.ref ->
        {Enum.reverse(populations), [%{code: "benchmark_worker_down"}]}
    after
      remaining -> {Enum.reverse(populations), [%{code: "benchmark_deadline_exceeded"}]}
    end
  end

  defp shutdown(supervisor, worker) do
    deadline = Metrics.now() + @cleanup_ms * 1_000

    stopped =
      try do
        Supervisor.stop(supervisor, :normal, @cleanup_ms)
        true
      catch
        :exit, _reason ->
          Process.exit(supervisor, :kill)
          false
      end

    if Process.alive?(worker.pid), do: Process.exit(worker.pid, :kill)
    Process.demonitor(worker.ref, [:flush])
    ready = await_teardown(supervisor, worker.pid, deadline)
    stopped and ready
  end

  defp await_teardown(supervisor, worker, deadline) do
    ready =
      not Process.alive?(supervisor) and not Process.alive?(worker) and
        is_nil(Process.whereis(@runtime)) and is_nil(Process.whereis(@drivers)) and
        is_nil(Process.whereis(Native.finch()))

    cond do
      ready ->
        true

      Metrics.now() >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_teardown(supervisor, worker, deadline)
    end
  end

  defp publish(path, report) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, Jason.encode!(report, pretty: true) <> "\n", [:exclusive])

    try do
      # Linking publishes a complete file without overwriting previous evidence.
      :ok = File.ln(temporary, path)
    after
      File.rm(temporary)
    end
  end
end

OhMyJido.Bench.Density.main(System.argv())
