defmodule OhMyJido.NativePrivacyTest do
  use ExUnit.Case, async: false

  alias Jido.Agent.Directive
  alias Jido.AgentServer
  alias Jido.Signal
  alias OhMyJido.Auth.Error
  alias OhMyJido.Models.Subscription
  alias ReqLLM.{Context, StreamServer}
  alias ReqLLM.Streaming.{Failure, InProcessClient, WebSocketClient}

  defmodule ForwardDirective do
    use Jido.Action, name: "native_privacy_forward_directive"

    @impl true
    def run(%{directive: directive}, %{agent_state: state}), do: {:ok, state, [directive]}
  end

  defmodule PublicAgent do
    use Jido.Agent, name: "public_directive_privacy_fixture"

    agent do
      schema(Zoi.object(%{}))
    end

    routes do
      route("privacy.directive", ForwardDirective)
    end
  end

  defmodule PrivateAgent do
    use Jido.Agent, name: "private_directive_privacy_fixture"

    agent do
      schema(Zoi.object(%{}))
    end

    routes do
      route("privacy.directive", ForwardDirective)
    end

    def private_diagnostics?, do: true
  end

  defmodule FailingDispatch do
    @behaviour Jido.Signal.Dispatch.Adapter

    @impl true
    def options_schema, do: Zoi.keyword(secret: Zoi.string() |> Zoi.required())

    @impl true
    def deliver(_signal, opts), do: raise(Keyword.fetch!(opts, :secret))
  end

  defmodule AlternateProvider do
    def attach_in_process_stream(_model, _context, opts) do
      case Keyword.fetch!(opts, :scenario) do
        :cancel ->
          owner = Keyword.fetch!(opts, :owner)
          secret = Keyword.fetch!(opts, :secret)
          failure = Keyword.fetch!(opts, :failure)

          stream =
            Stream.resource(
              fn -> :waiting end,
              fn state ->
                send(owner, {:enumeration_waiting, self()})

                receive do
                  :finish -> {:halt, state}
                end
              end,
              fn _state -> :ok end
            )

          cancel = fn ->
            send(owner, {:cancellation_waiting, self()})

            receive do
              :fail -> fail(failure, secret)
            end
          end

          {:ok, ReqLLM.Provider.InProcessStream.new(stream, cancel: cancel)}

        :enumerate ->
          failure = Keyword.fetch!(opts, :failure)
          secret = Keyword.fetch!(opts, :secret)
          {:ok, Stream.map([:step], fn _ -> fail(failure, secret) end)}

        :attach ->
          fail(Keyword.fetch!(opts, :failure), Keyword.fetch!(opts, :secret))
      end
    end

    def attach_websocket_stream(_model, _context, opts) do
      case Keyword.fetch!(opts, :scenario) do
        :websocket_task ->
          {:ok,
           %{
             url: "ws://fixture.invalid/never-contacted",
             headers: [],
             initial_messages: [],
             canonical_json: %{}
           }}

        :attach ->
          fail(Keyword.fetch!(opts, :failure), Keyword.fetch!(opts, :secret))
      end
    end

    def fail(:returned, secret) do
      {:error,
       Failure.api_error(
         429,
         %{
           "error" => %{
             "code" => "subscription_sharing_usage_limit_exceeded",
             "message" => secret,
             "quota" => %{"remaining" => 0}
           }
         },
         [{"openai-request-id", "req-alternate-safe"}, {"set-cookie", secret}]
       )}
    end

    def fail(:raised, secret), do: raise(secret)
    def fail(:thrown, secret), do: throw({:provider_failure, secret})
    def fail(:exited, secret), do: exit({:provider_failure, secret})
  end

  test "private module and inherited agents forward real directives without payload telemetry" do
    start_supervised!({Jido, name: __MODULE__.Engine})

    for mode <- [:module, :inherited] do
      id = "native-private-#{mode}"
      secret = "synthetic-directive-#{mode}-payload"
      trace_secret = "synthetic-trace-#{mode}-payload"
      emitted = Signal.new!("privacy.forwarded", %{content: secret}, source: "/privacy")
      directive = %Directive.Emit{signal: emitted, dispatch: {:pid, target: self()}}
      input = directive_signal(directive, trace_secret)
      observe_directives(id)
      server = start_agent(mode, id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _agent} = AgentServer.call(server, input)

          assert_receive {:signal,
                          %Signal{type: "privacy.forwarded", data: %{content: ^secret}} =
                            forwarded},
                         1_000

          forwarded_trace = Jido.Tracing.Trace.get(forwarded)
          input_trace = Jido.Tracing.Trace.get(input)
          assert forwarded_trace.trace_id == input_trace.trace_id
          assert forwarded_trace.span_id != input_trace.span_id
          assert forwarded_trace.causation_id == input.id
          assert_receive {:directive_telemetry, :start, measurements, start_metadata}, 1_000
          assert is_integer(measurements.system_time)
          assert_private_directive_metadata(start_metadata, id, input.id)
          assert_receive {:directive_telemetry, :stop, measurements, stop_metadata}, 1_000
          assert is_integer(measurements.duration)
          assert stop_metadata.status == :ok
          assert_private_directive_metadata(stop_metadata, id, input.id)
          refute inspect([start_metadata, stop_metadata], limit: :infinity) =~ secret
          refute inspect([start_metadata, stop_metadata], limit: :infinity) =~ trace_secret
          assert %{phase: :idle} = AgentServer.status(server)
        end)

      refute log =~ secret
      refute log =~ trace_secret
    end
  end

  test "private native dispatch failures remain real after commit without payload diagnostics" do
    start_supervised!({Jido, name: __MODULE__.Engine})
    id = "native-private-exception"
    secret = "synthetic-failed-directive-payload"
    trace_secret = "synthetic-failed-directive-trace"
    emitted = Signal.new!("privacy.forwarded", %{content: secret}, source: "/privacy")
    directive = %Directive.Emit{signal: emitted, dispatch: {FailingDispatch, secret: secret}}
    input = directive_signal(directive, trace_secret)
    observe_directives(id)
    server = start_agent(:module, id, error_policy: :stop_on_error)
    monitor = Process.monitor(server)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _agent} = AgentServer.call(server, input)
        assert_receive {:directive_telemetry, :start, _measurements, metadata}, 1_000
        assert_private_directive_metadata(metadata, id, input.id)
        assert_receive {:directive_telemetry, :stop, measurements, metadata}, 1_000
        assert is_integer(measurements.duration)
        assert_private_directive_metadata(metadata, id, input.id)
        assert metadata.status == :error
        assert metadata.error_type == :execution_error
        assert metadata.retryable? == false
        assert metadata.committed?
        refute inspect(metadata, limit: :infinity) =~ secret
        refute inspect(metadata, limit: :infinity) =~ trace_secret

        assert_receive {:DOWN, ^monitor, :process, ^server,
                        {:shutdown, {:agent_error, %Jido.Error.ExecutionError{} = reason}}},
                       1_000

        assert reason.details.retry == false
        refute inspect(reason, limit: :infinity) =~ secret
      end)

    assert log =~ "Agent Directive handling failed"
    refute log =~ secret
    refute log =~ trace_secret
    refute log =~ "Private AgentServer callback failed"
  end

  test "private committed dispatch failures notify subscribers without replaying partial deliveries" do
    start_supervised!({Jido, name: __MODULE__.Engine})
    id = "native-private-partial-dispatch"
    secret = "synthetic-partial-dispatch-payload"
    trace_secret = "synthetic-partial-dispatch-trace"
    emitted = Signal.new!("privacy.forwarded", %{content: secret}, source: "/privacy")

    directive = %Directive.Emit{
      signal: emitted,
      dispatch: [{:pid, target: self()}, {FailingDispatch, secret: secret}]
    }

    input = directive_signal(directive, trace_secret)
    observe_directives(id)
    server = start_agent(:module, id, error_policy: {:emit_signal, {:pid, target: self()}})
    monitor = Process.monitor(server)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, committed} = AgentServer.call(server, input)

        assert_receive {:signal, %Signal{type: "privacy.forwarded", data: %{content: ^secret}}},
                       1_000

        assert_receive {:signal, %Signal{type: "jido.agent.error"} = failure}, 1_000
        assert failure.data.agent_id == id
        assert failure.data.status == :failed
        assert failure.data.stage == :directive
        assert failure.data.committed?
        assert %{type: :execution_error, retryable?: false} = failure.data.error
        refute inspect(failure.data, limit: :infinity) =~ secret
        refute inspect(failure.data, limit: :infinity) =~ trace_secret

        assert_receive {:directive_telemetry, :start, _measurements, metadata}, 1_000
        assert_private_directive_metadata(metadata, id, input.id)
        assert_receive {:directive_telemetry, :stop, measurements, metadata}, 1_000
        assert is_integer(measurements.duration)
        assert_private_directive_metadata(metadata, id, input.id)
        assert metadata.status == :error
        assert metadata.error_type == :execution_error
        assert metadata.retryable? == false
        assert metadata.committed?
        assert metadata.turn_id == failure.data.turn_id
        refute inspect(metadata, limit: :infinity) =~ secret
        refute inspect(metadata, limit: :infinity) =~ trace_secret

        assert AgentServer.agent(server) == committed

        assert %{phase: :idle, state_version: 1, runtime: %{error_count: 1}} =
                 AgentServer.status(server)

        refute_receive {:signal, %Signal{type: "privacy.forwarded"}}, 0
        refute_receive {:signal, %Signal{type: "jido.agent.error"}}, 0
        refute_receive {:DOWN, ^monitor, :process, ^server, _reason}, 0
      end)

    assert log =~ "Agent Directive handling failed"
    refute log =~ secret
    refute log =~ trace_secret
    refute log =~ "Private AgentServer callback failed"
  end

  test "ordinary native directives retain payload and trace while telemetry stays native and bounded" do
    start_supervised!({Jido, name: __MODULE__.Engine})
    id = "native-public-directive"
    emitted = Signal.new!("privacy.forwarded", %{content: "ordinary payload"}, source: "/privacy")
    directive = %Directive.Emit{signal: emitted, dispatch: {:pid, target: self()}}
    input = directive_signal(directive, "ordinary trace attributes")
    observe_directives(id)
    server = start_agent(:public, id)

    assert {:ok, _agent} = AgentServer.call(server, input)
    assert_receive {:signal, %Signal{data: %{content: "ordinary payload"}} = forwarded}, 1_000
    assert Jido.Tracing.Trace.get(forwarded).tracestate == "omj=ordinary trace attributes"

    for phase <- [:start, :stop] do
      assert_receive {:directive_telemetry, ^phase, _measurements, metadata}, 1_000
      assert metadata.directive_module == Directive.Emit
      assert metadata.agent_id == id
      assert metadata.trace_id == Jido.Tracing.Trace.get(input).trace_id
      refute Map.has_key?(metadata, :directive)
      refute Map.has_key?(metadata, :tracestate)
      refute Map.has_key?(metadata, :jido_tracestate)
    end
  end

  test "alternate transport attach returns, raises, throws and exits normalize before logs and callers" do
    for client <- [InProcessClient, WebSocketClient],
        failure <- [:returned, :raised, :thrown, :exited] do
      secret = "synthetic-attach-#{inspect(client)}-#{failure}-payload"
      opts = private_opts(scenario: :attach, failure: failure, secret: secret)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Error{provider: :anthropic} = error} =
                   client.start_stream(AlternateProvider, model(), Context.new(), opts, self())

          refute inspect(error, limit: :infinity) =~ secret

          if failure == :returned do
            assert error.status == 429
            assert error.request_id == "req-alternate-safe"
            assert error.code == :subscription_sharing_usage_limit_exceeded
            assert error.quota == %{remaining: 0}
          else
            assert error.code == :provider_error
          end
        end)

      assert log =~ "kind="
      assert log =~ "stage="
      refute log =~ secret
    end
  end

  test "native in-process enumeration failures are safe before stream events and task completion" do
    for failure <- [:returned, :raised, :thrown, :exited] do
      secret = "synthetic-enumeration-#{failure}-payload"
      server = stream_server()
      opts = private_opts(scenario: :enumerate, failure: failure, secret: secret)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _task_pid, nil} =
                   InProcessClient.start_stream(
                     AlternateProvider,
                     model(),
                     Context.new(),
                     opts,
                     server
                   )

          assert_receive {reference, {:error, %Error{provider: :anthropic} = task_error}}, 1_000
          assert is_reference(reference)
          refute inspect(task_error, limit: :infinity) =~ secret

          assert {:ok, %{error: %Error{provider: :anthropic} = metadata_error}} =
                   StreamServer.await_metadata(server)

          assert {:error, %Error{provider: :anthropic} = stream_error} = StreamServer.next(server)
          refute inspect([metadata_error, stream_error], limit: :infinity) =~ secret
        end)

      refute log =~ secret
    end
  end

  test "WebSocket task exceptions normalize before native task and stream propagation" do
    secret = "synthetic-websocket-connect-timeout-payload"
    server = stream_server()

    opts =
      private_opts(
        scenario: :websocket_task,
        connect_timeout: secret,
        provider_options: [openai_websocket_session: self()]
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _task_pid, _http_context, %{}} =
                 WebSocketClient.start_stream(
                   AlternateProvider,
                   model(),
                   Context.new(),
                   opts,
                   server
                 )

        assert_receive {reference,
                        {:error, %Error{provider: :anthropic, code: :provider_error} = error}},
                       1_000

        assert is_reference(reference)
        refute inspect(error, limit: :infinity) =~ secret

        assert {:ok, %{error: %Error{provider: :anthropic} = metadata_error}} =
                 StreamServer.await_metadata(server)

        assert {:error, %Error{provider: :anthropic} = stream_error} = StreamServer.next(server)
        refute inspect([metadata_error, stream_error], limit: :infinity) =~ secret
      end)

    assert log =~ "provider_error"
    refute log =~ secret
  end

  test "native cancellation retains request normalization for returned and abnormal hook failures" do
    for failure <- [:returned, :raised, :thrown, :exited] do
      secret = "synthetic-cancellation-#{failure}-payload"
      server = stream_server()
      opts = private_opts(scenario: :cancel, owner: self(), failure: failure, secret: secret)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _task_pid, nil, %{}} =
                   StreamServer.start_in_process(
                     server,
                     AlternateProvider,
                     model(),
                     Context.new(),
                     opts
                   )

          assert_receive {:enumeration_waiting, _task_pid}, 1_000
          assert :ok = StreamServer.cancel(server)
          assert_receive {:cancellation_waiting, cancel_pid}, 1_000
          monitor = Process.monitor(cancel_pid)
          send(cancel_pid, :fail)
          assert_receive {:DOWN, ^monitor, :process, ^cancel_pid, :normal}, 1_000
        end)

      assert log =~ "In-process stream cancellation failed"
      assert log =~ "kind="
      refute log =~ secret
    end
  end

  def record_directive(event, measurements, metadata, {owner, id}) do
    if metadata.agent_id == id do
      send(owner, {:directive_telemetry, List.last(event), measurements, metadata})
    end
  end

  defp observe_directives(id) do
    handler = {__MODULE__, id, make_ref()}

    events =
      for phase <- [:start, :stop, :exception], do: [:jido, :agent, :directive, phase]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.record_directive/4, {self(), id})
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp start_agent(mode, id, extra_opts \\ []) do
    module = if mode == :module, do: PrivateAgent, else: PublicAgent

    opts =
      Keyword.merge(
        [jido: __MODULE__.Engine, agent: module, id: id, restart: :temporary],
        extra_opts
      )

    opts =
      if mode == :inherited do
        parent_server = start_agent(:module, id <> "-parent")

        parent =
          Jido.AgentServer.ParentRef.new!(%{
            pid: parent_server,
            id: id <> "-parent",
            tag: :privacy,
            meta: %{private_diagnostics: true}
          })

        Keyword.put(opts, :parent, parent)
      else
        opts
      end

    server =
      start_supervised!(Supervisor.child_spec({AgentServer, opts}, restart: :temporary),
        id: make_ref()
      )

    assert :ok = AgentServer.await_ready(server)
    server
  end

  defp directive_signal(directive, trace_state) do
    signal = Signal.new!("privacy.directive", %{directive: directive}, source: "/privacy")

    {:ok, signal} =
      Jido.Tracing.Trace.put(signal, %{
        trace_id: "00000000000000000000000000000001",
        span_id: "0000000000000001",
        tracestate: "omj=" <> trace_state
      })

    signal
  end

  defp assert_private_directive_metadata(metadata, id, signal_id) do
    assert metadata.agent_id == id
    assert metadata.agent_module in [PrivateAgent, PublicAgent]
    assert metadata.directive_module == Directive.Emit
    assert metadata.signal_type == "privacy.directive"
    assert metadata.signal_id == signal_id
    refute Map.has_key?(metadata, :directive)
    refute Map.has_key?(metadata, :jido_tracestate)
  end

  defp stream_server do
    start_supervised!({StreamServer, provider_mod: ReqLLM.Providers.OpenAI, model: model()},
      id: make_ref()
    )
  end

  defp private_opts(opts) do
    Keyword.put(opts, :stream_error_normalizer, &Subscription.normalize_stream_error/2)
  end

  defp model do
    %LLMDB.Model{
      provider: :anthropic,
      id: "synthetic-native-model",
      provider_model_id: "synthetic-native-model",
      limits: %{context: 10_000, output: 1_000},
      extra: %{}
    }
  end
end
