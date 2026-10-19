defmodule OhMyJido.ToolsSelectionTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Tools
  alias OhMyJido.Tools.{Edit, Git, Read, Shell, Write}

  test "named bundles expose availability without adding unmanaged execution" do
    assert {:ok, read_only} = Tools.select(:read_only)
    assert Read in read_only
    refute Write in read_only
    refute Shell in read_only

    assert {:ok, selected} =
             Tools.select([:read_only, :editing, :elixir, :process, :live_inspection])

    assert Edit in selected
    assert Git in selected
    assert OhMyJido.Tools.Observer in selected
    refute OhMyJido.Tools.Eval in selected
    assert Enum.all?(selected, &(&1 in Tools.default()))

    assert Enum.sort(Map.keys(Tools.bundles())) ==
             [:editing, :elixir, :live_inspection, :process, :read_only]
  end

  test "composition preserves caller precedence and deduplicates by first occurrence" do
    first = Tools.select!(:editing)
    second = Tools.select!(:read_only)

    assert Tools.select!([:editing, :read_only, :editing]) == first ++ second
    assert Tools.select!([:read_only, :editing, :read_only]) == second ++ first
    assert Tools.select!([]) == []
    assert Tools.select(:read_only) == Tools.select([:read_only])
  end

  test "unknown bundle names and malformed selections fail instead of becoming modules" do
    assert {:error, {:unknown_bundle, :missing_bundle}} = Tools.select(:missing_bundle)
    assert {:error, {:invalid_bundle, "read_only"}} = Tools.select(["read_only"])

    assert {:error, {:invalid_bundle_selection, :expected_atom_or_list}} =
             Tools.select("read_only")

    assert {:error, {:invalid_bundle_selection, :expected_atom_or_list}} =
             Tools.select([:read_only | :editing])

    assert_raise ArgumentError, ~r/unknown_bundle.*missing_bundle/, fn ->
      Tools.select!(:missing_bundle)
    end
  end

  test "unrecognized string names never create atoms" do
    name = "untrusted-bundle-#{System.unique_integer([:positive])}"
    assert {:error, {:invalid_bundle, ^name}} = Tools.select([name])
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
