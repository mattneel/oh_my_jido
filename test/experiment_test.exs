defmodule OhMyJido.ExperimentTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Runtime

  defmodule FaultAfterWrite do
    use Jido.Action,
      name: "experiment_fault_after_write",
      description: "Fail after an authorized observable filesystem effect",
      schema:
        Zoi.object(%{
          path: Zoi.string(),
          outcome: Zoi.enum(["error", "raise"])
        })

    def capability, do: :edit

    @impl true
    def run(params, execution_context) do
      with {:ok, context} <- OhMyJido.Context.fetch(execution_context),
           :ok <- OhMyJido.Tool.authorize(context, :edit, %{path: params.path}),
           {:ok, path} <- OhMyJido.Workspace.resolve(context, params.path),
           :ok <- File.write(path, params.outcome <> "\n", [:append]) do
        case params.outcome do
          "error" -> {:error, %{reason: :trial_rejected, artifact: params.path}}
          "raise" -> raise ArgumentError, "trial raised after writing its artifact"
        end
      end
    end
  end

  @moduletag timeout: 20_000

  setup do
    root = Path.join(System.tmp_dir!(), "omj-experiment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @tag :experiment_retention_regression
  test "retention rejection returns every executed trial without replaying filesystem effects", %{
    root: root
  } do
    session = session(root, context_policy: [max_retained_bytes: 512])

    assert :ok =
             OhMyJido.retain(session, %{memory: %{"operator-note" => "must survive rejection"}})

    trials = [
      shell_trial("printf 'first\\n' >> trials.txt; printf first-result"),
      shell_trial("printf 'second\\n' >> trials.txt; printf second-result")
    ]

    outcome =
      try do
        OhMyJido.experiment(session, trials)
      rescue
        error -> {:raised, error}
      end

    assert File.read!(Path.join(root, "trials.txt")) == "first\nsecond\n"

    assert {:ok, %{effects: effects, retained: retained, status: :idle}} =
             OhMyJido.inspect_session(session)

    receipts = effects_named(effects, "shell")
    assert [%{status: :completed}, %{status: :completed}] = receipts
    assert retained["retained"]["memory"] == %{"operator-note" => "must survive rejection"}

    assert {:error,
            %{
              reason: :experiment_retention_failed,
              cause: :retained_context_too_large,
              effect: :completed,
              experiment: %{id: id, status: :completed, results: results}
            }} = outcome

    assert is_binary(id)
    assert [%{result: [:ok, first]}, %{result: [:ok, second]}] = results
    assert first.stdout == "first-result"
    assert second.stdout == "second-result"
    assert first.exit_status == 0
    assert second.exit_status == 0

    for trial <- results do
      assert is_integer(trial.duration_us) and trial.duration_us >= 0
      assert trial.status == :completed
      assert %{id: effect_id, status: :completed, name: "shell"} = trial.receipt
      assert effects[effect_id].result == {:ok, Enum.at(trial.result, 1)}
    end

    refute Enum.any?(OhMyJido.events(session), &(&1.kind == :experiment_completed))
    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, %{effects: restored}} = OhMyJido.inspect_session(session)
    assert Map.keys(restored) |> Enum.sort() == Map.keys(effects) |> Enum.sort()
    assert File.read!(Path.join(root, "trials.txt")) == "first\nsecond\n"
  end

  test "the public Experiment Action retains measured results and exact Shell receipts", %{
    root: root
  } do
    session = session(root, max_experiment_trials: 2)

    assert {:ok, %{status: :completed, results: results} = record} =
             OhMyJido.execute_tool(session, "experiment", %{
               trials: [
                 shell_trial("printf 'first\n' >> measured.txt; printf first"),
                 shell_trial("printf 'second\n' >> measured.txt; printf second")
               ]
             })

    assert File.read!(Path.join(root, "measured.txt")) == "first\nsecond\n"
    assert [%{result: [:ok, %{stdout: "first"}]}, %{result: [:ok, %{stdout: "second"}]}] = results
    assert {:ok, %{effects: effects, retained: retained}} = OhMyJido.inspect_session(session)
    assert [_, _] = effects_named(effects, "shell")

    for trial <- results do
      assert %{id: id, status: :completed, name: "shell", arguments_hash: hash} = trial.receipt
      assert effects[id].arguments_hash == hash
      assert effects[id].result == {:ok, Enum.at(trial.result, 1)}
      assert trial.duration_us >= 0
    end

    canonical = record |> Jason.encode!() |> Jason.decode!()
    assert retained["retained"]["memory"]["experiment:" <> record.id] == canonical

    assert [%{payload: %{id: id, status: :completed}}] =
             Enum.filter(OhMyJido.events(session), &(&1.kind == :experiment_completed))

    assert id == record.id

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)

    assert {:ok, %{retained: restored, effects: restored_effects}} =
             OhMyJido.inspect_session(session)

    assert restored["retained"]["memory"]["experiment:" <> record.id] == canonical
    assert [_, _] = effects_named(restored_effects, "shell")
    assert File.read!(Path.join(root, "measured.txt")) == "first\nsecond\n"
  end

  test "excessive or malformed public trials are rejected before any trial effects", %{root: root} do
    session = session(root, max_experiment_trials: 2)
    trial = shell_trial("printf 'must not run' >> excessive.txt")

    for trials <- [[], [trial, trial, trial], [%{tool: "shell"}], :not_trials] do
      assert {:error, :invalid_or_excessive_trials} =
               OhMyJido.experiment(session, trials, timeout: 2_000)
    end

    assert {:error, %{details: %{reason: :invalid_or_excessive_trials}}} =
             OhMyJido.execute_tool(session, "experiment", %{trials: [trial, trial, trial]})

    refute File.exists?(Path.join(root, "excessive.txt"))
    assert {:ok, %{effects: effects, retained: retained}} = OhMyJido.inspect_session(session)
    assert effects_named(effects, "shell") == []
    assert retained["retained"]["memory"] == %{}
    refute Enum.any?(OhMyJido.events(session), &(&1.kind == :experiment_completed))
  end

  test "native error and exception trials preserve their actual artifacts without retries", %{
    root: root
  } do
    session = session(root, max_experiment_trials: 3)
    File.write!(Path.join(root, "failures.txt"), "")

    trials = [
      %{tool: FaultAfterWrite.name(), params: %{path: "failures.txt", outcome: "error"}},
      %{tool: FaultAfterWrite.name(), params: %{path: "failures.txt", outcome: "raise"}},
      shell_trial("printf observed-after-errors")
    ]

    assert {:ok, %{status: :failed, results: [rejected, raised, observed]} = record} =
             OhMyJido.execute_tool(session, "experiment", %{trials: trials})

    assert File.read!(Path.join(root, "failures.txt")) == "error\nraise\n"
    assert %{status: :failed, result: [:error, %{details: %{reason: :trial_rejected}}]} = rejected

    assert %{
             status: :failed,
             result: [
               :error,
               %{details: %{action: FaultAfterWrite, exception: ArgumentError, retry: false}}
             ]
           } = raised

    assert %{status: :completed, result: [:ok, %{stdout: "observed-after-errors"}]} = observed
    assert {:ok, %{effects: effects, retained: retained}} = OhMyJido.inspect_session(session)
    assert [_, _] = effects_named(effects, FaultAfterWrite.name())

    for trial <- [rejected, raised, observed] do
      assert %{id: id, status: :completed} = trial.receipt
      assert is_map(effects[id])
    end

    assert retained["retained"]["memory"]["experiment:" <> record.id]["status"] == "failed"
    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, %{effects: restored}} = OhMyJido.inspect_session(session)
    assert [_, _] = effects_named(restored, FaultAfterWrite.name())
    assert File.read!(Path.join(root, "failures.txt")) == "error\nraise\n"
  end

  @tag :experiment_uncertainty_regression
  test "a public Action recording failure preserves uncertain trial and enclosing effect receipts",
       %{
         root: root
       } do
    session = session(root, context_policy: [max_retained_bytes: 512])

    trial =
      shell_trial("printf 'before-timeout\n' >> uncertain.txt; sleep 30")
      |> put_in([:params, :timeout_ms], 1_000)

    outcome = OhMyJido.execute_tool(session, "experiment", %{trials: [trial]})

    assert File.read!(Path.join(root, "uncertain.txt")) == "before-timeout\n"

    assert {:error,
            %{
              details: %{
                reason: :experiment_retention_failed,
                cause: :retained_context_too_large,
                effect: :uncertain,
                experiment: %{status: :failed, effect: :uncertain, results: [trial]}
              }
            }} = outcome

    assert %{status: :failed, effect: :uncertain, receipt: %{status: :uncertain}} = trial
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert [%{id: trial_id, status: :uncertain}] = effects_named(effects, "shell")
    assert trial_id == trial.receipt.id
    assert [%{status: :uncertain}] = effects_named(effects, "experiment")

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, %{effects: restored}} = OhMyJido.inspect_session(session)
    assert [%{id: ^trial_id, status: :uncertain}] = effects_named(restored, "shell")
    assert [%{status: :uncertain}] = effects_named(restored, "experiment")
    assert File.read!(Path.join(root, "uncertain.txt")) == "before-timeout\n"
  end

  test "a rejected unregistered trial has no invented execution receipt", %{root: root} do
    session = session(root, [])

    assert {:ok,
            %{
              status: :failed,
              effect: :not_started,
              results: [
                %{
                  status: :failed,
                  effect: :not_started,
                  receipt: nil,
                  receipt_error: :effect_not_recorded,
                  result: [:error, [:unknown_tool, "not-registered"]]
                }
              ]
            }} =
             OhMyJido.experiment(session, [%{tool: "not-registered", params: %{}}])

    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert effects == %{}
  end

  test "host effect ID collisions reject replay and leave the original receipt unchanged", %{
    root: root
  } do
    session = session(root, [])
    assert {:error, :effect_not_recorded} = OhMyJido.Session.effect_receipt(session, "unknown")

    for {id, command, expected_status} <- [
          {"completed", "printf 'completed\n' >> correlated.txt", :exited},
          {"uncertain", "printf 'uncertain\n' >> correlated.txt; sleep 30", :timed_out}
        ] do
      trial = shell_trial(command)

      params =
        if expected_status == :timed_out,
          do: Map.put(trial.params, :timeout_ms, 1_000),
          else: trial.params

      assert {:ok, %{status: ^expected_status}} =
               OhMyJido.execute_tool(session, trial.tool, params, effect_id: id)

      assert {:ok, receipt} = OhMyJido.Session.effect_receipt(session, id)

      assert Enum.sort(Map.keys(receipt)) ==
               Enum.sort([:id, :run, :name, :status, :arguments_hash, :started_at, :completed_at])

      assert {:ok, %{effects: before}} = OhMyJido.inspect_session(session)

      assert {:error, :effect_already_recorded} =
               OhMyJido.execute_tool(session, trial.tool, params, effect_id: id)

      assert {:ok, %{effects: after_collision}} = OhMyJido.inspect_session(session)
      assert before == after_collision
      assert {:ok, ^receipt} = OhMyJido.Session.effect_receipt(session, id)
    end

    assert File.read!(Path.join(root, "correlated.txt")) == "completed\nuncertain\n"
  end

  defp session(root, opts) do
    runtime_opts =
      Keyword.merge(
        [
          name: __MODULE__.Host,
          storage: {Jido.Persistence.File, path: Path.join(root, ".store")},
          tools: [OhMyJido.Tools.Shell, OhMyJido.Tools.Experiment, FaultAfterWrite]
        ],
        opts
      )

    start_supervised!({Runtime, runtime_opts})

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: root,
               permissions: [:exec, :experiments, :edit]
             )

    session
  end

  defp shell_trial(command) do
    %{
      tool: "shell",
      params: %{executable: "sh", args: ["-c", command]}
    }
  end

  defp effects_named(effects, name),
    do: effects |> Map.values() |> Enum.filter(&(&1.name == name))
end
