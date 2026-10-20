defmodule OhMyJido.WorkspacePolicyTest do
  use ExUnit.Case, async: false

  alias OhMyJido.{Context, Tool, Workspace}
  alias OhMyJido.Tools.{Read, Write}

  setup do
    base = Path.join(System.tmp_dir!(), "omj-policy-#{System.unique_integer([:positive])}")
    allowed = Path.join(base, "allowed")
    denied = Path.join(base, "denied")
    File.mkdir_p!(allowed)
    File.mkdir_p!(denied)
    File.write!(Path.join(allowed, "file"), "allowed")
    File.write!(Path.join(denied, "file"), "denied")
    original = Application.fetch_env(:jido_action, :file_tool_roots)
    Application.put_env(:jido_action, :file_tool_roots, [allowed])

    on_exit(fn ->
      case original do
        {:ok, roots} -> Application.put_env(:jido_action, :file_tool_roots, roots)
        :error -> Application.delete_env(:jido_action, :file_tool_roots)
      end

      File.rm_rf!(base)
    end)

    %{base: base, allowed: allowed, denied: denied}
  end

  test "an explicit workspace grant never weakens configured Jido file roots", fixture do
    allowed = context(fixture.allowed)
    denied = context(fixture.denied)
    assert {:ok, %{content: "allowed"}} = Tool.execute(allowed, "read", %{path: "file"})
    assert {:error, :outside_workspace} = Workspace.resolve(denied, "file")

    assert {:error, %{details: %{reason: :outside_workspace}}} =
             Tool.execute(denied, "read", %{path: "file"})

    assert {:error, %{details: %{reason: :outside_workspace}}} =
             Tool.execute(denied, "write", %{path: "new", snapshot: "missing", content: "denied"})

    refute File.exists?(Path.join(fixture.denied, "new"))
  end

  test "a broader workspace cannot bypass Jido's context-root intersection policy", fixture do
    broad = context(fixture.base)
    assert {:error, :outside_workspace} = Workspace.resolve(broad, "allowed/file")
    assert File.read!(Path.join(fixture.allowed, "file")) == "allowed"
  end

  test "configured roots are canonical and invalid policies fail closed", fixture do
    alias_path = Path.join(fixture.base, "configured-link")
    File.ln_s!(fixture.allowed, alias_path)
    allowed = context(fixture.allowed)
    Application.put_env(:jido_action, :file_tool_roots, alias_path)
    assert {:ok, _path} = Workspace.resolve(allowed, "file")

    for roots <- [[fixture.allowed, 1], [Path.join(fixture.base, "missing")], :invalid] do
      Application.put_env(:jido_action, :file_tool_roots, roots)
      assert {:error, :outside_workspace} = Workspace.resolve(allowed, "file")
    end
  end

  defp context(root) do
    %Context{
      session_id: "policy-test",
      workspace: root,
      permissions: MapSet.new([:read, :edit]),
      tools: [Read, Write]
    }
  end
end
