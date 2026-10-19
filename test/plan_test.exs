defmodule OhMyJido.PlanTest do
  use ExUnit.Case, async: true
  alias OhMyJido.Plan

  test "plans preserve every task and terminal completion across updates" do
    {:ok, original} =
      Plan.validate([
        %{id: "fix", title: "Fix the boundary", status: :done},
        %{id: "check", title: "Run the suite", status: :pending}
      ])

    assert {:error, :plan_would_discard_completed_or_required_work} =
             Plan.update(original, [%{id: "fix", title: "Fix the boundary", status: :done}])

    assert {:error, :plan_would_discard_completed_or_required_work} =
             Plan.update(original, [
               %{id: "fix", title: "Fix the boundary", status: :pending},
               %{id: "check", title: "Run the suite", status: :pending}
             ])

    assert {:ok, completed} =
             Plan.update(original, [
               %{id: "fix", title: "Fix the boundary", status: :done},
               %{id: "check", title: "Run the suite", status: :done}
             ])

    assert {:error, :verification_required} = Plan.complete(completed, %{})

    assert {:error, :verification_failed} =
             Plan.complete(completed, %{checks: [%{status: :failed}]})

    assert :ok = Plan.complete(completed, %{checks: [%{status: :verified}]})
  end

  test "duplicate, competing active, and unexplained blocked tasks are rejected" do
    task = %{id: "one", title: "One task", status: :pending}
    assert {:error, :ambiguous_plan} = Plan.validate([task, task])

    assert {:error, :ambiguous_plan} =
             Plan.validate([
               %{task | status: :in_progress},
               %{task | id: "two", status: :in_progress}
             ])

    assert {:error, :blocked_task_requires_reason} = Plan.validate([%{task | status: :blocked}])
  end
end
