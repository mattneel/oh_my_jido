defmodule ElixosHost.T10 do
  @moduledoc """
  Human-started, source-pinned no-NIC guest acceptance using native scripted
  Jido.AI ReAct turns and actual library/OS effects. No provider inference is
  claimed. Each Candidate execution/proposal still requires a fresh Ask grant.
  Only the normal boot Health/AutoCommit path can COMMIT; this module cannot.
  """
  require Jido.AI.Test
  import Jido.AI.Test, only: [user: 1, call: 3, answer: 1]

  alias Elixos.Candidate
  alias Elixos.Candidate.Evidence
  alias ElixosHost.FactoryReceipt

  @root "/priv/oh_my_jido/t10"
  @model "anthropic:claude-sonnet-4-20250514"
  @suite_timeout 600_000
  @run_timeout 1_800_000
  @workload OhMyJidoGuest.Workload

  @doc "Starts one finite scenario task; inspect/answer its real Ask questions from IEx."
  def stage(scenario) when scenario in [:healthy, :fallback] do
    with {:ok, env} <- guest(),
         {:ok, identity} <- FactoryReceipt.verify(),
         :ok <- baseline(scenario, env),
         :ok <- fresh_workspace(scenario),
         :ok <- start_runtime(scenario),
         {:ok, session} <-
           OhMyJido.start_session(runtime(scenario),
             id: session_id(scenario),
             workspace: workspace(scenario),
             model: @model,
             permissions: [:read, :edit, :candidate, :deploy]
           ),
         :ok <- select_tools(session),
         state = %{
           scenario: scenario,
           parent: env.generation,
           session: session,
           factory: identity,
           calls: [],
           runs: [],
           status: :running
         },
         :ok <- Evidence.write(directory(scenario), "stage", state),
         {:ok, pid} <- Task.Supervisor.start_child(drivers(scenario), fn -> drive(state) end) do
      {:ok,
       %{
         driver: pid,
         session: session,
         workspace: workspace(scenario),
         evidence: directory(scenario),
         mode: :native_scripted_no_provider
       }}
    end
  end

  @doc "Reads the durable scenario state without executing work or replaying effects."
  def status(scenario) when scenario in [:healthy, :fallback],
    do: Evidence.read(directory(scenario), "stage")

  @doc "Checks real post-reboot health/seal/fallback and explicitly resumes the durable session."
  def verify(scenario) when scenario in [:healthy, :fallback] do
    with {:ok, env} <- guest(),
         {:ok, identity} <- FactoryReceipt.verify(),
         {:ok, %{status: :next_written} = state} <- status(scenario),
         true <- identity == state.factory,
         :ok <- boot_outcome(scenario, env, state),
         {:ok, candidate} <- Candidate.open(state.candidate_id),
         {:ok, provenance} <- Candidate.provenance(state.generation),
         true <- provenance == candidate.manifest.provenance,
         :ok <- build_provenance(state, candidate),
         :ok <- suite_receipts(candidate),
         :ok <- start_runtime(scenario),
         {:ok, session} <- restore_session(state.session),
         {:ok, snapshot} <- OhMyJido.inspect_session(session),
         true <- snapshot.retained.retained.memory["t10_candidate"] == state.candidate_id,
         true <- snapshot.retained.retained.memory["t10_generation"] == state.generation,
         true <-
           Enum.any?(snapshot.conversation, &(Map.get(&1, :role) in [:assistant, "assistant"])),
         {:ok, resumed} <-
           scripted(
             state,
             "Resume the same durable T10 session after boot without replaying any mutation",
             [{"read", %{path: "lib/workload.ex"}}]
           ),
         receipt = %{
           result: :guest_postconditions_verified,
           scenario: scenario,
           generation: env.generation,
           candidate_generation: state.generation,
           resumed_run: List.last(resumed.runs),
           factory: identity,
           session: session,
           serial_transcript_required: true
         },
         :ok <- Evidence.record(directory(scenario), "verified", receipt) do
      {:ok, receipt}
    else
      false -> {:error, :continuity_or_factory_mismatch}
      {:error, _reason} = error -> error
      _unexpected -> {:error, :scenario_not_ready}
    end
  end

  defp drive(state) do
    result =
      try do
        cwd = File.cwd!()
        loaded = loaded_workload()
        source = Path.join(workspace(state.scenario), "lib/workload.ex") |> File.read!()

        calls = [
          {"read", %{path: "mix.exs"}},
          {"read", %{path: "test/workload_test.exs"}},
          {"read", %{path: "lib/workload.ex"}},
          {"edit",
           %{
             path: "lib/workload.ex",
             snapshot: sha256(source),
             edits: [%{old: "value - 1", new: "value + 1"}]
           }},
          {"elixos_candidate", %{operation: "build", path: "."}}
        ]

        with {:ok, state} <-
               scripted(
                 state,
                 "Inspect and repair only the disposable userland Mix project, then build its isolated candidate",
                 calls
               ),
             {:ok, build} <- tool_value(state.session, List.last(state.runs), "elixos_candidate"),
             {:ok, candidate} <- Candidate.open(build.candidate_id),
             true <- loaded_workload() == loaded and File.cwd!() == cwd,
             true <-
               File.read!(Path.join(workspace(state.scenario), "lib/workload.ex")) ==
                 String.replace(source, "value - 1", "value + 1"),
             :ok <- build_provenance(state, candidate),
             {:error, :not_validated} <- Candidate.propose(candidate),
             {:ok, state} <-
               scripted(
                 state,
                 "Run the real portable OS, toolset and userland candidate suites in isolated ERTS workers",
                 [{"elixos_candidate", %{operation: "test", candidate_id: candidate.id}}]
               ),
             :ok <- suite_receipts(candidate),
             true <- loaded_workload() == loaded and File.cwd!() == cwd,
             state = Map.put(state, :candidate_id, candidate.id),
             :ok <- checkpoint(state),
             :ok <- Evidence.write(directory(state.scenario), "stage", state),
             {:ok, state} <-
               scripted(
                 state,
                 "Request a fresh scoped human approval to propose only this tested candidate through NEXT; never commit or reboot",
                 [{"elixos_candidate", %{operation: "propose", candidate_id: candidate.id}}]
               ),
             {:ok, proposal} <-
               tool_value(state.session, List.last(state.runs), "elixos_candidate"),
             true <-
               proposal.next_written and not proposal.promotion_acknowledged and
                 not proposal.reboot_requested,
             {:ok, provenance} <- Candidate.provenance(proposal.generation),
             true <- provenance == candidate.manifest.provenance,
             state = Map.merge(state, %{generation: proposal.generation, status: :next_written}),
             :ok <- checkpoint(state),
             :ok <- Evidence.write(directory(state.scenario), "stage", state) do
          {:ok,
           %{
             generation: state.generation,
             evidence: directory(state.scenario),
             next_written: true,
             promotion_acknowledged: false,
             reboot_requested: false
           }}
        else
          false -> {:error, :guest_contract_failed}
          {:error, _reason} = error -> error
          other -> {:error, {:unexpected_contract_result, inspect(other, limit: 20)}}
        end
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {kind, inspect(reason, limit: 20)}}
      end

    :ok = Evidence.record(directory(state.scenario), "driver", %{result: result})
    IO.inspect(result, label: "T10 native scripted guest (not provider evidence)")
  end

  defp scripted(state, prompt, additions) do
    calls = state.calls ++ additions

    script =
      Jido.AI.Test.expect_react do
        user(prompt)
        # Native ReActScript indexes the entire retained tool transcript. Earlier
        # entries are the actual previous calls, not new/replayed effects.
        for {{name, arguments}, index} <- Enum.with_index(calls) do
          call(name, arguments, id: "t10-#{state.scenario}-#{index}")
        end

        answer(
          "Deterministic T10 phase ended; actual tool and suite receipts determine acceptance."
        )
      end

    with {:ok, run} <- OhMyJido.prompt(state.session, prompt, Jido.AI.Test.react_opts(script)),
         {:ok, %{status: :completed}} <- OhMyJido.await(state.session, run, timeout: @run_timeout),
         {:ok, snapshot} <- OhMyJido.inspect_session(state.session),
         effects = snapshot.effects |> Map.values() |> Enum.filter(&(&1.run == run)),
         true <- length(effects) == length(additions),
         true <- Enum.all?(effects, &successful_effect?/1) do
      {:ok, %{state | calls: calls, runs: state.runs ++ [run]}}
    else
      false -> {:error, :actual_tool_effect_failed}
      {:error, _reason} = error -> error
    end
  end

  defp successful_effect?(%{status: :completed, result: {:ok, _value, _effects}}), do: true
  defp successful_effect?(%{status: :completed, result: {:ok, _value}}), do: true
  defp successful_effect?(_), do: false

  defp tool_value(session, run, name) do
    with {:ok, snapshot} <- OhMyJido.inspect_session(session) do
      case Enum.filter(Map.values(snapshot.effects), &(&1.run == run and &1.name == name)) do
        [%{status: :completed, result: {:ok, value, _effects}}] -> {:ok, value}
        [%{status: :completed, result: {:ok, value}}] -> {:ok, value}
        _ -> {:error, {:tool_receipt_missing, name}}
      end
    end
  end

  defp checkpoint(state) do
    memory = %{
      "t10_candidate" => state.candidate_id,
      "t10_generation" => Map.get(state, :generation),
      "t10_source_pin" => state.factory["source_sha256"]
    }

    with :ok <-
           OhMyJido.retain(state.session, %{
             memory: memory,
             constraints: [
               "No direct COMMIT, reboot, protected module mutation or provider inference"
             ]
           }),
         :ok <- OhMyJido.checkpoint(state.session),
         do: :ok
  end

  defp build_provenance(state, candidate) do
    provenance = candidate.manifest.provenance

    with true <- provenance.session == %{runtime: state.session.runtime, id: state.session.id},
         true <- provenance.parent == state.parent and provenance.model == @model,
         true <- Map.keys(candidate.manifest.modules) == [@workload],
         true <- candidate.manifest.boot == [{@workload, :boot, [state.scenario]}],
         {:ok, %{result: :ok, runtime: child}} <- Candidate.evidence(candidate, :build),
         true <- child.os_pid != System.pid() and child.node == "nonode@nohost",
         tools = [OhMyJido.Tools.Read, OhMyJido.Tools.Edit, ElixosHost.Tools.Candidate],
         true <- Enum.sort(Map.keys(provenance.tools)) == Enum.sort(Enum.map(tools, & &1.name())),
         true <-
           Enum.all?(tools, fn module ->
             {^module, bytes, _} = :code.get_object_code(module)
             provenance.tools[module.name()].revision == sha256(bytes)
           end) do
      :ok
    else
      _ -> {:error, :invalid_actual_candidate_provenance}
    end
  end

  defp suite_receipts(candidate) do
    with {:ok, %{result: :ok, suites: suites}} <- Candidate.evidence(candidate, :test),
         true <- Enum.sort(Map.keys(suites)) == [:candidate_suite, :system_suite, :toolset_smoke],
         true <-
           Enum.all?(suites, fn {_name, suite} ->
             suite.result == :ok and suite.failures == 0 and
               suite.total - suite.excluded - suite.skipped > 0 and
               suite.os_pid != System.pid() and suite.node == "nonode@nohost"
           end),
         true <- suites |> Map.values() |> Enum.map(& &1.os_pid) |> Enum.uniq() |> length() == 3 do
      :ok
    else
      _ -> {:error, :real_candidate_suites_not_passed}
    end
  end

  defp boot_outcome(scenario, env, state) do
    expected = if scenario == :healthy, do: state.generation, else: state.parent

    with true <- env.generation == expected,
         {:ok, boot} <- boot_state(),
         true <- boot == %{current: expected, last_good: expected, attempts: 0},
         {:ok, %{result: :ok}} <- Evidence.read(Candidate.evidence_dir(expected), "health"),
         {:ok, %{result: :ok}} <- Evidence.read(Candidate.evidence_dir(expected), "auto_commit"),
         :ok <- Candidate.verify_running_generation(expected),
         :ok <- fallback_observation(scenario, state) do
      :ok
    else
      false -> {:error, :normal_boot_not_committed_to_expected_generation}
      {:error, _reason} = error -> error
    end
  end

  defp fallback_observation(:healthy, _state), do: :ok

  defp fallback_observation(:fallback, state) do
    path = Path.join(directory(:fallback), "boot-attempts.log")

    with {:ok, bytes} <- File.read(path),
         rows = String.split(bytes, "\n", trim: true) |> Enum.map(&String.split/1),
         true <- length(rows) == 3,
         true <-
           Enum.with_index(rows, 1)
           |> Enum.all?(fn
             {[generation, attempt, pid], index} ->
               generation == Integer.to_string(state.generation) and
                 attempt == Integer.to_string(index) and
                 String.match?(pid, ~r/\A[1-9][0-9]*\z/)

             _ ->
               false
           end),
         true <- rows |> Enum.map(&List.last/1) |> Enum.uniq() |> length() == 3,
         false <-
           File.exists?(Path.join(Candidate.evidence_dir(state.generation), "auto_commit.term")) do
      :ok
    else
      _ -> {:error, :normal_fallback_observation_missing}
    end
  end

  defp baseline(:healthy, env) do
    with true <- env.generation == 0,
         {:ok, %{current: 0, last_good: 0, attempts: 0}} <- boot_state() do
      :ok
    else
      _ -> {:error, :wait_for_factory_health_and_automatic_commit_on_a_fresh_disposable_disk}
    end
  end

  defp baseline(:fallback, env) do
    with {:ok, %{status: :next_written, generation: generation}} <- status(:healthy),
         true <- env.generation == generation,
         {:ok, %{result: :guest_postconditions_verified}} <-
           Evidence.read(directory(:healthy), "verified"),
         {:ok, %{current: ^generation, last_good: ^generation, attempts: 0}} <- boot_state() do
      :ok
    else
      _ -> {:error, :healthy_candidate_must_be_verified_first}
    end
  end

  defp guest do
    with {:ok, %{mode: :normal} = env} <- Elixos.Boot.Env.current(),
         {:ok, ["lo"]} <- File.ls("/sys/class/net"),
         {:ok, cmdline} <- File.read("/proc/cmdline"),
         false <-
           Enum.any?(
             String.split(cmdline),
             &(String.starts_with?(&1, "elixos.generation=") or
                 String.starts_with?(&1, "elixos.max_attempts=") or
                 &1 in ["elixos.safe", "elixos.safe=1"])
           ),
         :error <- Application.fetch_env(:elixos, :health_checks) do
      {:ok, env}
    else
      _ -> {:error, :requires_normal_no_nic_guest_without_health_or_recovery_overrides}
    end
  end

  defp fresh_workspace(scenario) do
    source = Application.app_dir(:elixos_host, "priv/t10/project")

    with :ok <- File.mkdir_p(directory(scenario)),
         false <- File.exists?(workspace(scenario)),
         {:ok, _paths} <- File.cp_r(source, workspace(scenario)) do
      :ok
    else
      true -> {:error, :scenario_workspace_already_exists_never_replayed}
      {:error, _reason} = error -> error
    end
  end

  defp start_runtime(scenario) do
    if Process.whereis(runtime(scenario)) do
      :ok
    else
      options = [
        runtime: runtime(scenario),
        approval_tasks: approvals(scenario),
        storage_path: Path.join(@root, "sessions"),
        deployment_enabled: true,
        allow_test_scripts: true,
        max_sessions: 1,
        max_active: 1,
        approval_timeout_ms: 300_000,
        tool_timeout_ms: 900_000,
        run_timeout_ms: @run_timeout,
        build_options: [
          target: :elixos,
          system_source: "/factory/source/os",
          deps_path: "/factory/source/os/deps",
          timeout: @suite_timeout,
          boot: [{@workload, :boot, [scenario]}]
        ]
      ]

      with {:ok, _host} <-
             DynamicSupervisor.start_child(
               Elixos.Package.Services,
               {ElixosHost.Supervisor, options}
             ),
           {:ok, _drivers} <-
             DynamicSupervisor.start_child(
               Elixos.Package.Services,
               {Task.Supervisor, name: drivers(scenario)}
             ) do
        :ok
      end
    end
  end

  defp select_tools(session) do
    with :ok <- OhMyJido.register_tool(session, ElixosHost.Tools.Candidate) do
      Enum.reduce_while(OhMyJido.Tools.default(), :ok, fn module, :ok ->
        if module.name() in ["read", "edit"] do
          {:cont, :ok}
        else
          case OhMyJido.unregister_tool(session, module.name()) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      end)
    end
  end

  defp restore_session(session) do
    if session in OhMyJido.list_sessions(session.runtime),
      do: {:ok, session},
      else: OhMyJido.resume_session(session.runtime, session.id)
  end

  defp loaded_workload do
    case :code.is_loaded(@workload) do
      false -> :not_loaded
      _ -> apply(@workload, :module_info, [:md5])
    end
  end

  defp boot_state do
    with {:ok, bytes} <- File.read("/priv/boot.state") do
      values =
        for line <- String.split(bytes, "\n", trim: true), into: %{} do
          [key, value] = String.split(line, "=", parts: 2)
          {key, String.to_integer(value)}
        end

      {:ok,
       %{
         current: Map.fetch!(values, "current"),
         last_good: Map.fetch!(values, "last_good"),
         attempts: Map.fetch!(values, "attempts")
       }}
    end
  end

  defp directory(scenario), do: Path.join(@root, Atom.to_string(scenario))
  defp workspace(scenario), do: Path.join(directory(scenario), "project")
  defp session_id(scenario), do: "t10-#{scenario}"
  defp runtime(:healthy), do: ElixosHost.T10.HealthyCoding
  defp runtime(:fallback), do: ElixosHost.T10.FallbackCoding
  defp approvals(:healthy), do: ElixosHost.T10.HealthyApprovals
  defp approvals(:fallback), do: ElixosHost.T10.FallbackApprovals
  defp drivers(:healthy), do: ElixosHost.T10.HealthyDrivers
  defp drivers(:fallback), do: ElixosHost.T10.FallbackDrivers
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
