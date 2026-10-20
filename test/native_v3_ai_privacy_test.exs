defmodule OhMyJido.NativeV3AIPrivacyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.AI.Execution.RequestTransform
  alias Jido.AI.Execution.State
  alias Jido.AI.Orchestration
  alias Jido.AI.Request
  alias Jido.AI.Test.MockLLM

  defmodule DeclaredTool do
    use Jido.Action, name: "declared_tool", schema: Zoi.object(%{})
    def run(_, _), do: {:ok, %{text: "public tool output"}}
  end

  defmodule UnknownTool do
    use Jido.Action, name: "unknown_tool", schema: Zoi.object(%{})
    def run(_, _), do: {:ok, %{}}
  end

  defmodule FailingTool do
    use Jido.Action, name: "private_failing_tool"

    def run(_, context) do
      case context.failure do
        :return -> {:error, {:opaque_tool_failure, context.opaque}}
        :raise -> raise ArgumentError, context.opaque
        :throw -> throw({:opaque_tool_failure, context.opaque})
        :exit -> exit({:opaque_tool_failure, context.opaque})
        :function_clause -> public_only(context.opaque)
      end
    end

    defp public_only(:public), do: {:ok, %{}}
  end

  defmodule TelemetryProbe do
    use Jido.Action, name: "telemetry_probe"

    def run(_, context) do
      Jido.AI.Observe.emit(
        %{},
        [:jido, :ai, :tool, :execute, :stop],
        %{duration_ms: 1},
        %{
          tool_name: "telemetry_probe",
          params: %{unlabelled: context.opaque},
          tool_result: {:ok, context.opaque, []},
          error_reason: context.opaque,
          custom_payload: context.opaque
        }
      )

      {:ok, %{text: "Useful public tool value"}}
    end
  end

  defmodule NarrowingTransformer do
    def transform_request(_request, _state, _config, context),
      do: {:ok, %{tools: context.selected_tools}}
  end

  defmodule FailingTransformer do
    def transform_request(request, _state, _config, context) do
      probe = context.privacy_probe
      send(probe.owner, {:native_transformer, self()})

      receive do
        :release -> fail(probe.failure, probe.payload, request)
      end
    end

    defp fail({:task, failure}, payload, _request) do
      {:ok, callback} =
        Jido.AI.Validation.validate_and_wrap_callback(
          fn argument -> fail(failure, argument, nil) end,
          task_supervisor: payload.callback_supervisor,
          timeout: 1_000
        )

      callback.(payload)
    end

    defp fail(:return, payload, _), do: {:error, {:opaque_callback_failure, payload}}
    defp fail(:invalid_return, payload, _), do: {:invalid_result, payload}
    defp fail(:raise, payload, _), do: raise(ArgumentError, inspect(payload))
    defp fail(:throw, payload, _), do: throw({:opaque_callback_failure, payload})
    defp fail(:exit, payload, _), do: exit({:opaque_callback_failure, payload})
    defp fail(:function_clause, payload, _), do: accept_public_atom(payload)
    defp fail(:success, _payload, request), do: {:ok, request}
    defp accept_public_atom(:public), do: :ok
  end

  defmodule PrivateAgent do
    use Jido.AI.Agent, name: "native_ai_private_fixture"

    agent do
      schema(Zoi.object(%{answer: Zoi.any() |> Zoi.default(nil)}))

      ai :assistant do
        model("openai:gpt-4o-mini")
        reasoning(:react, request_transformer: FailingTransformer)

        tools do
          action(DeclaredTool, forward_context: :none)
        end

        controls do
          timeout(10_000)
        end

        result(into: :answer)
      end
    end

    routes do
      route("privacy.ask", ai: :assistant)
    end

    def private_diagnostics?, do: true
  end

  defmodule PublicAgent do
    use Jido.AI.Agent, name: "native_ai_public_fixture"

    agent do
      schema(Zoi.object(%{answer: Zoi.any() |> Zoi.default(nil)}))

      ai :assistant do
        model("openai:gpt-4o-mini")
        reasoning(:react, request_transformer: FailingTransformer)
        result(into: :answer)
      end
    end

    routes do
      route("privacy.ask", ai: :assistant)
    end
  end

  test "per-turn narrowing reuses declared tool authority and execution metadata" do
    {state, request, context} = transform_fixture()
    [declared] = state.profile.tools

    for selected <- [%{"declared_tool" => DeclaredTool}, [DeclaredTool], DeclaredTool] do
      assert {:ok, _request, [^declared]} =
               RequestTransform.prepare(
                 state,
                 request,
                 Map.put(context, :selected_tools, selected)
               )
    end

    assert {:ok, _request, []} =
             RequestTransform.prepare(state, request, Map.put(context, :selected_tools, %{}))
  end

  test "per-turn transformers cannot add, replace, or rename declared tool targets" do
    {state, request, context} = transform_fixture()

    for selected <- [
          %{"declared_tool" => UnknownTool},
          %{"unknown_tool" => UnknownTool},
          %{"renamed_tool" => DeclaredTool},
          [UnknownTool],
          UnknownTool
        ] do
      assert {:error, _reason} =
               RequestTransform.prepare(
                 state,
                 request,
                 Map.put(context, :selected_tools, selected)
               )
    end
  end

  test "native request resources and opaque callback failures never enter diagnostics or committed state" do
    start_supervised!({Jido, name: __MODULE__.Engine})
    observe_failures()
    callback_supervisor = start_supervised!({Task.Supervisor, []})

    failures = [
      :return,
      :invalid_return,
      :raise,
      :throw,
      :exit,
      :function_clause,
      {:task, :raise},
      {:task, :throw},
      {:task, :exit},
      {:task, :function_clause}
    ]

    for failure <- failures do
      secret = "synthetic-native-ai-#{inspect(failure)}-private-value"
      {:ok, server} = Jido.start_agent(__MODULE__.Engine, PrivateAgent.new!())

      payload = %{
        unlabelled: secret,
        nested: {secret, self()},
        callback_supervisor: callback_supervisor
      }

      probe = %{owner: self(), failure: failure, payload: payload}

      log =
        capture_log(fn ->
          assert {:ok, request} =
                   PrivateAgent.ask(server, "Exercise native callback containment",
                     stream: false,
                     stream_to: self(),
                     tool_context: %{privacy_probe: probe},
                     llm_opts: [api_key: secret]
                   )

          assert_receive {:native_transformer, worker}, 2_000
          children = AgentServer.children(server)
          coordinator = children[{:plugin, Jido.AI.Orchestration.Plugin}].pid
          delivery = :sys.get_state(coordinator).delivery

          for pid <- [server, coordinator, delivery] do
            refute contains_secret?(:sys.get_status(pid), secret)
          end

          pending = AgentServer.agent(server)
          refute contains_secret?(pending, secret)
          send(worker, :release)
          assert {:error, reason} = Request.await(request, timeout: 5_000)
          refute contains_secret?(reason, secret)

          assert {:ok, records} = AgentServer.plugin_state(server, Jido.AI.Orchestration.Plugin)
          assert records[request.id].status == :failed
          refute contains_secret?(records, secret)
          refute contains_secret?(AgentServer.snapshot(server), secret)
          assert {:ok, checkpoint} = Jido.Agent.checkpoint(AgentServer.agent(server), %{})
          refute contains_secret?(checkpoint, secret)
          assert {:ok, snapshot} = Orchestration.snapshot(server, include_content: true)
          refute contains_secret?(snapshot, secret)

          events =
            request |> Request.Stream.events(stream_event_timeout_ms: 1_000) |> Enum.to_list()

          assert Enum.any?(events, &(&1.kind == :request_failed))
          refute contains_secret?(events, secret)
          telemetry = drain_telemetry()

          assert Enum.any?(telemetry, fn {event, _, _} ->
                   event == [:jido, :ai, :request, :failed]
                 end)

          refute contains_secret?(telemetry, secret)
        end)

      refute log =~ secret
      :ok = Jido.stop_agent(__MODULE__.Engine, server)
    end
  end

  test "an existing public AI Coordinator inherits adoption privacy without a later downgrade" do
    start_supervised!({Jido, name: __MODULE__.Engine})
    {:ok, parent} = Jido.start_agent(__MODULE__.Engine, PrivateAgent.new!())

    {:ok, child} =
      Jido.start_agent(__MODULE__.Engine, PublicAgent.new!(), on_parent_death: :continue)

    coordinator = AgentServer.children(child)[{:plugin, Jido.AI.Orchestration.Plugin}].pid
    delivery = :sys.get_state(coordinator).delivery
    refute :sys.get_state(coordinator).private_diagnostics?
    assert :ok = AgentServer.adopt_child(parent, child, :private_ai)

    for iteration <- 1..2 do
      secret = "synthetic-adopted-native-ai-private-#{iteration}"
      probe = %{owner: self(), failure: :raise, payload: %{unlabelled: secret}}

      log =
        capture_log(fn ->
          {:ok, request} =
            PublicAgent.ask(child, "Exercise inherited native AI privacy",
              stream: false,
              context: %{jido_ai_private_diagnostics: false},
              tool_context: %{privacy_probe: probe},
              llm_opts: [api_key: secret]
            )

          assert_receive {:native_transformer, worker}, 2_000

          assert AgentServer.children(child)[{:plugin, Jido.AI.Orchestration.Plugin}].pid ==
                   coordinator

          assert :sys.get_state(coordinator).private_diagnostics?
          assert :sys.get_state(delivery).private_diagnostics?

          for pid <- [child, coordinator, delivery] do
            refute contains_secret?(:sys.get_status(pid), secret)
          end

          send(worker, :release)
          assert {:error, reason} = Request.await(request, timeout: 5_000)
          refute contains_secret?(reason, secret)
          refute contains_secret?(AgentServer.agent(child), secret)
        end)

      refute log =~ secret
      if iteration == 1, do: assert(:ok == AgentServer.stop(parent))
    end
  end

  test "successful public and tool text is preserved by the opt-in native diagnostics boundary" do
    start_supervised!({Jido, name: __MODULE__.Engine})

    mock =
      start_supervised!(
        {MockLLM,
         script: [
           %{reply: {:tools, [%{id: "public-tool-call", name: "declared_tool", arguments: %{}}]}},
           %{reply: {:text, "Useful public answer"}}
         ]}
      )

    {:ok, server} = Jido.start_agent(__MODULE__.Engine, PrivateAgent.new!())
    probe = %{owner: self(), failure: :success, payload: %{unlabelled: "private-host-resource"}}

    {:ok, request} =
      PrivateAgent.ask(server, "Return useful public text",
        stream: false,
        tool_context: %{privacy_probe: probe},
        llm_opts: MockLLM.options(mock)
      )

    assert_receive {:native_transformer, worker}, 2_000
    send(worker, :release)
    assert_receive {:native_transformer, next_worker}, 2_000
    send(next_worker, :release)
    assert {:ok, "Useful public answer"} = Request.await(request, timeout: 5_000)
    assert AgentServer.agent(server).state.answer == "Useful public answer"
    refute contains_secret?(AgentServer.agent(server), "private-host-resource")
    report = MockLLM.report(mock)
    assert report.unexpected == []
    assert [_initial_request, final_request] = report.requests
    assert contains_secret?(final_request, "public tool output")
  end

  test "native tool exceptions and returned failures are private before AI exception logs" do
    observe_failures()

    for failure <- [:return, :raise, :throw, :exit, :function_clause] do
      secret = "synthetic-native-tool-#{failure}-opaque-value"
      context = %{agent_module: PrivateAgent, failure: failure, opaque: secret}

      log =
        capture_log(fn ->
          assert {:error, reason, []} =
                   Jido.AI.Tools.Executor.execute_module(FailingTool, %{}, context)

          refute contains_secret?(reason, secret)
          telemetry = drain_telemetry()
          assert Enum.any?(telemetry, fn {event, _, _} -> event == [:jido, :action, :error] end)
          refute contains_secret?(telemetry, secret)
        end)

      refute log =~ secret
    end
  end

  test "private telemetry retains lifecycle fields without opaque tool payloads or changing success" do
    observe_failures()
    event = [:jido, :ai, :tool, :execute, :stop]
    secret = "synthetic-native-tool-telemetry-value"

    for module <- [PrivateAgent, PublicAgent] do
      context = %{agent_module: module, opaque: secret}
      options = Jido.AI.PrivateDiagnostics.exec_options(context)

      assert {:ok, %{text: "Useful public tool value"}} =
               Jido.Exec.run(TelemetryProbe, %{}, context, options)

      assert [{^event, %{duration_ms: 1}, metadata}] =
               Enum.filter(drain_telemetry(), fn {observed, _, _} -> observed == event end)

      assert metadata.tool_name == "telemetry_probe"

      if module == PrivateAgent do
        refute contains_secret?(metadata, secret)
        refute Map.has_key?(metadata, :tool_result)
        refute Map.has_key?(metadata, :params)
        refute Map.has_key?(metadata, :error_reason)
      else
        assert contains_secret?(metadata, secret)
        assert Map.has_key?(metadata, :tool_result)
      end
    end
  end

  test "ordinary native agents retain their callback failure details" do
    start_supervised!({Jido, name: __MODULE__.Engine})
    {:ok, server} = Jido.start_agent(__MODULE__.Engine, PublicAgent.new!())
    detail = "ordinary-native-callback-diagnostic"
    probe = %{owner: self(), failure: :return, payload: %{unlabelled: detail}}

    {:ok, request} =
      PublicAgent.ask(server, "Ordinary native failure",
        stream: false,
        tool_context: %{privacy_probe: probe}
      )

    assert_receive {:native_transformer, worker}, 2_000
    send(worker, :release)
    assert {:error, reason} = Request.await(request, timeout: 5_000)
    assert contains_secret?(reason, detail)
  end

  defp transform_fixture do
    {:ok, profile} =
      Jido.AI.Profile.new(%{
        id: :assistant,
        model: "openai:gpt-4o-mini",
        reasoning: %{method: :react, request_transformer: NarrowingTransformer},
        result: %{into: :answer},
        tools: [
          %{
            name: "declared_tool",
            target: DeclaredTool,
            forward_context: :none,
            timeout: 1_234,
            max_retries: 2,
            retry_backoff: 73,
            idempotency: :unsafe_once,
            approval: %{capability: :read},
            metadata: %{effect: :read, declared: true}
          }
        ]
      })

    {:ok, profile} = Jido.AI.Profile.resolve_controls(profile)
    model = Jido.AI.Models.resolve("openai:gpt-4o-mini")
    messages = ReqLLM.Context.new([ReqLLM.Context.user("Narrow the declared catalog")])

    {:ok, state} =
      State.new(%{
        profile: profile,
        model: model,
        messages: messages,
        options: [],
        output: nil,
        streaming: false,
        request_id: "authority-request",
        run_id: "authority-run",
        effect_plan: Jido.AI.Effects.Candidate.new(%{answer: nil}),
        deadline: System.monotonic_time(:millisecond) + profile.controls.timeout,
        history_delta: []
      })

    context = %{
      jido_ai_agent: PublicAgent.new!(id: "authority-agent"),
      jido_ai_tool_defaults: %{forward_context: :all, timeout: 5_000, max_retries: 0}
    }

    {state, %{model: model, messages: messages, options: [], schema: nil, stream: false}, context}
  end

  defp observe_failures do
    events = [
      [:jido, :action, :error],
      [:jido, :flow, :error],
      [:jido, :flow, :node, :error],
      [:jido, :ai, :tool, :execute, :stop],
      [:jido, :ai, :request, :failed]
    ]

    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        events,
        fn event, measurements, metadata, owner ->
          send(owner, {:native_ai_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp drain_telemetry do
    receive do
      {:native_ai_telemetry, event, measurements, metadata} ->
        [{event, measurements, metadata} | drain_telemetry()]
    after
      0 -> []
    end
  end

  defp contains_secret?(value, secret),
    do: :binary.match(:erlang.term_to_binary(value), secret) != :nomatch
end
