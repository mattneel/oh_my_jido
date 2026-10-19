defmodule OhMyJidoGuest.WorkloadTest do
  use ExUnit.Case, async: true
  @moduletag milestone: 0

  test "the repaired userland implementation increments without changing its public label" do
    assert OhMyJidoGuest.Workload.increment(41) == 42
    assert OhMyJidoGuest.Workload.increment(-1) == 0
    assert OhMyJidoGuest.Workload.label() == "oh-my-jido-userland"
  end

  test "healthy boot is successful and the deliberate fallback is only a benign MFA exception" do
    assert OhMyJidoGuest.Workload.boot(:healthy) == :ok
    assert_raise RuntimeError, "T10 human-approved benign userland boot exception", fn ->
      OhMyJidoGuest.Workload.boot(:fallback)
    end
  end
end
