defmodule OhMyJido.NativeV3PrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.AgentServer
  alias Jido.AgentServer.PrivateDiagnostics
  alias Jido.Signal

  defmodule Work do
    use Jido.Action, name: "native_v3_private_work"

    @impl true
    def run(input, context) do
      if owner = input[:owner], do: send(owner, {:private_work_attempt, self(), input[:mode]})

      case input[:mode] do
        :gate ->
          receive do
            :release -> success(context)
          end

        :return ->
          {:error,
           Jido.Action.Error.execution_error(input.secret, %{
             code: :private_fixture_failure,
             status: 401,
             retry: true,
             private_context: context,
             private_payload: input.secret
           })}

        :raise ->
          raise ArgumentError, input.secret

        :throw ->
          throw({:private_fixture_failure, input.secret})

        :exit ->
          exit({:private_fixture_failure, input.secret})

        :directive ->
          {:ok, context.agent_state, [input.directive]}

        _ ->
          success(context)
      end
    end

    defp success(context),
      do: {:ok, %{context.agent_state | count: context.agent_state.count + 1}}
  end

  defmodule WorkFlow do
    use Jido.Flow, name: "native_v3_private_flow"

    flow do
      step("work", action: Work, params: input())
      output(result("work"))
    end
  end

  defmodule PublicAgent do
    use Jido.Agent, name: "native_v3_public_agent"

    agent do
      schema(
        Zoi.object(%{
          count: Zoi.integer() |> Zoi.default(0),
          secret: Zoi.string() |> Zoi.default("")
        })
      )
    end

    routes do
      route("privacy.work", Work)
      route("privacy.flow", WorkFlow)
    end
  end

  defmodule PrivateAgent do
    use Jido.Agent, name: "native_v3_private_agent"

    agent do
      schema(
        Zoi.object(%{
          count: Zoi.integer() |> Zoi.default(0),
          secret: Zoi.string() |> Zoi.default("")
        })
      )
    end

    routes do
      route("privacy.work", Work)
      route("privacy.flow", WorkFlow)
    end

    def private_diagnostics?, do: true
  end

  setup do
    start_supervised!({Jido, name: __MODULE__.Engine})
    :ok
  end

  test "native diagnostic version and bounded error projection retain machine-readable failures" do
    assert AgentServer.private_diagnostics_version() == 1
    assert PrivateDiagnostics.enabled?(PrivateAgent)
    refute PrivateDiagnostics.enabled?(PublicAgent)

    safe = {:request_transformer, :credential_service_failed}
    assert PrivateDiagnostics.error(safe) == safe

    assert PrivateDiagnostics.error(%{code: :provider_error, status: 401}) == %{
             code: :provider_error,
             status: 401
           }

    wrapped = Jido.Action.Error.execution_error("opaque native message", %{reason: safe})
    assert PrivateDiagnostics.error(wrapped).details.reason == safe

    secret = "synthetic-native-v3-error-payload"

    error =
      Jido.Action.Error.execution_error(secret, %{
        code: :private_fixture_failure,
        status: 401,
        retry: true,
        input: secret
      })

    projected = PrivateDiagnostics.error(error)
    assert %Jido.Action.Error.ExecutionFailureError{} = projected
    assert projected.details == %{code: :private_fixture_failure, status: 401, retry: true}
    assert Jido.Action.Error.retryable?(projected)
    refute contains?(projected, secret)

    assert {:persistence_failed, %Jido.Action.Error.ExecutionFailureError{}} =
             PrivateDiagnostics.error({:persistence_failed, error})

    stack = [{__MODULE__, :private_callback, [secret], [file: secret, line: 1]}]
    refute contains?(PrivateDiagnostics.error(stack), secret)
    result = {:ok, %{approved_output: secret}, []}
    assert PrivateDiagnostics.result(result) == result
  end

  test "nested exception structs cannot interrupt private error projection or native stop policies" do
    secret = "synthetic-native-v3-nested-exception"
    exception = %RuntimeError{message: secret}

    for reason <- [
          {:emit_dispatch_failed, exception},
          %{reason: exception},
          [exception]
        ] do
      assert %Jido.Error.ExecutionError{details: %{retry: false}} =
               projected = PrivateDiagnostics.error(reason)

      refute contains?(projected, secret)
    end

    error = Jido.Action.Error.execution_error(secret, %{reason: :dispatch_failed, retry: false})

    for tag <- [:agent_error, :max_agent_errors] do
      assert {:shutdown, {^tag, %Jido.Action.Error.ExecutionFailureError{} = projected}} =
               PrivateDiagnostics.error({:shutdown, {tag, error}})

      assert projected.details == %{reason: :dispatch_failed, retry: false}
      refute contains?(projected, secret)
    end
  end

  test "gen_statem format_status covers native data, events, queues, timeouts and stop reasons" do
    secret = "synthetic-native-v3-status-payload"

    private = %Jido.AgentServer.State{
      config: %{},
      plugin_specs: [],
      postponed_tokens: MapSet.new(),
      active: nil,
      agent: PrivateAgent.new!(id: "private-format", state: %{secret: secret}),
      state_version: 7,
      error_count: 2
    }

    status = %{
      state: :running,
      data: private,
      queue: [{:cast, %{secret: secret}}],
      postponed: [{:call, %{secret: secret}}],
      timeouts: [{:state_timeout, secret}],
      log: [secret],
      reason: {:private_failure, secret},
      future_diagnostic_field: secret
    }

    projected = AgentServer.format_status(status)
    assert Enum.sort(Map.keys(projected)) == Enum.sort(Map.keys(status))
    assert projected.state == :running
    assert projected.data.agent_id == "private-format"
    assert projected.data.state_version == 7
    refute contains?(projected, secret)

    public = %{private | agent: PublicAgent.new!(id: "public-format", state: %{secret: secret})}
    public_status = %{status | data: public}
    assert AgentServer.format_status(public_status) == public_status
  end

  test "live OTP status excludes private state, active input, context and valid W3C tracestate" do
    state_secret = "synthetic-native-v3-state-payload"
    input_secret = "synthetic-native-v3-input-payload"
    context_secret = "synthetic-native-v3-context-payload"
    trace_secret = "synthetic-native-v3-trace-payload"
    server = start_agent(PrivateAgent, "private-gated", state_secret)

    signal =
      traced_signal(
        "privacy.work",
        %{mode: :gate, owner: self(), secret: input_secret},
        trace_secret
      )

    task =
      Task.async(fn ->
        AgentServer.call(server, signal,
          context: %{private_context: context_secret},
          timeout: 5_000
        )
      end)

    assert_receive {:private_work_attempt, action, :gate}, 1_000
    status = :sys.get_status(server)

    for secret <- [state_secret, input_secret, context_secret, trace_secret] do
      refute contains?(status, secret)
    end

    assert AgentServer.agent(server).state.secret == state_secret
    assert %{phase: :running} = AgentServer.status(server)
    send(action, :release)
    assert {:ok, agent} = Task.await(task, 5_000)
    assert agent.state.count == 1
    assert agent.state.secret == state_secret
  end

  test "native Action and Flow failures stay real, execute once and emit only private diagnostics" do
    observe_native_events()
    server = start_agent(PrivateAgent, "private-failures", "synthetic-preserved-state")

    for type <- ["privacy.work", "privacy.flow"], mode <- [:return, :raise, :throw, :exit] do
      secret = "synthetic-native-v3-#{mode}-#{type}-payload"
      signal = traced_signal(type, %{mode: mode, owner: self(), secret: secret}, secret)

      log =
        capture_log(fn ->
          assert {:error, error} =
                   AgentServer.call(server, signal, context: %{private_context: secret})

          assert_receive {:private_work_attempt, _worker, ^mode}, 1_000
          refute_receive {:private_work_attempt, _worker, ^mode}, 0
          refute contains?(error, secret)
          assert AgentServer.agent(server).state.count == 0

          events = events_until_settled(signal.id)

          expected_event =
            if type == "privacy.work",
              do: [:jido, :action, :error],
              else: [:jido, :flow, :target, :error]

          assert Enum.any?(events, fn {event, _, _} -> event == expected_event end)
          refute contains?(events, secret)

          if mode == :return do
            assert error.details.code == :private_fixture_failure
            assert error.details.status == 401
          end
        end)

      refute log =~ secret
    end
  end

  test "private callback crashes stop with a real bounded failure and no OTP payload report" do
    secret = "synthetic-native-v3-invalid-callback-message"

    server =
      start_agent(PrivateAgent, "private-callback-crash", "synthetic-native-v3-crash-state")

    monitor = Process.monitor(server)

    log =
      capture_log(fn ->
        assert {:error, :private_callback_failed} =
                 AgentServer.adopt_child(server, self(), :privacy, secret)

        assert_receive {:DOWN, ^monitor, :process, ^server,
                        {:shutdown, :private_callback_failed}},
                       1_000
      end)

    assert log =~ "Private AgentServer callback failed"
    refute log =~ secret
    refute log =~ "synthetic-native-v3-crash-state"
  end

  test "native supervisor child specifications keep private startup arguments opaque" do
    secret = "synthetic-native-v3-supervisor-argument"

    private =
      AgentServer.child_spec(
        agent: PrivateAgent.new!(id: "private-child-spec", state: %{secret: secret})
      )

    public =
      AgentServer.child_spec(
        agent: PublicAgent.new!(id: "public-child-spec", state: %{secret: secret})
      )

    refute inspect(private, limit: :infinity, printable_limit: :infinity) =~ secret
    assert inspect(public, limit: :infinity, printable_limit: :infinity) =~ secret
  end

  test "native child creation inherits private diagnostics and retains them after parent loss" do
    observe_native_events()
    secret = "synthetic-native-v3-inherited-state"
    parent = start_agent(PrivateAgent, "private-parent", "parent-state")
    child_id = "private-native-child"

    directive =
      Jido.Agent.Directive.spawn_child(PublicAgent, :private_child,
        opts: %{id: child_id, initial_state: %{secret: secret}, on_parent_death: :continue},
        restart: :temporary
      )

    assert {:ok, _agent} =
             AgentServer.call(
               parent,
               Signal.new!("privacy.work", %{mode: :directive, directive: directive},
                 source: "/privacy"
               )
             )

    assert_receive {:native_event, [:jido, :agent, :lifecycle, :stop], _,
                    %{agent_id: ^child_id, operation: :activate, status: :ok}},
                   1_000

    child = AgentServer.whereis(Jido.registry_name(__MODULE__.Engine), child_id)
    assert is_pid(child)
    refute contains?(:sys.get_status(child), secret)

    assert :ok = AgentServer.stop(parent)

    assert {:ok, _agent} =
             AgentServer.call(child, Signal.new!("privacy.work", %{}, source: "/privacy"))

    assert AgentServer.status(child).runtime.parent == nil
    assert AgentServer.agent(child).state.secret == secret
    refute contains?(:sys.get_status(child), secret)
  end

  def record_event(event, measurements, metadata, owner),
    do: send(owner, {:native_event, event, measurements, metadata})

  defp observe_native_events do
    id = {__MODULE__, make_ref()}

    events = [
      [:jido, :action, :start],
      [:jido, :action, :stop],
      [:jido, :action, :error],
      [:jido, :flow, :start],
      [:jido, :flow, :stop],
      [:jido, :flow, :error],
      [:jido, :flow, :target, :start],
      [:jido, :flow, :target, :stop],
      [:jido, :flow, :target, :error],
      [:jido, :agent, :lifecycle, :stop],
      [:jido, :agent, :turn, :settled]
    ]

    assert :ok = :telemetry.attach_many(id, events, &__MODULE__.record_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp events_until_settled(signal_id, events \\ []) do
    receive do
      {:native_event, [:jido, :agent, :turn, :settled] = event, measurements,
       %{signal_id: ^signal_id} = metadata} ->
        [{event, measurements, metadata} | events]

      {:native_event, event, measurements, metadata} ->
        events_until_settled(signal_id, [{event, measurements, metadata} | events])
    after
      1_000 -> flunk("native turn did not emit its terminal summary")
    end
  end

  defp start_agent(module, id, secret) do
    server =
      start_supervised!(
        {AgentServer,
         agent: module,
         id: id,
         jido: __MODULE__.Engine,
         initial_state: %{secret: secret},
         restart: :temporary},
        id: make_ref()
      )

    assert :ok = AgentServer.await_ready(server)
    server
  end

  defp traced_signal(type, data, secret) do
    signal = Signal.new!(type, data, source: "/privacy")

    {:ok, signal} =
      Jido.Tracing.Trace.put(signal, %{
        trace_id: "00000000000000000000000000000001",
        span_id: "0000000000000001",
        tracestate: "omj=" <> secret
      })

    signal
  end

  defp contains?(value, secret),
    do: :binary.match(:erlang.term_to_binary(value), secret) != :nomatch
end
