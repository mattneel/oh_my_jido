defmodule ElixosHost.GuestContractTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  test "an ordinary host cannot start guest effects or claim post-reboot acceptance" do
    expected = {:error, :requires_normal_no_nic_guest_without_health_or_recovery_overrides}
    assert ElixosHost.T10.stage(:healthy) == expected
    assert ElixosHost.T10.stage(:fallback) == expected
    assert ElixosHost.T10.verify(:healthy) == expected
    assert ElixosHost.T10.verify(:fallback) == expected
    refute Process.whereis(ElixosHost.T10.HealthyCoding)
    refute Process.whereis(ElixosHost.T10.FallbackCoding)
  end

  test "missing immutable factory identity is never replaced by a host fixture", %{tmp_dir: root} do
    assert ElixosHost.FactoryReceipt.verify(root) == {:error, :enoent}
  end
end
