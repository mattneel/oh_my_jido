defmodule OhMyJido.EffectDurabilityTest do
  use Jido.AI.TestCase, async: false

  alias Jido.Action.Error.ExecutionFailureError
  alias OhMyJido.{ContextPolicy, Persistence, Runtime, Session}

  @moduletag timeout: 30_000
  @moduletag capture_log: true

  defmodule FaultingStorage do
    @behaviour Jido.Storage

    @impl true
    def get_checkpoint(key, opts), do: Jido.Storage.File.get_checkpoint(key, opts)

    @impl true
    def delete_checkpoint(key, opts), do: Jido.Storage.File.delete_checkpoint(key, opts)

    @impl true
    def load_thread(id, opts), do: Jido.Storage.File.load_thread(id, opts)

    @impl true
    def append_thread(id, entries, opts),
      do: Jido.Storage.File.append_thread(id, entries, opts)

    @impl true
    def delete_thread(id, opts), do: Jido.Storage.File.delete_thread(id, opts)

    @impl true
    def put_checkpoint(key, checkpoint, opts) do
      phase = Keyword.fetch!(opts, :fault_phase)

      if reject?(phase, checkpoint) do
        previous = Jido.Storage.File.get_checkpoint(key, opts)
        send(Keyword.fetch!(opts, :observer), {:storage_rejected, phase, checkpoint, previous})
        {:error, :deliberate_storage_eio}
      else
        Jido.Storage.File.put_checkpoint(key, checkpoint, opts)
      end
    end

    defp reject?(:retention, checkpoint) do
      checkpoint
      |> get_in([:context_policy, "retained", "memory"])
      |> Map.keys()
      |> Enum.any?(&String.starts_with?(&1, "experiment:"))
    end

    defp reject?(:notification, checkpoint),
      do: Enum.any?(checkpoint.events, &(&1.kind == :experiment_completed))

    defp reject?({:effect, id}, checkpoint),
      do: match?(%{status: :completed}, Map.get(checkpoint.effects, id))
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "omj-effect-durability-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for {phase, reason} <- [
        retention: :experiment_retention_failed,
        notification: :experiment_notification_failed
      ] do
    @fault_phase phase
    @recording_reason reason

    test "storage failure during Experiment #{phase} preserves every native result and receipt",
         %{
           root: root
         } do
      session = session(root, @fault_phase)

      outcome =
        OhMyJido.execute_tool(
          session,
          "experiment",
          %{
            trials: [
              shell_trial("printf 'first\\n' >> trials.txt; printf first-result"),
              shell_trial("printf 'second\\n' >> trials.txt; printf second-result")
            ],
            timeout: 10_000
          },
          effect_id: "outer-experiment"
        )

      assert {:error,
              %{
                reason: :effect_recording_failed,
                cause: cause,
                effect: :uncertain,
                effect_id: "outer-experiment",
                result: {:error, %ExecutionFailureError{details: details}}
              }} = outcome

      assert cause in [:session_unavailable, :coordinator_failed]
      assert details.reason == @recording_reason

      assert %{
               id: experiment_id,
               status: :completed,
               effect: :completed,
               results: [first, second]
             } = details.experiment

      assert_receive {:storage_rejected, @fault_phase, rejected, {:ok, previous}}
      canonical = details.experiment |> Jason.encode!() |> Jason.decode!()

      assert get_in(rejected, [
               :context_policy,
               "retained",
               "memory",
               "experiment:" <> experiment_id
             ]) == canonical

      assert %{status: :running} = previous.effects["outer-experiment"]
      refute Enum.any?(previous.events, &(&1.kind == :experiment_completed))

      for {trial, stdout} <- [{first, "first-result"}, {second, "second-result"}] do
        assert %{status: :completed, effect: :completed, receipt_error: nil} = trial
        assert [:ok, %{stdout: ^stdout, exit_status: 0} = result] = trial.result
        assert %{id: id, name: "shell", status: :completed} = trial.receipt
        assert previous.effects[id].result == {:ok, result}
        assert Map.take(previous.effects[id], Map.keys(trial.receipt)) == trial.receipt
      end

      assert File.read!(Path.join(root, "trials.txt")) == "first\nsecond\n"
    end
  end

  test "a failed terminal receipt returns the exact successful Shell result with uncertain bookkeeping",
       %{root: root} do
    session = session(root, {:effect, "shell-once"})

    assert {:error,
            %{
              reason: :effect_recording_failed,
              effect_id: "shell-once",
              effect: :uncertain,
              result: {:ok, %{stdout: "known-output", exit_status: 0} = result}
            }} =
             OhMyJido.execute_tool(
               session,
               "shell",
               shell_params("printf 'once\\n' >> receipt.txt; printf known-output"),
               effect_id: "shell-once"
             )

    assert_receive {:storage_rejected, {:effect, "shell-once"}, rejected, {:ok, previous}}
    assert rejected.effects["shell-once"].result == {:ok, result}
    assert %{status: :running} = previous.effects["shell-once"]
    refute Map.has_key?(previous.effects["shell-once"], :result)
    assert File.read!(Path.join(root, "receipt.txt")) == "once\n"
  end

  test "credential-like host and native IDs retain their receipts across restore and later native work",
       %{root: root} do
    session = session(root)
    secret = "synthetic-durability-secret"
    assert :ok = Session.register_secrets(session, [secret])

    params = shell_params("printf 'host\\n' >> correlated.txt; printf '#{secret}'")

    assert {:ok, %{stdout: "[REDACTED]"} = host_result} =
             OhMyJido.execute_tool(session, "shell", params, effect_id: "password")

    assert {:ok, host_receipt} = Session.effect_receipt(session, "password")
    assert {:ok, %{effects: original}} = OhMyJido.inspect_session(session)
    assert original["password"].result == {:ok, host_result}
    assert is_binary(original["password"].arguments_hash)
    restore(session)
    assert {:ok, ^host_receipt} = Session.effect_receipt(session, "password")
    assert {:ok, %{effects: restored}} = OhMyJido.inspect_session(session)
    assert restored == original

    assert {:error, :effect_already_recorded} =
             OhMyJido.execute_tool(session, "shell", params, effect_id: "password")

    native_shell(session, "authorization", "native", "Continue after the host receipt")
    assert {:ok, native_receipt} = Session.effect_receipt(session, "authorization")

    assert {:ok, %{effects: effects, retained: retained, conversation: messages}} =
             OhMyJido.inspect_session(session)

    assert effects["password"] == original["password"]
    assert %{status: :completed} = effects["authorization"]
    assert %{"name" => "shell"} = retained["completed_tools"]["authorization"]
    assert %{"name" => "shell"} = summary_evidence(messages)["authorization"]
    restore(session)
    assert {:ok, ^host_receipt} = Session.effect_receipt(session, "password")
    assert {:ok, ^native_receipt} = Session.effect_receipt(session, "authorization")

    native_shell(session, "client_secret", "after", "Continue after the native receipt")
    assert {:ok, %{effects: final}} = OhMyJido.inspect_session(session)
    assert final["password"] == effects["password"]
    assert final["authorization"] == effects["authorization"]
    assert %{status: :completed} = final["client_secret"]
    assert File.read!(Path.join(root, "correlated.txt")) == "host\nnative\nafter\n"
  end

  test "pending credential-like native IDs survive JSON checkpoints and result reconciliation" do
    assert {:ok, policy} = ContextPolicy.new([])

    call = %{
      role: :assistant,
      content: "",
      tool_calls: [%{id: "password", name: "shell", arguments: %{executable: "sh"}}]
    }

    assert {:ok, pending} = ContextPolicy.compact(policy, [call])
    checkpoint = pending.state |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()
    assert %{"name" => "shell"} = checkpoint["pending_tools"]["password"]

    assert %{"name" => "shell"} =
             summary_evidence(pending.messages, "unresolved_tool_evidence")["password"]

    assert {:ok, restored} = ContextPolicy.restore(checkpoint)

    result = %{role: :tool, tool_call_id: "password", name: "shell", content: "observed once"}
    assert {:ok, completed} = ContextPolicy.compact(restored, [call, result])

    checkpoint =
      completed.state |> ContextPolicy.checkpoint() |> Jason.encode!() |> Jason.decode!()

    assert %{"name" => "shell"} = checkpoint["completed_tools"]["password"]
    assert checkpoint["pending_tools"] == %{}
    assert {:ok, restored} = ContextPolicy.restore(checkpoint)
    assert {:ok, repeated} = ContextPolicy.compact(restored, completed.messages)
    assert repeated.state.completed_tools == completed.state.completed_tools
  end

  test "only explicit correlation dictionaries bypass credential-field interpretation" do
    secret = "synthetic-key-material"

    records = %{
      "password" => %{
        id: "password",
        result: %{password: "must-not-survive", output: secret}
      },
      ("call-" <> secret) => %{id: "call-" <> secret, result: %{"api_key" => "also-secret"}}
    }

    context_checkpoint = %{
      "completed_tools" => records,
      "pending_tools" => records,
      "retained" => %{"memory" => %{"password" => "ordinary-sensitive-field"}}
    }

    cleaned =
      Persistence.clean_session(
        %{
          effects: records,
          runs: records,
          children: records,
          context_policy: context_checkpoint,
          retained: context_checkpoint,
          password: "ordinary-top-level-secret"
        },
        [secret]
      )

    for field <- [:effects, :runs, :children] do
      assert cleaned[field]["password"].id == "password"
      assert cleaned[field]["password"].result == %{password: nil, output: "[REDACTED]"}
      assert cleaned[field]["call-[REDACTED]"].id == "call-[REDACTED]"
      assert cleaned[field]["call-[REDACTED]"].result == %{"api_key" => nil}
      refute Map.has_key?(cleaned[field], "call-" <> secret)
    end

    for field <- [:context_policy, :retained], records <- ["completed_tools", "pending_tools"] do
      assert cleaned[field][records]["password"].id == "password"
      assert cleaned[field][records]["password"].result.password == nil
      assert cleaned[field][records]["call-[REDACTED]"].result == %{"api_key" => nil}
      assert cleaned[field]["retained"]["memory"]["password"] == nil
    end

    assert cleaned.password == nil
    assert Persistence.clean(%{"password" => "ordinary-secret"}, []) == %{"password" => nil}
    refute inspect(cleaned) =~ secret
  end

  defp session(root, fault_phase \\ nil) do
    storage =
      if fault_phase do
        {FaultingStorage,
         path: Path.join(root, ".store"), fault_phase: fault_phase, observer: self()}
      else
        {Jido.Storage.File, path: Path.join(root, ".store")}
      end

    start_supervised!(
      {Runtime,
       name: __MODULE__.Host,
       storage: storage,
       allow_test_scripts: true,
       tools: [OhMyJido.Tools.Shell, OhMyJido.Tools.Experiment]}
    )

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: root,
               permissions: [:exec, :experiments]
             )

    session
  end

  defp restore(session) do
    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
  end

  defp native_shell(session, id, line, query) do
    params = shell_params("printf '#{line}\\n' >> correlated.txt; printf #{line}-result")
    assert {:ok, %{conversation: history}} = OhMyJido.inspect_session(session)

    script =
      expect_react do
        user(query)
        # Native scripts index retained tool-call turns, including prior runs.
        for message <- history,
            Map.get(message, :role) in [:assistant, "assistant"],
            match?([_ | _], Map.get(message, :tool_calls)) do
          call("shell", %{}, id: "consumed-history")
        end

        call("shell", params, id: id)
        answer("The new receipt is complete without replaying previous effects.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, query, react_opts(script))
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run, timeout: 10_000)
  end

  defp summary_evidence(messages, key \\ "completed_tool_evidence") do
    summary =
      Enum.find(messages, fn message ->
        match?(%{oh_my_jido_context_summary: _hash}, Map.get(message, :metadata))
      end)

    [_preamble, json] = String.split(summary.content, "\n", parts: 2)
    Jason.decode!(json)[key]
  end

  defp shell_trial(command), do: %{tool: "shell", params: shell_params(command)}

  defp shell_params(command),
    do: %{executable: "sh", args: ["-c", command], timeout_ms: 5_000}
end
