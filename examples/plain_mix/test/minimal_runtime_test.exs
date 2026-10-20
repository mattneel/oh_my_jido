defmodule PlainMixHost.MinimalRuntimeTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "minimal runtime reads source without inherited model configuration or credentials", %{
    tmp_dir: workspace
  } do
    source = "defmodule ConsumerFixture, do: def(value, do: 41)\n"
    File.write!(Path.join(workspace, "sample.ex"), source)
    runtime = PlainMixHost.MinimalCoding
    start_supervised!({OhMyJido, name: runtime})

    assert {:ok, session} =
             OhMyJido.start_session(runtime,
               workspace: workspace,
               bundles: :read_only,
               permissions: [:read]
             )

    assert {:ok, %{content: ^source}} =
             OhMyJido.execute_tool(session, "read", %{path: "sample.ex"})

    assert :ok = OhMyJido.stop_session(session)
  end
end
