defmodule OhMyJido.GoalWorkflowTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.{Event, Runtime}

  @moduletag timeout: 20_000

  setup do
    root = Path.join(System.tmp_dir!(), "omj-goal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      {Runtime,
       name: __MODULE__.Host,
       allow_test_scripts: true,
       storage: {Jido.Persistence.File, path: Path.join(root, ".store")},
       tools: [OhMyJido.Tools.Goal, OhMyJido.Tools.Shell, OhMyJido.Tools.Read]}
    )

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: root,
               permissions: [:planning, :exec, :read]
             )

    %{root: root, session: session}
  end

  test "only explicit completion consumes a successful Shell receipt, not a native task answer",
       %{
         root: root,
         session: session
       } do
    File.write!(Path.join(root, "repaired.txt"), "expected")
    set_goal(session)
    put_plan(session, :done)
    assert :ok = OhMyJido.subscribe(session, self())

    assert {:ok, %{exit_status: 0, status: :exited, effect: :completed, stdout: "verified"}} =
             shell(session, "test \"$(cat repaired.txt)\" = expected && printf verified")

    receipt = shell_receipt(session)
    assert receipt.status == :completed

    script =
      expect_react do
        user("Report the finished task")
        answer("The task is finished and the check passed.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, "Report the finished task", react_opts(script))
    assert {:ok, %{status: :completed, tools: []}} = OhMyJido.await(session, run, timeout: 5_000)
    assert Enum.any?(OhMyJido.events(session), &(&1.kind == :run_completed))
    refute Enum.any?(OhMyJido.events(session), &(&1.kind == :goal_completed))

    assert {:ok, %{status: :completed}} =
             goal(session, %{operation: "complete", effect_ids: [receipt.id]})

    assert_receive {:oh_my_jido,
                    %Event{
                      kind: :goal_completed,
                      payload: %{
                        goal: "Repair the public boundary",
                        evidence: %{
                          checks: [%{effect_id: effect_id, status: :verified, exit_status: 0}]
                        }
                      }
                    }}

    assert effect_id == receipt.id
    assert File.read!(Path.join(root, "repaired.txt")) == "expected"
    assert {:ok, %{plan: [%{id: "repair", status: :done}]}} = OhMyJido.inspect_session(session)
  end

  test "an incomplete plan rejects even an actual successful verification receipt", %{
    session: session
  } do
    set_goal(session)
    put_plan(session, :pending)
    assert {:ok, %{exit_status: 0}} = shell(session, "printf checked")
    receipt = shell_receipt(session)

    assert_rejected(
      goal(session, %{operation: "complete", effect_ids: [receipt.id]}),
      :unfinished_plan
    )

    assert {:ok, %{plan: [%{id: "repair", status: :pending}]}} = OhMyJido.inspect_session(session)
    assert_no_completion(session)
  end

  test "missing, invented and non-Shell evidence cannot authorize goal completion", %{
    root: root,
    session: session
  } do
    set_goal(session)
    put_plan(session, :done)
    File.write!(Path.join(root, "inspection.txt"), "observed, not a check")
    assert {:ok, _read} = OhMyJido.execute_tool(session, "read", %{path: "inspection.txt"})
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    [%{id: read_id}] = Enum.filter(Map.values(effects), &(&1.name == "read"))

    assert {:error, :verification_required} =
             OhMyJido.complete_goal(session, %{checks: [%{status: :verified, exit_status: 0}]})

    assert_rejected(
      goal(session, %{operation: "complete", effect_ids: []}),
      :verification_required
    )

    for id <- ["never-executed", read_id] do
      assert_rejected(
        goal(session, %{operation: "complete", effect_ids: [id]}),
        :unverified_effect
      )
    end

    assert_no_completion(session)
  end

  test "failed and nonzero Shell outcomes do not become verified checks", %{session: session} do
    set_goal(session)
    put_plan(session, :done)

    assert {:error, _reason} =
             OhMyJido.execute_tool(session, "shell", %{
               executable: "omj-no-such-check-executable",
               args: []
             })

    failed = shell_receipt(session)
    assert failed.status == :completed
    assert {:error, _reason} = failed.result

    assert_rejected(
      goal(session, %{operation: "complete", effect_ids: [failed.id]}),
      :verification_failed
    )

    assert {:ok, %{exit_status: 9, effect: :completed, stdout: "check failed"}} =
             shell(session, "printf 'check failed'; exit 9")

    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)

    nonzero =
      Enum.find(Map.values(effects), fn
        %{name: "shell", result: {:ok, %{exit_status: 9}}} -> true
        _effect -> false
      end)

    assert %{status: :completed} = nonzero

    assert_rejected(
      goal(session, %{operation: "complete", effect_ids: [nonzero.id]}),
      :verification_failed
    )

    assert_no_completion(session)
  end

  test "a timed-out Shell keeps its real effect but cannot complete a goal across restore", %{
    root: root,
    session: session
  } do
    set_goal(session)
    put_plan(session, :done)

    assert {:ok, %{status: :timed_out, effect: :uncertain}} =
             shell(session, "printf 'executed once\\n' >> uncertain.txt; sleep 30")

    assert File.read!(Path.join(root, "uncertain.txt")) == "executed once\n"
    receipt = shell_receipt(session)
    assert receipt.status == :uncertain

    assert_rejected(
      goal(session, %{operation: "complete", effect_ids: [receipt.id]}),
      :unverified_effect
    )

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)

    assert_rejected(
      goal(session, %{operation: "complete", effect_ids: [receipt.id]}),
      :unverified_effect
    )

    assert shell_receipt(session).id == receipt.id
    assert shell_receipt(session).status == :uncertain
    assert File.read!(Path.join(root, "uncertain.txt")) == "executed once\n"
    assert_no_completion(session)
  end

  test "public plan updates cannot rename, reopen or discard completed work", %{session: session} do
    set_goal(session)
    put_plan(session, :done)

    for items <- [
          [],
          [%{id: "repair", title: "A different task", status: :done}],
          [%{id: "repair", title: "Repair the boundary", status: :pending}]
        ] do
      assert_rejected(
        goal(session, %{operation: "plan", items: items}),
        :plan_would_discard_completed_or_required_work
      )
    end

    assert {:ok, %{plan: [%{id: "repair", title: "Repair the boundary", status: :done}]}} =
             goal(session, %{operation: "inspect"})

    assert_no_completion(session)
  end

  defp set_goal(session) do
    assert {:ok, %{goal: "Repair the public boundary"}} =
             goal(session, %{operation: "set", goal: "Repair the public boundary"})
  end

  defp put_plan(session, status) do
    assert {:ok, %{status: :updated}} =
             goal(session, %{
               operation: "plan",
               items: [%{id: "repair", title: "Repair the boundary", status: status}]
             })
  end

  defp goal(session, params), do: OhMyJido.execute_tool(session, "goal", params)

  defp shell(session, command) do
    OhMyJido.execute_tool(
      session,
      "shell",
      %{executable: "sh", args: ["-c", command], timeout_ms: 1_000},
      timeout: 3_000
    )
  end

  defp shell_receipt(session) do
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert [receipt] = Enum.filter(Map.values(effects), &(&1.name == "shell"))
    receipt
  end

  defp assert_rejected({:error, %{details: %{reason: actual}}}, expected),
    do: assert(actual == expected)

  defp assert_no_completion(session),
    do: refute(Enum.any?(OhMyJido.events(session), &(&1.kind == :goal_completed)))
end
