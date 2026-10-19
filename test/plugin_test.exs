defmodule OhMyJido.PluginTest do
  use Jido.AI.TestCase, async: false

  alias Jido.{AgentServer, Signal}
  alias OhMyJido.{Context, Plugin}
  alias OhMyJido.Tools.{Edit, Read}

  defmodule Bindings do
    @behaviour OhMyJido.Plugin.ContextProvider

    def fetch_context(%{agent_id: id} = identity) do
      {owner, binding} =
        Agent.get(__MODULE__, fn bindings -> {bindings.owner, Map.fetch(bindings, id)} end)

      send(owner, {:context_lookup, identity})

      case binding do
        {:ok, context} -> {:ok, context}
        :error -> {:error, :not_bound}
      end
    end
  end

  defmodule DomainAction do
    use Jido.Action,
      name: "domain_status",
      description: "Reports the host application's installed version",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context) do
      {:ok, %{domain_status: to_string(Application.spec(:oh_my_jido, :vsn))}}
    end
  end

  defmodule DomainPlugin do
    use Jido.Plugin,
      name: "domain",
      state_key: :domain,
      actions: [DomainAction],
      signal_routes: [{"status", DomainAction}]
  end

  defmodule PlainAgent do
    use Jido.Agent,
      name: "plugin_plain_agent",
      default_plugins: false,
      plugins: [
        DomainPlugin,
        {Plugin, %{bundles: [:read_only, :editing], context_provider: Bindings}}
      ],
      schema: Zoi.object(%{domain_value: Zoi.integer() |> Zoi.default(42)})

    def private_diagnostics?, do: true
  end

  defmodule ModelPolicy do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    def transform_request(request, _state, _config, _context) do
      owner = Agent.get(Bindings, &Map.fetch!(&1, :owner))
      send(owner, {:model_policy, Map.keys(request.tools)})
      {:ok, %{llm_opts: Keyword.put(request.llm_opts, :temperature, 0)}}
    end
  end

  defmodule NativeAI do
    use Jido.AI.Agent,
      name: "plugin_native_ai",
      model: "openai:gpt-4o-mini",
      tools: [DomainAction],
      tool_max_retries: 0,
      request_transformer: ModelPolicy,
      plugins: [{Plugin, %{bundles: [:read_only, :editing], context_provider: Bindings}}]

    def private_diagnostics?, do: true
  end

  defmodule ProcessAI do
    use Jido.AI.Agent,
      name: "plugin_native_process_ai",
      model: "openai:gpt-4o-mini",
      tools: [],
      tool_max_retries: 0,
      plugins: [{Plugin, %{bundles: [:process], context_provider: Bindings}}]

    def private_diagnostics?, do: true
  end

  defmodule UnboundAI do
    use Jido.AI.Agent,
      name: "plugin_unbound_ai",
      model: "openai:gpt-4o-mini",
      tools: [Read],
      tool_max_retries: 0,
      plugins: [{Plugin, %{context_provider: Bindings}}]

    def private_diagnostics?, do: true
  end

  defmodule MissingProvider do
    use Jido.Agent,
      name: "plugin_missing_provider",
      default_plugins: false,
      plugins: [Plugin]

    def private_diagnostics?, do: true
  end

  defmodule PublicDiagnostics do
    use Jido.Agent,
      name: "plugin_public_diagnostics",
      default_plugins: false,
      plugins: [{Plugin, %{context_provider: Bindings}}]
  end

  defmodule RetryingAI do
    use Jido.AI.Agent,
      name: "plugin_retrying_ai",
      tools: [],
      plugins: [{Plugin, %{context_provider: Bindings}}]

    def private_diagnostics?, do: true
  end

  defmodule PrivateFailure do
    def fetch_context(_identity), do: raise("private-provider-secret")
  end

  defmodule BrokenProviderAgent do
    use Jido.Agent,
      name: "plugin_broken_provider",
      default_plugins: false,
      plugins: [{Plugin, %{context_provider: PrivateFailure}}]

    def private_diagnostics?, do: true
  end

  defmodule UncertainHost do
    @behaviour OhMyJido.Host

    def authorize(_context, capability, _effect, opts) do
      owner = Keyword.fetch!(opts, :owner)

      if opts[:mode] == :gate do
        send(owner, {:authorization_waiting, self()})

        receive do
          :release -> :ok
        after
          5_000 -> {:error, :timeout}
        end
      else
        send(owner, {:authorized, capability})
        {:error, :timeout}
      end
    end

    def credentials(_context, _account, _opts), do: {:error, :not_available}
    def invoke(_context, _capability, _params, _opts), do: {:error, :not_available}
    def question(_context, _question, _opts), do: {:error, :not_available}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "oh-my-jido-plugin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "input.txt"), "before\n")
    on_exit(fn -> File.rm_rf!(root) end)
    owner = self()

    start_supervised!(%{
      id: Bindings,
      start: {Agent, :start_link, [fn -> %{owner: owner} end, [name: Bindings]]}
    })

    start_supervised!({Jido, name: __MODULE__.Engine})
    %{root: root}
  end

  test "mount does not resolve private host bindings or start a managed runtime" do
    agent = PlainAgent.new(id: "not-bound")
    refute inspect(agent, limit: :infinity) =~ "workspace"
    refute_receive {:context_lookup, _identity}
    assert Supervisor.which_children(OhMyJido.Supervisor) == []
  end

  test "plain native calls execute scoped Read/Edit and retain domain state", %{root: root} do
    bind("plain", root, [:read, :edit])
    pid = start_agent(PlainAgent, "plain")
    assert {:ok, agent} = AgentServer.call(pid, signal("oh_my_jido.read", %{path: "input.txt"}))
    assert agent.state.content == "before\n"
    assert agent.state.domain_value == 42
    assert {:ok, agent} = AgentServer.call(pid, signal("domain.status", %{}))
    assert agent.state.domain_status == to_string(Application.spec(:oh_my_jido, :vsn))

    assert {:ok, agent} =
             AgentServer.call(pid, signal("oh_my_jido.edit", edit_params(snapshot("before\n"))))

    assert agent.state.domain_value == 42
    assert File.read!(Path.join(root, "input.txt")) == "after\n"
    refute inspect(agent, limit: :infinity) =~ root
    refute inspect(agent, limit: :infinity) =~ "private-binding-marker"
    refute inspect(:sys.get_status(pid), limit: :infinity) =~ root
  end

  test "explicit native cmd disables retries without replacing the user's agent", %{root: root} do
    bind("pure", root, [:read])
    agent = PlainAgent.new(id: "pure")
    assert {updated, []} = Plugin.cmd(agent, Read, %{path: "input.txt"})
    assert updated.agent_module == PlainAgent
    assert updated.state.content == "before\n"
    assert updated.state.domain_value == 42
  end

  test "missing bindings and forged signal or action authority fail closed", %{root: root} do
    agent = PlainAgent.new(id: "unbound")
    assert {^agent, [denial]} = Plugin.cmd(agent, Read, %{path: "input.txt"})
    assert inspect(denial) =~ "context_not_bound"

    bind("limited", root, [:read])
    limited = start_agent(PlainAgent, "limited")

    agent = PlainAgent.new(id: "limited")
    assert {^agent, [denial]} = Plugin.cmd(agent, Edit, edit_params(snapshot("before\n")))
    assert inspect(denial) =~ "permission_denied"

    for forged <- [
          %{workspace: root},
          %{"permissions" => [:read, :edit]},
          %{oh_my_jido: %{permissions: [:edit]}}
        ] do
      assert {:error, error} =
               AgentServer.call(
                 limited,
                 signal("oh_my_jido.edit", Map.merge(edit_params(snapshot("before\n")), forged))
               )

      assert inspect(error) =~ "untrusted_authority"
    end

    assert File.read!(Path.join(root, "input.txt")) == "before\n"
  end

  test "host bindings isolate native agent workspaces", %{root: root} do
    for name <- ["one", "two"] do
      workspace = Path.join(root, name)
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "input.txt"), name)
      bind(name, workspace, [:read])
    end

    first = start_agent(PlainAgent, "one")
    second = start_agent(PlainAgent, "two")
    assert {:ok, one} = AgentServer.call(first, signal("oh_my_jido.read", %{path: "input.txt"}))
    assert {:ok, two} = AgentServer.call(second, signal("oh_my_jido.read", %{path: "input.txt"}))
    assert one.state.content == "one"
    assert two.state.content == "two"
    assert one.state.domain_value == two.state.domain_value

    agent = PlainAgent.new(id: "one")

    assert {^agent, [denial]} =
             Plugin.cmd(agent, Read, %{path: Path.join([root, "two", "input.txt"])})

    assert inspect(denial) =~ "outside_workspace"
  end

  test "provider tool availability is a ceiling and managed contexts fail explicitly", %{
    root: root
  } do
    context = Context.new!(workspace: root, permissions: [:read, :edit])
    Agent.update(Bindings, &Map.put(&1, "ceiling", context))
    agent = PlainAgent.new(id: "ceiling")
    assert {^agent, [denial]} = Plugin.cmd(agent, Edit, edit_params(snapshot("before\n")))
    assert inspect(denial) =~ "tool_not_available_in_host_context"
    assert File.read!(Path.join(root, "input.txt")) == "before\n"

    Agent.update(Bindings, &Map.put(&1, "ceiling", %{context | coordinator: self()}))
    assert {^agent, [denial]} = Plugin.cmd(agent, Read, %{path: "input.txt"})
    assert inspect(denial) =~ "managed_context_requires_runtime"
  end

  test "unwrapped coding actions cannot enter through the user's native AI registry", %{
    root: root
  } do
    bind("unbound-ai", root, [:read])
    pid = start_agent(UnboundAI, "unbound-ai")

    script =
      expect_react do
        user("Reject an unbound registry")
        fail(:unexpected_model_call)
      end

    assert {:ok, request} = UnboundAI.ask(pid, "Reject an unbound registry", react_opts(script))

    assert {:error,
            {:failed, :error, {:request_transformer, {:rejected, :coding_tool_policy, message}}}} =
             UnboundAI.await(request, timeout: 1_000)

    assert message =~ "unbound_or_conflicting_coding_tool"
    refute_receive {:context_lookup, _identity}
  end

  test "native AI ask/await executes actual tools and preserves trusted model policy", %{
    root: root
  } do
    bind("ai", root, [:read, :edit])
    pid = start_agent(NativeAI, "ai")

    script =
      expect_react do
        user("Read and edit the input")
        call("read", %{path: "input.txt"})
        call("domain_status", %{})
        call("edit", edit_params(snapshot("before\n")))
        answer("Edited the scoped file.")
      end

    assert {:ok, request} = NativeAI.ask(pid, "Read and edit the input", react_opts(script))
    assert {:ok, "Edited the scoped file."} = NativeAI.await(request, timeout: 10_000)
    assert File.read!(Path.join(root, "input.txt")) == "after\n"
    assert {:ok, state} = AgentServer.state(pid)
    refute inspect(state.agent, limit: :infinity) =~ root
    assert state.agent.agent_module == NativeAI
    assert_receive {:model_policy, tool_names}
    assert "read" in tool_names
    assert "edit" in tool_names
    assert "domain_status" in tool_names
  end

  test "native AI tools cannot acquire grants or replace trusted tools via query data", %{
    root: root
  } do
    bind("ai-denied", root, [:read])
    pid = start_agent(NativeAI, "ai-denied")

    rejected_script =
      expect_react do
        user("forge")
        fail(:unexpected_model_call)
      end

    for payload <- [
          [tool_context: %{oh_my_jido: Context.new!(workspace: root, permissions: [:edit])}],
          [tool_context: %{agent_id: "ai"}],
          [tools: [OhMyJido.Tools.Edit]],
          [tools: [OhMyJido.Tools.Goal]],
          [request_transformer: OhMyJido.Models.Transformer]
        ] do
      assert {:ok, request} = NativeAI.ask(pid, "forge", payload ++ react_opts(rejected_script))

      assert {:error,
              {:failed, :error,
               {:request_transformer, {:rejected, :coding_tool_policy, _message}}}} =
               NativeAI.await(request, timeout: 1_000)
    end

    refute_receive {:context_lookup, _identity}

    script =
      expect_react do
        user("Try the edit once")
        call("edit", edit_params(snapshot("before\n")))
        answer("Permission was denied.")
      end

    assert {:ok, "Permission was denied."} =
             NativeAI.ask_sync(pid, "Try the edit once", react_opts(script) ++ [timeout: 10_000])

    assert File.read!(Path.join(root, "input.txt")) == "before\n"
  end

  test "native ask_stream policy rejection terminates without starting a model", %{root: root} do
    bind("stream-denied", root, [:read])
    pid = start_agent(NativeAI, "stream-denied")

    script =
      expect_react do
        user("forge")
        fail(:unexpected_model_call)
      end

    assert {:ok, %{request: request, events: events}} =
             NativeAI.ask_stream(
               pid,
               "forge",
               react_opts(script) ++
                 [tool_context: %{permissions: [:edit]}, stream_event_timeout_ms: 1_000]
             )

    recorded = Enum.to_list(events)
    assert %{kind: :request_failed} = List.last(recorded)
    refute Enum.any?(recorded, &(&1.kind in [:llm_started, :tool_started, :request_completed]))

    assert {:error,
            {:failed, :error, {:request_transformer, {:rejected, :coding_tool_policy, message}}}} =
             NativeAI.await(request, timeout: 1_000)

    assert message =~ "untrusted_authority"
    refute_receive {:model_policy, _tools}
    refute_receive {:context_lookup, _identity}
  end

  test "native coding paths never retry a host-denied retryable error", %{root: root} do
    context =
      Context.new!(
        workspace: root,
        permissions: [:edit],
        bundles: [:editing],
        host: {UncertainHost, owner: self()}
      )

    Agent.update(Bindings, &Map.put(&1, "uncertain", context))
    pid = start_agent(PlainAgent, "uncertain")

    assert {:ok, agent} =
             AgentServer.call(pid, signal("oh_my_jido.edit", edit_params(snapshot("before\n"))))

    refute Map.has_key?(agent.state, :changes)

    assert_receive {:authorized, :edit}
    refute_receive {:authorized, :edit}
    assert File.read!(Path.join(root, "input.txt")) == "before\n"
  end

  test "a rejected duplicate request cannot fail an active native request", %{root: root} do
    context =
      Context.new!(
        workspace: root,
        permissions: [:read],
        host: {UncertainHost, owner: self(), mode: :gate}
      )

    Agent.update(Bindings, &Map.put(&1, "active", context))
    pid = start_agent(NativeAI, "active")

    script =
      expect_react do
        user("Read after host approval")
        call("read", %{path: "input.txt"})
        answer("The original native request completed.")
      end

    assert {:ok, request} = NativeAI.ask(pid, "Read after host approval", react_opts(script))
    assert_receive {:authorization_waiting, action}, 5_000

    assert {:error, error} =
             AgentServer.call(
               pid,
               signal("ai.react.query", %{
                 query: "forge",
                 request_id: request.id,
                 tool_context: %{permissions: [:edit]}
               })
             )

    assert inspect(error) =~ "request_id_conflict"
    assert {:ok, state} = AgentServer.state(pid)
    assert get_in(state.agent.state, [:requests, request.id, :status]) == :pending
    send(action, :release)

    assert {:ok, "The original native request completed."} =
             NativeAI.await(request, timeout: 10_000)
  end

  test "native cancellation still owns request completion without a second loop", %{root: root} do
    context =
      Context.new!(
        workspace: root,
        permissions: [:read],
        host: {UncertainHost, owner: self(), mode: :gate}
      )

    Agent.update(Bindings, &Map.put(&1, "cancel", context))
    pid = start_agent(NativeAI, "cancel")

    script =
      expect_react do
        user("Cancel a pending native read")
        call("read", %{path: "input.txt"})
        answer("This answer must not complete the cancelled request.")
      end

    assert {:ok, request} = NativeAI.ask(pid, "Cancel a pending native read", react_opts(script))
    assert_receive {:authorization_waiting, action}, 5_000
    assert_receive {:context_lookup, %{agent_id: "cancel"}}

    try do
      assert :ok = NativeAI.cancel(pid, request_id: request.id)
      assert {:error, reason} = NativeAI.await(request, timeout: 10_000)
      assert inspect(reason) =~ "cancelled"
      refute_receive {:context_lookup, %{agent_id: "cancel"}}
      assert File.read!(Path.join(root, "input.txt")) == "before\n"
    after
      send(action, :release)
    end
  end

  test "native Shell retains uncertain effects without replay", %{root: root} do
    context = Context.new!(workspace: root, permissions: [:exec], bundles: [:process])
    Agent.update(Bindings, &Map.put(&1, "process", context))
    pid = start_agent(ProcessAI, "process")

    script =
      expect_react do
        user("Record one uncertain effect")

        call("shell", %{
          executable: "sh",
          args: ["-c", "printf x >> receipt; sleep 30 & wait"],
          timeout_ms: 150
        })

        answer("The command timed out; do not replay its effect.")
      end

    assert {:ok, %{request: request, events: events}} =
             ProcessAI.ask_stream(
               pid,
               "Record one uncertain effect",
               react_opts(script) ++ [stream_event_timeout_ms: 10_000]
             )

    completed = Enum.find(Enum.to_list(events), &(&1.kind == :tool_completed))
    assert completed.data.attempts == 1
    assert {:ok, %{status: :timed_out, effect: :uncertain}, []} = completed.data.result

    assert {:ok, "The command timed out; do not replay its effect."} =
             ProcessAI.await(request, timeout: 10_000)

    assert File.read!(Path.join(root, "receipt")) == "x"
  end

  test "explicit nil cannot bypass the host's request transformer" do
    pid = start_agent(NativeAI, "nil-transformer")

    script =
      expect_react do
        user("Exercise transformer precedence")
        answer("This answer must be rejected")
      end

    id = "explicit-nil-transformer"

    assert :ok =
             AgentServer.cast(
               pid,
               signal("ai.react.query", %{
                 request_id: id,
                 query: "Exercise transformer precedence",
                 request_transformer: nil,
                 llm_opts: Jido.AI.Test.react_llm_opts(script)
               })
             )

    request = Jido.AI.Request.Handle.new(id, pid, "Exercise transformer precedence")
    assert {:error, reason} = NativeAI.await(request, timeout: 1_000)
    assert inspect(reason) =~ "untrusted_request_transformer"
    refute_receive {:model_policy, _tools}
    refute_receive {:context_lookup, _identity}
  end

  test "policy rejections honor the native configured request retention limit" do
    limit = 3

    {:ok, pid} =
      Jido.start_agent(__MODULE__.Engine, NativeAI,
        id: "bounded-rejections",
        initial_state: %{__request_tracking__: %{max_requests: limit}}
      )

    for index <- 1..(limit + 2) do
      {:ok, request} =
        NativeAI.ask(pid, "Rejected request #{index}", tool_context: %{permissions: [:edit]})

      assert {:error, reason} = NativeAI.await(request, timeout: 1_000)
      assert inspect(reason) =~ "untrusted_authority"
    end

    {:ok, state} = AgentServer.state(pid)
    assert map_size(state.agent.state.requests) <= limit
    refute_receive {:model_policy, _tools}
    refute_receive {:context_lookup, _identity}
  end

  test "setup requirements and provider failures are actionable without revealing private errors" do
    assert_raise ArgumentError, ~r/context_provider_required/, fn -> MissingProvider.new() end

    assert_raise ArgumentError, ~r/private_diagnostics_required/, fn ->
      PublicDiagnostics.new()
    end

    assert_raise ArgumentError, ~r/tool_max_retries_must_be_zero/, fn -> RetryingAI.new() end

    agent = BrokenProviderAgent.new(id: "broken")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {updated, [directive]} = Plugin.cmd(agent, Read, %{path: "input.txt"})
        assert updated == agent
        assert inspect(directive) =~ "context_provider_failed"
        refute inspect(directive) =~ "private-provider-secret"
      end)

    refute log =~ "private-provider-secret"
  end

  defp bind(id, root, permissions) do
    context =
      Context.new!(
        workspace: root,
        permissions: permissions,
        bundles: [:read_only, :editing],
        metadata: %{private_note: "private-binding-marker"}
      )

    Agent.update(Bindings, &Map.put(&1, id, context))
  end

  defp start_agent(module, id) do
    {:ok, pid} = Jido.start_agent(__MODULE__.Engine, module, id: id)
    pid
  end

  defp signal(type, data), do: Signal.new!(type, data, source: "/host")

  defp edit_params(sha),
    do: %{path: "input.txt", snapshot: sha, edits: [%{old: "before", new: "after"}]}

  defp snapshot(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
