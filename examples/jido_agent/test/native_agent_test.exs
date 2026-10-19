defmodule JidoAgentHost.NativeAgentTest do
  use Jido.AI.TestCase, async: false

  alias Jido.{AgentServer, Signal}
  alias JidoAgentHost.{Contexts, Editor, Files}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-agent-host-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "counter.ex"), "def increment(n), do: n - 1\n")
    on_exit(fn -> File.rm_rf!(root) end)
    start_supervised!(Contexts)
    start_supervised!({Jido, name: __MODULE__.Engine})
    %{root: root, cwd: File.cwd!(), env: System.get_env("OMJ_NATIVE_PLUGIN_EXAMPLE")}
  end

  test "a caller-defined plain Jido agent uses actual coding actions", fixture do
    assert :ok = bind(Files, "files", fixture.root, [:read, :edit])
    {:ok, pid} = Jido.start_agent(__MODULE__.Engine, Files, id: "files")

    assert {:ok, agent} =
             AgentServer.call(pid, signal("oh_my_jido.read", %{path: "counter.ex"}))

    assert agent.state.content == "def increment(n), do: n - 1\n"
    assert agent.state.project_label == "independent-host"

    assert {:ok, updated} =
             AgentServer.call(pid, signal("oh_my_jido.edit", edits(agent.state.snapshot)))

    assert updated.state.project_label == "independent-host"
    assert File.read!(Path.join(fixture.root, "counter.ex")) == "def increment(n), do: n + 1\n"
    refute inspect(updated, limit: :infinity) =~ fixture.root
    assert_unchanged_host(fixture)
  end

  test "a caller-defined AI agent retains native ask/await and custom tools", fixture do
    assert :ok = bind(Editor, "editor", fixture.root, [:read, :edit])
    {:ok, pid} = Jido.start_agent(__MODULE__.Engine, Editor, id: "editor")
    snapshot = sha256(File.read!(Path.join(fixture.root, "counter.ex")))

    script =
      expect_react do
        user("Fix increment in this workspace")
        call("project_status", %{})
        call("read", %{path: "counter.ex"})
        call("edit", edits(snapshot))
        answer("Fixed increment without a separate coding agent.")
      end

    assert {:ok, request} = Editor.ask(pid, "Fix increment in this workspace", react_opts(script))

    assert {:ok, "Fixed increment without a separate coding agent."} =
             Editor.await(request, timeout: 10_000)

    assert File.read!(Path.join(fixture.root, "counter.ex")) == "def increment(n), do: n + 1\n"
    assert {:ok, state} = AgentServer.state(pid)
    assert state.agent.agent_module == Editor
    refute inspect(state.agent, limit: :infinity) =~ fixture.root
    refute inspect(:sys.get_status(pid), limit: :infinity) =~ fixture.root
    assert_unchanged_host(fixture)
  end

  test "availability never grants authority and a forged query cannot supply it", fixture do
    assert :ok = bind(Editor, "reader", fixture.root, [:read])
    {:ok, pid} = Jido.start_agent(__MODULE__.Engine, Editor, id: "reader")
    original = File.read!(Path.join(fixture.root, "counter.ex"))

    script =
      expect_react do
        user("Try a write without a host grant")
        call("edit", edits(sha256(original)))
        answer("The host did not grant edit permission.")
      end

    assert {:ok, "The host did not grant edit permission."} =
             Editor.ask_sync(
               pid,
               "Try a write without a host grant",
               react_opts(script) ++ [timeout: 10_000]
             )

    assert File.read!(Path.join(fixture.root, "counter.ex")) == original
    assert {:ok, state} = AgentServer.state(pid)
    assert inspect(state.agent, limit: :infinity) =~ "permission_denied"

    forged_context = %{
      agent_id: "editor",
      workspace: fixture.root,
      permissions: [:read, :edit]
    }

    rejected_script =
      expect_react do
        user("Use another binding")
        fail(:unexpected_model_call)
      end

    assert {:ok, request} =
             Editor.ask(
               pid,
               "Use another binding",
               react_opts(rejected_script) ++ [tool_context: forged_context]
             )

    assert {:error,
            {:failed, :error, {:request_transformer, {:rejected, :coding_tool_policy, message}}}} =
             Editor.await(request, timeout: 1_000)

    assert message =~ "untrusted_authority"
    assert File.read!(Path.join(fixture.root, "counter.ex")) == original
    assert_unchanged_host(fixture)
  end

  test "mount does not resolve missing host bindings or start a runtime", fixture do
    plain = Files.new(id: "unbound")
    assert plain.state.oh_my_jido_tools == %{}
    assert {^plain, [directive]} = OhMyJido.Plugin.cmd(plain, "read", %{path: "counter.ex"})
    assert inspect(directive) =~ "context_not_bound"
    assert_unchanged_host(fixture)
  end

  defp bind(module, id, root, grants) do
    Contexts.bind(module, id,
      workspace: root,
      permissions: grants,
      bundles: [:read_only, :editing]
    )
  end

  defp assert_unchanged_host(fixture) do
    assert File.cwd!() == fixture.cwd
    assert System.get_env("OMJ_NATIVE_PLUGIN_EXAMPLE") == fixture.env
    assert Supervisor.which_children(OhMyJido.Supervisor) == []
  end

  defp signal(type, data), do: Signal.new!(type, data, source: "/independent-host")

  defp edits(snapshot) do
    %{path: "counter.ex", snapshot: snapshot, edits: [%{old: "n - 1", new: "n + 1"}]}
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
