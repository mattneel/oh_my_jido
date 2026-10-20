defmodule OhMyJido.PluginTest do
  use Jido.AI.TestCase, async: false

  alias Jido.{AgentServer, Signal}
  alias OhMyJido.{Context, Plugin}
  alias OhMyJido.Plugin.Tools, as: BoundTools
  alias OhMyJido.Tools.{Edit, Read}

  defmodule Bindings do
    @behaviour OhMyJido.Plugin.ContextProvider

    def fetch_context(%{agent_module: module, agent_id: id} = identity) do
      {owner, binding} =
        Agent.get(__MODULE__, fn bindings ->
          {bindings.owner, Map.fetch(bindings, {module, id})}
        end)

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
    def run(_params, context) do
      result = %{domain_status: to_string(Application.spec(:oh_my_jido, :vsn))}
      {:ok, Map.merge(Map.get(context, :agent_state, %{}), result)}
    end
  end

  defmodule DomainPlugin do
    use Jido.Plugin

    @impl true
    def state_spec(_opts), do: {:domain, Zoi.integer() |> Zoi.default(0)}

    @impl true
    def reduce(reduction, _opts), do: {:ok, reduction.plugin_state + 1}
  end

  defmodule PlainAgent do
    use Jido.Agent, name: "plugin_plain_agent"

    agent do
      schema(
        Zoi.object(%{
          domain_value: Zoi.integer() |> Zoi.default(42),
          domain_status: Zoi.string() |> Zoi.default("")
        })
      )

      plugin(DomainPlugin)
      plugin(Plugin, config: [bundles: [:read_only, :editing], context_provider: Bindings])
    end

    routes do
      route("oh_my_jido.read", BoundTools.Read)
      route("oh_my_jido.edit", BoundTools.Edit)
      route("domain.status", DomainAction)
    end

    def private_diagnostics?, do: true
  end

  defmodule ModelPolicy do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    @impl true
    def transform_request(request, _state, _config, _context) do
      owner = Agent.get(Bindings, &Map.fetch!(&1, :owner))
      send(owner, {:model_policy, Map.keys(request.tools)})
      {:ok, %{llm_opts: Keyword.put(request.llm_opts, :temperature, 0.0)}}
    end
  end

  defmodule NativeAI do
    use Jido.AI.Agent,
      name: "plugin_native_ai",
      extensions: [OhMyJido.Plugin.AgentExtension]

    agent do
      schema(
        Zoi.object(%{
          answer: Zoi.string() |> Zoi.default(""),
          domain_value: Zoi.integer() |> Zoi.default(42)
        })
      )

      plugin(Plugin, config: [bundles: [:read_only, :editing], context_provider: Bindings])

      ai :assistant do
        model("openai:gpt-4o-mini")
        reasoning(:react, request_transformer: ModelPolicy)

        tools do
          action(DomainAction)
        end

        result(into: :answer)
      end
    end

    routes do
      route("coding.ask", ai: :assistant)
    end

    def private_diagnostics?, do: true

    def before_tool_call(call, context) do
      owner = Agent.get(Bindings, &Map.fetch!(&1, :owner))
      send(owner, {:before_tool, call.name, context.agent_module, context.agent_id})
      {:ok, call}
    end

    def after_tool_call(call, result, _context) do
      owner = Agent.get(Bindings, &Map.fetch!(&1, :owner))
      send(owner, {:after_tool, call.name})
      {:ok, result}
    end
  end

  defmodule ProcessAI do
    use Jido.AI.Agent,
      name: "plugin_native_process_ai",
      extensions: [OhMyJido.Plugin.AgentExtension]

    agent do
      schema(Zoi.object(%{answer: Zoi.string() |> Zoi.default("")}))
      plugin(Plugin, config: [bundles: [:process], context_provider: Bindings])

      ai :assistant do
        model("openai:gpt-4o-mini")
        reasoning(:react)

        observability do
          stream_content(true)
        end

        result(into: :answer)
      end
    end

    routes do
      route("process.ask", ai: :assistant)
    end

    def private_diagnostics?, do: true
  end

  defmodule UnboundAI do
    use Jido.AI.Agent, name: "plugin_unbound_ai"

    agent do
      schema(Zoi.object(%{answer: Zoi.string() |> Zoi.default("")}))
      plugin(Plugin, config: [context_provider: Bindings])

      ai :assistant do
        model("openai:gpt-4o-mini")
        reasoning(:react)

        tools do
          action(Read)
        end

        result(into: :answer)
      end
    end

    routes do
      route("unbound.ask", ai: :assistant)
    end

    def private_diagnostics?, do: true
  end

  defmodule PublicDiagnostics do
    use Jido.Agent, name: "plugin_public_diagnostics"

    agent do
      plugin(Plugin, config: [context_provider: Bindings])
    end

    routes do
      route("oh_my_jido.read", BoundTools.Read)
    end
  end

  defmodule RetryingAI do
    use Jido.AI.Agent, name: "plugin_retrying_ai"

    agent do
      schema(Zoi.object(%{answer: Zoi.string() |> Zoi.default("")}))
      plugin(Plugin, config: [context_provider: Bindings])

      ai :assistant do
        model("openai:gpt-4o-mini")
        reasoning(:react)

        tools do
          action(BoundTools.Read,
            max_retries: 1,
            retry_backoff: 0,
            idempotency: :unsafe_once,
            forward_context: [:plugin_inputs, :agent_id, :agent_module, :jido_ai_tool_identity]
          )
        end

        result(into: :answer)
      end
    end

    routes do
      route("retrying.ask", ai: :assistant)
    end

    def private_diagnostics?, do: true
  end

  defmodule PrivateFailure do
    def fetch_context(_identity), do: raise("private-provider-secret")
  end

  defmodule BrokenProviderAgent do
    use Jido.Agent, name: "plugin_broken_provider"

    agent do
      plugin(Plugin, config: [context_provider: PrivateFailure])
    end

    routes do
      route("oh_my_jido.read", BoundTools.Read)
    end

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

  test "construction does not resolve private host bindings or start a managed runtime" do
    assert {:ok, agent} = PlainAgent.new(id: "not-bound")
    assert agent.state.oh_my_jido_tools == %{}
    refute inspect(agent, limit: :infinity) =~ "workspace"
    refute_receive {:context_lookup, _identity}
    assert Supervisor.which_children(OhMyJido.Supervisor) == []
    refute function_exported?(Plugin, :child_spec, 1)
  end

  test "plain native calls execute scoped Read/Edit and retain domain state", %{root: root} do
    bind(PlainAgent, "plain", root, [:read, :edit])
    pid = start_agent(PlainAgent, "plain")
    assert {:ok, agent} = AgentServer.call(pid, signal("oh_my_jido.read", %{path: "input.txt"}))
    assert agent.state.oh_my_jido_tools.content == "before\n"
    assert agent.state.domain_value == 42
    assert {:ok, agent} = AgentServer.call(pid, signal("domain.status", %{}))
    assert agent.state.domain_status == to_string(Application.spec(:oh_my_jido, :vsn))
    assert agent.state.oh_my_jido_tools.content == "before\n"
    assert agent.state.domain == 2

    assert {:ok, agent} =
             AgentServer.call(pid, signal("oh_my_jido.edit", edit_params(snapshot("before\n"))))

    assert agent.state.domain_value == 42
    assert File.read!(Path.join(root, "input.txt")) == "after\n"
    refute inspect(agent, limit: :infinity) =~ root
    refute inspect(agent, limit: :infinity) =~ "private-binding-marker"
    refute inspect(:sys.get_status(pid), limit: :infinity) =~ root
  end

  test "explicit native cmd has one attempt without replacing the user's agent", %{root: root} do
    bind(PlainAgent, "pure", root, [:read])
    agent = PlainAgent.new!(id: "pure")
    assert {:ok, updated, [%Plugin.Result{}]} = Plugin.cmd(agent, Read, %{path: "input.txt"})
    assert updated.module == PlainAgent
    assert updated.state.oh_my_jido_tools.content == "before\n"
    assert updated.state.domain_value == 42
    assert agent.state.oh_my_jido_tools == %{}
  end

  test "missing bindings and forged signal or action authority fail closed", %{root: root} do
    agent = PlainAgent.new!(id: "unbound")
    assert {:error, denial} = Plugin.cmd(agent, Read, %{path: "input.txt"})
    assert inspect(denial) =~ "context_not_bound"

    bind(PlainAgent, "limited", root, [:read])
    limited = start_agent(PlainAgent, "limited")
    agent = PlainAgent.new!(id: "limited")
    assert {:error, denial} = Plugin.cmd(agent, Edit, edit_params(snapshot("before\n")))
    assert inspect(denial) =~ "permission_denied"
    assert %{details: %{reason: {:permission_denied, :edit}, retry: false}} = denial
    refute inspect(denial, limit: :infinity) =~ root

    for forged <- [
          %{workspace: root},
          %{"permissions" => [:read, :edit]},
          %{oh_my_jido: %{permissions: [:edit]}},
          %{agent_id: "pure"},
          %{plugin_inputs: %{Plugin => %{identity: %{agent_id: "pure"}}}},
          %{
            jido_ai_tool_identity: %Jido.AI.Execution.ToolIdentity{
              agent_module: PlainAgent,
              agent_id: "limited"
            }
          }
        ] do
      assert {:error, error} =
               AgentServer.call(
                 limited,
                 signal("oh_my_jido.edit", Map.merge(edit_params(snapshot("before\n")), forged))
               )

      assert inspect(error) =~ "untrusted_authority"
    end

    assert {:error, {:oh_my_jido_plugin, :native_agent_context_required}} =
             BoundTools.Read.run(%{path: "input.txt"}, %{
               agent_module: PlainAgent,
               agent_id: "limited"
             })

    assert File.read!(Path.join(root, "input.txt")) == "before\n"
  end

  test "native AI identity carrier contains no grants and rejects mismatched identities", %{
    root: root
  } do
    bind(PlainAgent, "native-carrier", root, [:read])
    agent = PlainAgent.new!(id: "native-carrier")

    native_context =
      Jido.AI.Execution.ToolInterception.identity(
        %{request_id: "carrier-request", run_id: "carrier-run"},
        %{jido_ai_agent: agent}
      )

    assert native_context.jido_ai_tool_identity ==
             %Jido.AI.Execution.ToolIdentity{
               agent_module: PlainAgent,
               agent_id: "native-carrier"
             }

    assert {:ok, %{content: "before\n"}} =
             BoundTools.Read.run(%{path: "input.txt"}, native_context)

    assert_receive {:context_lookup,
                    %{agent_module: PlainAgent, agent_id: "native-carrier"} = identity}

    assert map_size(identity) == 2
    refute inspect(native_context, limit: :infinity) =~ root

    for changed <- [%{agent_id: "other"}, %{agent_module: NativeAI}] do
      assert {:error, {:oh_my_jido_plugin, :native_agent_context_required}} =
               BoundTools.Read.run(%{path: "input.txt"}, Map.merge(native_context, changed))
    end

    refute_receive {:context_lookup, _identity}
  end

  test "host bindings isolate native agent modules and workspaces", %{root: root} do
    for name <- ["one", "two"] do
      workspace = Path.join(root, name)
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "input.txt"), name)
      bind(PlainAgent, name, workspace, [:read])
    end

    first = start_agent(PlainAgent, "one")
    second = start_agent(PlainAgent, "two")
    assert {:ok, one} = AgentServer.call(first, signal("oh_my_jido.read", %{path: "input.txt"}))
    assert {:ok, two} = AgentServer.call(second, signal("oh_my_jido.read", %{path: "input.txt"}))
    assert one.state.oh_my_jido_tools.content == "one"
    assert two.state.oh_my_jido_tools.content == "two"
    assert one.state.domain_value == two.state.domain_value

    agent = PlainAgent.new!(id: "one")

    assert {:error, denial} =
             Plugin.cmd(agent, Read, %{path: Path.join([root, "two", "input.txt"])})

    assert inspect(denial) =~ "outside_workspace"
    assert %{details: %{reason: :outside_workspace, retry: false}} = denial
    refute inspect(denial, limit: :infinity) =~ root

    wrong_module = BrokenProviderAgent.new!(id: "one")
    assert {:error, denial} = Plugin.cmd(wrong_module, Read, %{path: "input.txt"})
    assert inspect(denial) =~ "context_provider_failed"
  end

  test "provider tool availability is a ceiling and managed contexts fail explicitly", %{
    root: root
  } do
    context = Context.new!(workspace: root, permissions: [:read, :edit])
    put_binding(PlainAgent, "ceiling", context)
    agent = PlainAgent.new!(id: "ceiling")
    assert {:error, denial} = Plugin.cmd(agent, Edit, edit_params(snapshot("before\n")))
    assert inspect(denial) =~ "tool_not_available_in_host_context"
    assert File.read!(Path.join(root, "input.txt")) == "before\n"

    put_binding(PlainAgent, "ceiling", %{context | coordinator: self()})
    assert {:error, denial} = Plugin.cmd(agent, Read, %{path: "input.txt"})
    assert inspect(denial) =~ "managed_context_requires_runtime"
  end

  test "native static catalogs preserve selected tools and exact unsafe-once execution policy" do
    assert {:ok, catalog} = Plugin.tool_catalog(%{bundles: [:read_only, :editing]})
    assert Enum.any?(catalog, &(&1.name == "read" and &1.target == BoundTools.Read))
    assert Enum.any?(catalog, &(&1.name == "edit" and &1.target == BoundTools.Edit))
    refute Enum.any?(catalog, &(&1.target in [OhMyJido.Tools.Goal, OhMyJido.Tools.Subagent]))

    for tool <- catalog do
      assert tool.max_retries == 0
      assert tool.retry_backoff == 0
      assert tool.idempotency == :unsafe_once

      assert tool.forward_context == [
               :plugin_inputs,
               :agent_id,
               :agent_module,
               :jido_ai_tool_identity
             ]
    end

    profile = Jido.AI.Agent.profile(NativeAI, :assistant)
    assert profile.models.default.model == "openai:gpt-4o-mini"
    assert profile.reasoning.request_transformer == ModelPolicy
    assert Enum.any?(profile.tools, &(&1.target == DomainAction))
    assert Enum.all?(catalog, &(&1 in profile.tools))
    assert {:error, _reason} = Plugin.tool_catalog(%{bundles: [:eval]})
  end

  test "native lowering waits for a concurrently compiled domain tool's public name", %{
    root: root
  } do
    true = Process.register(self(), __MODULE__.CompileOrderOwner)
    tool_path = Path.join(root, "compile_order_tool.ex")
    agent_path = Path.join(root, "compile_order_agent.ex")

    File.write!(tool_path, """
    defmodule OhMyJido.PluginTest.CompileOrderTool do
      use Jido.Action,
        name: "compile_order_tool",
        description: "A separately compiled native domain tool",
        schema: Zoi.object(%{})

      send(OhMyJido.PluginTest.CompileOrderOwner, {:tool_compiler, self()})
      receive do
        :finish_tool -> :ok
      end

      @impl true
      def run(_params, _context), do: {:ok, %{domain: true}}
    end
    """)

    File.write!(agent_path, """
    defmodule OhMyJido.PluginTest.CompileOrderAgent do
      use Jido.AI.Agent,
        name: "plugin_compile_order",
        extensions: [OhMyJido.Plugin.AgentExtension]

      agent do
        schema Zoi.object(%{answer: Zoi.string() |> Zoi.default("")})
        plugin OhMyJido.Plugin, config: [context_provider: OhMyJido.PluginTest.Bindings]

        ai :assistant do
          model "openai:gpt-4o-mini"
          reasoning :react
          tools do
            action OhMyJido.PluginTest.CompileOrderTool
          end
          result into: :answer
        end
      end

      routes do
        route "compile_order.ask", ai: :assistant
      end

      def private_diagnostics?, do: true

      send(OhMyJido.PluginTest.CompileOrderOwner, {:agent_compiler, self()})
      receive do
        :lower_tools -> :ok
      end
    end
    """)

    task = Task.async(fn -> Kernel.ParallelCompiler.compile([tool_path, agent_path]) end)
    assert_receive {:tool_compiler, tool_compiler}, 5_000
    assert_receive {:agent_compiler, agent_compiler}, 5_000

    try do
      send(agent_compiler, :lower_tools)
      reference = task.ref
      refute_receive {^reference, _premature_result}, 100
      send(tool_compiler, :finish_tool)

      assert {:ok, modules, _warnings} = Task.await(task, 10_000)
      assert __MODULE__.CompileOrderAgent in modules
      profile = Jido.AI.Agent.profile(__MODULE__.CompileOrderAgent, :assistant)

      assert Enum.any?(profile.tools, fn tool ->
               tool.name == "compile_order_tool" and
                 tool.target == __MODULE__.CompileOrderTool
             end)

      assert Enum.any?(profile.tools, &(&1.target == BoundTools.Read))
      refute_receive {:context_lookup, _identity}
    after
      send(agent_compiler, :lower_tools)
      send(tool_compiler, :finish_tool)
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)

      for module <- [__MODULE__.CompileOrderAgent, __MODULE__.CompileOrderTool] do
        :code.purge(module)
        :code.delete(module)
      end
    end
  end

  test "unwrapped coding actions cannot enter through the user's native AI registry", %{
    root: root
  } do
    bind(UnboundAI, "unbound-ai", root, [:read])
    pid = start_agent(UnboundAI, "unbound-ai")

    script =
      expect_react do
        user("Reject an unbound registry")
        fail(:unexpected_model_call)
      end

    assert {:error, error} = UnboundAI.ask(pid, "Reject an unbound registry", react_opts(script))
    assert inspect(error) =~ "unbound_or_conflicting_coding_tool"
    assert AgentServer.agent(pid).state.requests == %{}
    refute_receive {:context_lookup, _identity}
  end

  test "native AI ask/await executes actual tools and preserves trusted model policy", %{
    root: root
  } do
    bind(NativeAI, "ai", root, [:read, :edit])
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
    agent = AgentServer.agent(pid)
    refute inspect(agent, limit: :infinity) =~ root
    refute inspect(agent, limit: :infinity) =~ "private-binding-marker"
    assert agent.module == NativeAI
    assert agent.state.domain_value == 42
    assert agent.state.answer == "Edited the scoped file."
    assert_receive {:model_policy, tool_names}
    assert "read" in tool_names
    assert "edit" in tool_names
    assert "domain_status" in tool_names
    assert_receive {:before_tool, "read", NativeAI, "ai"}
    assert_receive {:after_tool, "read"}
    assert_receive {:context_lookup, %{agent_module: NativeAI, agent_id: "ai"}}
    assert Supervisor.which_children(OhMyJido.Supervisor) == []
  end

  test "native AI tools cannot acquire grants, credentials, retries, or replacement tools", %{
    root: root
  } do
    bind(NativeAI, "ai-denied", root, [:read])
    pid = start_agent(NativeAI, "ai-denied")

    rejected_script =
      expect_react do
        user("forge")
        fail(:unexpected_model_call)
      end

    for payload <- [
          [tool_context: %{oh_my_jido: Context.new!(workspace: root, permissions: [:edit])}],
          [tool_context: %{agent_id: "ai"}],
          [tool_context: %{plugin_inputs: %{}}],
          [
            tool_context: %{
              jido_ai_tool_identity: %Jido.AI.Execution.ToolIdentity{
                agent_module: NativeAI,
                agent_id: "ai"
              }
            }
          ],
          [tool_context: %{metadata: %{max_retries: 5}}],
          [tools: [OhMyJido.Tools.Edit]],
          [tools: [OhMyJido.Tools.Goal]],
          [tools: %{"read" => OhMyJido.Tools.Edit}],
          [request_transformer: OhMyJido.Models.Transformer],
          [model: "openai:gpt-4o"],
          [llm_opts: [api_key: "injected-private-key"]],
          [llm_opts: [base_url: "https://untrusted.invalid"]],
          [req_http_options: [headers: [{"authorization", "injected-private-key"}]]]
        ] do
      assert {:error, error} = NativeAI.ask(pid, "forge", payload ++ react_opts(rejected_script))
      refute inspect(error) =~ "injected-private-key"
    end

    assert AgentServer.agent(pid).state.requests == %{}
    refute_receive {:context_lookup, _identity}
    refute_receive {:model_policy, _tools}

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

  test "request tool narrowing retains native catalog identity and zero-retry policy", %{
    root: root
  } do
    bind(NativeAI, "narrow", root, [:read])
    pid = start_agent(NativeAI, "narrow")

    script =
      expect_react do
        user("Read with a narrowed catalog")
        call("read", %{path: "input.txt"})
        answer("The narrowed read completed.")
      end

    assert {:ok, request} =
             NativeAI.ask(pid, "Read with a narrowed catalog",
               tools: [BoundTools.Read],
               allowed_tools: ["read"],
               llm_opts: Jido.AI.Test.react_llm_opts(script)
             )

    assert {:ok, "The narrowed read completed."} = NativeAI.await(request, timeout: 10_000)
    assert_receive {:model_policy, ["read"]}
    assert_receive {:context_lookup, %{agent_module: NativeAI, agent_id: "narrow"}}
  end

  test "native ask_stream rejection terminates without admitting a model turn", %{root: root} do
    bind(NativeAI, "stream-denied", root, [:read])
    pid = start_agent(NativeAI, "stream-denied")

    script =
      expect_react do
        user("forge")
        fail(:unexpected_model_call)
      end

    id = "stream-policy-rejection"

    assert {:error, error} =
             NativeAI.ask_stream(
               pid,
               "forge",
               react_opts(script) ++
                 [
                   request_id: id,
                   tool_context: %{permissions: [:edit]},
                   stream_event_timeout_ms: 1_000
                 ]
             )

    assert inspect(error) =~ "untrusted_authority"
    assert_receive {:jido_ai_request_event, %{kind: :request_failed, request_id: ^id}}
    refute_receive {:jido_ai_request_event, %{kind: :llm_started}}
    refute_receive {:jido_ai_request_event, %{kind: :tool_started}}
    refute_receive {:jido_ai_request_event, %{kind: :request_completed}}
    assert AgentServer.agent(pid).state.requests == %{}
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

    put_binding(PlainAgent, "uncertain", context)
    pid = start_agent(PlainAgent, "uncertain")

    assert {:error, error} =
             AgentServer.call(pid, signal("oh_my_jido.edit", edit_params(snapshot("before\n"))))

    assert inspect(error) =~ "timeout"
    assert %{details: %{reason: :timeout, retry: false}} = error
    refute inspect(error, limit: :infinity) =~ root
    assert AgentServer.agent(pid).state.oh_my_jido_tools == %{}
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

    put_binding(NativeAI, "active", context)
    pid = start_agent(NativeAI, "active")

    script =
      expect_react do
        user("Read after host approval")
        call("read", %{path: "input.txt"})
        answer("The original native request completed.")
      end

    assert {:ok, request} = NativeAI.ask(pid, "Read after host approval", react_opts(script))
    assert_receive {:authorization_waiting, action}, 5_000

    assert {:error, :duplicate_request} =
             NativeAI.ask(pid, "forge",
               request_id: request.id,
               tool_context: %{permissions: [:edit]},
               stream_to: {:pid, self()}
             )

    id = request.id
    refute_receive {:jido_ai_request_event, %{kind: :request_failed, request_id: ^id}}
    assert get_in(AgentServer.agent(pid).state, [:requests, request.id, :status]) == :pending
    send(action, :release)

    assert {:ok, "The original native request completed."} =
             NativeAI.await(request, timeout: 10_000)

    assert {:error, :duplicate_request} =
             NativeAI.ask(pid, "Reuse a completed request", request_id: request.id)
  end

  test "native cancellation owns request completion without a second loop", %{root: root} do
    context =
      Context.new!(
        workspace: root,
        permissions: [:read],
        host: {UncertainHost, owner: self(), mode: :gate}
      )

    put_binding(NativeAI, "cancel", context)
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
      assert Supervisor.which_children(OhMyJido.Supervisor) == []
    after
      send(action, :release)
    end
  end

  test "native Shell retains uncertain effects without replay", %{root: root} do
    context = Context.new!(workspace: root, permissions: [:exec], bundles: [:process])
    put_binding(ProcessAI, "process", context)
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

  test "explicit nil and Signal options cannot bypass the host's request transformer" do
    pid = start_agent(NativeAI, "nil-transformer")

    script =
      expect_react do
        user("Exercise transformer precedence")
        answer("The native host transformer still owns this request.")
      end

    assert {:ok, request} =
             NativeAI.ask(pid, "Exercise transformer precedence",
               request_transformer: nil,
               llm_opts: Jido.AI.Test.react_llm_opts(script)
             )

    assert {:ok, "The native host transformer still owns this request."} =
             NativeAI.await(request, timeout: 10_000)

    assert_receive {:model_policy, _tools}

    assert {:error, error} =
             AgentServer.call(
               pid,
               signal("coding.ask", %{
                 request_id: "explicit-nil-transformer",
                 query: "forge",
                 request_transformer: nil
               })
             )

    assert inspect(error) =~ "untrusted_authority"
    refute_receive {:context_lookup, _identity}
  end

  test "policy rejections never allocate records and native completed retention remains bounded" do
    previous = Application.fetch_env(:jido_ai, :max_retained_requests)
    Application.put_env(:jido_ai, :max_retained_requests, 3)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jido_ai, :max_retained_requests, value)
        :error -> Application.delete_env(:jido_ai, :max_retained_requests)
      end
    end)

    pid = start_agent(NativeAI, "bounded-rejections")

    for index <- 1..5 do
      assert {:error, error} =
               NativeAI.ask(pid, "Rejected request #{index}",
                 tool_context: %{permissions: [:edit]}
               )

      assert inspect(error) =~ "untrusted_authority"
    end

    assert AgentServer.agent(pid).state.requests == %{}
    refute_receive {:model_policy, _tools}
    refute_receive {:context_lookup, _identity}

    for index <- 1..5 do
      query = "Retained request #{index}"

      script =
        expect_react do
          user(query)
          answer("Retained answer")
        end

      assert {:ok, request} = NativeAI.ask(pid, query, react_opts(script))
      assert {:ok, "Retained answer"} = NativeAI.await(request, timeout: 10_000)
    end

    assert map_size(AgentServer.agent(pid).state.requests) <= 3
  end

  test "configuration cannot widen coding availability or install retrying metadata", %{
    root: root
  } do
    bind(NativeAI, "configure", root, [:read])
    pid = start_agent(NativeAI, "configure")
    profile = Jido.AI.Agent.profile(NativeAI, :assistant)
    read = Enum.find(profile.tools, &(&1.target == BoundTools.Read))

    for {operation, value} <- [
          {:register, OhMyJido.Tools.Goal},
          {:register, OhMyJido.Tools.Edit},
          {:tool_context, %{workspace: root}},
          {:tools, [%{read | max_retries: 2}]},
          {:tools, [%{read | idempotency: :idempotent}]},
          {:tools, [%{read | forward_context: :all}]},
          {:tools, [%{read | metadata: %{retry: true}}]},
          {:tools, [%{read | metadata: %{api_key: "injected-private-key"}}]}
        ] do
      assert {:error, _reason} =
               AgentServer.call(
                 pid,
                 signal("jido.ai.configure", %{
                   profile_id: :assistant,
                   operation: operation,
                   value: value
                 })
               )
    end

    assert File.read!(Path.join(root, "input.txt")) == "before\n"
    refute_receive {:context_lookup, _identity}
  end

  test "setup requirements and provider failures are actionable without private errors" do
    assert {:error, {:oh_my_jido_plugin, :context_provider_required}} = Plugin.normalize(%{})

    public = PublicDiagnostics.new!(id: "public")
    assert {:error, error} = Plugin.cmd(public, Read, %{path: "input.txt"})
    assert inspect(error) =~ "private_diagnostics_required"

    retrying = start_agent(RetryingAI, "retrying")
    assert {:error, error} = RetryingAI.ask(retrying, "No automatic tool retries")
    assert inspect(error) =~ "unsafe_retry_metadata"

    agent = BrokenProviderAgent.new!(id: "broken")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, error} = Plugin.cmd(agent, Read, %{path: "input.txt"})
        assert inspect(error) =~ "context_provider_failed"
        refute inspect(error) =~ "private-provider-secret"
      end)

    refute log =~ "private-provider-secret"
  end

  defp bind(module, id, root, permissions) do
    context =
      Context.new!(
        workspace: root,
        permissions: permissions,
        bundles: [:read_only, :editing],
        metadata: %{private_note: "private-binding-marker"}
      )

    put_binding(module, id, context)
  end

  defp put_binding(module, id, context),
    do: Agent.update(Bindings, &Map.put(&1, {module, id}, context))

  defp start_agent(module, id) do
    {:ok, pid} = Jido.start_agent(__MODULE__.Engine, module, id: id)
    pid
  end

  defp signal(type, data), do: Signal.new!(type, data, source: "/host")

  defp edit_params(sha),
    do: %{path: "input.txt", snapshot: sha, edits: [%{old: "before", new: "after"}]}

  defp snapshot(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
