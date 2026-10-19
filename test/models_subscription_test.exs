defmodule OhMyJido.Models.SubscriptionTest do
  use ExUnit.Case, async: false

  alias Jido.AI.Reasoning.ReAct.{Config, Runner}
  alias OhMyJido.Auth.Error
  alias OhMyJido.Models.Subscription
  alias OhMyJido.Models.Subscription.Provider
  alias ReqLLM.{Context, ToolCall}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Streaming.{FinchClient, SSE}
  alias __MODULE__.{FixtureProvider, LegacyFailure, UnsafeBuildProvider}

  setup_all do
    ReqLLM.Providers.register!(Provider)
    ReqLLM.Providers.register!(FixtureProvider)
    :ok
  end

  test "options bind an explicit OAuth token without file or API-key fallback" do
    assert {:ok, opts} = Subscription.options("fixture-oauth")
    assert opts[:auth_mode] == :oauth
    assert opts[:access_token] == "fixture-oauth"
    assert opts[:provider_options][:store] == false
    assert opts[:stream] == true
    assert opts[:max_retries] == 0
    assert is_function(opts[:on_finch_request], 1)
    refute Keyword.has_key?(opts, :api_key)
    refute Keyword.has_key?(opts, :oauth_file)
    refute Keyword.has_key?(opts, :auth_file)

    for token <- [nil, "", " ", "token with spaces", "token\r\ninjected", 10] do
      assert {:error, %Error{code: :access_token_missing}} = Subscription.options(token)
    end
  end

  test "actual ReqLLM encoder emits public Responses with developer input and additional function tools" do
    tool =
      ReqLLM.Tool.new!(
        name: "read_file",
        description: "Read a granted file",
        parameter_schema: [path: [type: :string, required: true]],
        callback: fn _ -> {:ok, "fixture"} end
      )

    call = ToolCall.new("call_read", "read_file", ~s({"path":"mix.exs"}))

    context =
      Context.new([
        Context.system("Follow host permissions"),
        Context.user("Read mix.exs"),
        Context.assistant("", tool_calls: [call]),
        Context.tool_result("call_read", "file contents")
      ])

    {:ok, credential_opts} = Subscription.options("fixture-oauth")

    {:ok, {model, opts}} =
      Subscription.configure(model(), Keyword.put(credential_opts, :tools, [tool]))

    assert {:ok, request, _http_context, body} =
             FinchClient.build_stream_request(Provider, model, context, opts, ReqLLM.Finch)

    assert request.scheme == :https
    assert request.host == "api.openai.com"
    assert request.path == "/v1/responses"

    assert {"authorization", "Bearer fixture-oauth"} in Enum.map(request.headers, fn {key, value} ->
             {String.downcase(key), value}
           end)

    assert body["store"] == false
    assert body["stream"] == true
    refute Map.has_key?(body, "max_output_tokens")
    refute Map.has_key?(body, "previous_response_id")
    refute Enum.any?(body["input"], &(&1["role"] == "system"))

    assert Enum.any?(
             body["input"],
             &(&1["role"] == "developer" &&
                 &1["content"] == [%{"type" => "input_text", "text" => "Follow host permissions"}])
           )

    [additional | _] = body["input"]
    assert additional["type"] == "additional_tools"
    assert additional["role"] == "developer"

    assert [%{"type" => "function", "name" => "read_file", "parameters" => parameters}] =
             additional["tools"]

    assert parameters["required"] == ["path"]
    refute Map.has_key?(body, "tools")

    assert Enum.any?(
             body["input"],
             &(&1["type"] == "function_call" && &1["call_id"] == "call_read" &&
                 &1["name"] == "read_file" && &1["arguments"] == ~s({"path":"mix.exs"}))
           )

    assert Enum.any?(
             body["input"],
             &(&1["type"] == "function_call_output" && &1["call_id"] == "call_read" &&
                 &1["output"] == "file contents")
           )
  end

  test "preview namespace and additional-tools mapping preserve call names and result IDs" do
    function = %{
      "type" => "function",
      "name" => "read",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    namespace = %{
      "type" => "namespace",
      "name" => "workspace",
      "description" => "Granted workspace",
      "tools" => [function]
    }

    call = %{
      "type" => "function_call",
      "namespace" => "workspace",
      "name" => "read",
      "call_id" => "call_ns",
      "arguments" => "{}"
    }

    output = %{"type" => "function_call_output", "call_id" => "call_ns", "output" => "contents"}

    body = %{
      "model" => "fixture",
      "input" => [call, output],
      "tools" => [namespace, function],
      "store" => true,
      "stream" => false,
      "max_output_tokens" => 100,
      "temperature" => 0.2,
      "previous_response_id" => "old-response"
    }

    assert {:ok, profiled} = Subscription.profile_body(body)
    assert profiled["tools"] == [namespace]

    assert [
             %{"type" => "additional_tools", "role" => "developer", "tools" => [^function]},
             ^call,
             ^output
           ] = profiled["input"]

    assert profiled["store"] == false
    assert profiled["stream"] == true
    refute Map.has_key?(profiled, "max_output_tokens")
    refute Map.has_key?(profiled, "temperature")
    refute Map.has_key?(profiled, "previous_response_id")
  end

  test "explicit unsupported choices error while known Jido defaults survive until encoding" do
    {:ok, opts} = Subscription.options("fixture")

    for {key, value} <- [
          max_tokens: 4096,
          temperature: 0.2,
          previous_response_id: "old",
          background: false,
          top_p: 0.9,
          metadata: %{}
        ] do
      assert {:error, %Error{code: :subscription_sharing_unsupported_capability}} =
               Subscription.configure(model(), Keyword.put(opts, key, value))
    end

    defaults = [max_tokens: 4096, temperature: 0.2]

    assert {:ok, {model, configured}} =
             Subscription.configure(model(), Keyword.merge(opts, defaults),
               generated_options: defaults
             )

    assert configured[:max_tokens] == 4096
    assert configured[:temperature] == 0.2

    {:ok, request} =
      Provider.attach_stream(
        model,
        Context.new([Context.user("Hello")]),
        configured,
        ReqLLM.Finch
      )

    body = request |> configured[:on_finch_request].() |> Map.fetch!(:body) |> Jason.decode!()
    refute Map.has_key?(body, "max_output_tokens")
    refute Map.has_key?(body, "temperature")

    assert {:error, %Error{}} =
             Subscription.configure(model(), Keyword.put(opts, :api_key, "metered-key"))

    assert {:error, %Error{}} =
             Subscription.configure(
               model(),
               Keyword.put(opts, :base_url, "https://chatgpt.com/backend-api")
             )

    assert {:error, %Error{}} =
             Subscription.configure(model(), Keyword.put(opts, :provider_options, store: true))

    assert {:error, %Error{}} =
             Subscription.configure(
               model(),
               Keyword.put(opts, :provider_options, openai_stream_transport: :websocket)
             )
  end

  test "only identified runtime continuation IDs may be removed for stateless replay" do
    {:ok, opts} = Subscription.options("fixture")
    provider = Keyword.put(opts[:provider_options], :previous_response_id, "resp_old")
    opts = Keyword.put(opts, :provider_options, provider)

    assert {:error, %Error{code: :subscription_sharing_unsupported_capability}} =
             Subscription.configure(model(), opts)

    assert {:ok, {_, configured}} =
             Subscription.configure(model(), opts,
               generated_options: [previous_response_id: "resp_old"]
             )

    refute Keyword.has_key?(configured[:provider_options], :previous_response_id)
  end

  test "rejects hosted tools and unsupported audio input rather than dropping them" do
    for tool <- [
          "image_generation",
          "file_search",
          "code_interpreter",
          "computer",
          "computer_use_preview",
          "mcp",
          "tool_search",
          "programmatic_tool_calling"
        ] do
      body = %{"model" => "fixture", "input" => [], "tools" => [%{"type" => tool}]}

      assert {:error, %Error{code: :subscription_sharing_unsupported_capability}} =
               Subscription.profile_body(body)
    end

    body = %{
      "model" => "fixture",
      "input" => [
        %{"role" => "user", "content" => [%{"type" => "input_audio", "data" => "fixture"}]}
      ]
    }

    assert {:error, %Error{code: :subscription_sharing_unsupported_capability}} =
             Subscription.profile_body(body)
  end

  test "unsupported native custom-tool decoding cannot silently complete a coding turn" do
    {:ok, opts} = Subscription.options("fixture")
    custom = %{"type" => "custom", "name" => "freeform_editor"}

    namespace = %{
      "type" => "namespace",
      "name" => "workspace",
      "description" => "Granted workspace",
      "tools" => [custom]
    }

    for tool <- [custom, namespace] do
      assert {:error, %Error{code: :subscription_sharing_unsupported_capability}} =
               Subscription.configure(model(), Keyword.put(opts, :tools, [tool]))
    end
  end

  test "original multimodal contexts reject media that ReqLLM would omit" do
    assert :ok =
             Subscription.validate_context(
               Context.new([
                 Context.user([
                   ContentPart.text("Inspect image"),
                   ContentPart.image_url("https://example.invalid/image.png")
                 ])
               ])
             )

    for part <- [
          ContentPart.video_url("https://example.invalid/video.mp4"),
          ContentPart.file("fixture", "voice.wav", "audio/wav")
        ] do
      assert {:error, %Error{code: :subscription_sharing_unsupported_capability}} =
               Subscription.validate_context(Context.new([Context.user([part])]))
    end
  end

  test "installed fragmented SSE parser and Responses decoder retain terminal quota after text" do
    bytes =
      sse("response.output_text.delta", %{"delta" => "partial answer"}) <>
        sse("response.failed", %{
          "response" => %{
            "id" => "resp_fixture",
            "error" => %{
              "code" => "subscription_sharing_usage_limit_exceeded",
              "message" => "private diagnostic"
            }
          }
        })

    chunks = decode(bytes)
    assert [%ReqLLM.StreamChunk{type: :content, text: "partial answer"}, terminal] = chunks
    assert terminal.metadata.error_code == "subscription_sharing_usage_limit_exceeded"

    assert {:error,
            %Error{code: :subscription_sharing_usage_limit_exceeded, retryable: false} = error} =
             Subscription.classify_chunk(terminal)

    refute inspect(error) =~ "private diagnostic"
    assert :continue = Subscription.classify_chunk(hd(chunks))
  end

  test "real native StreamServer and materializer propagate typed terminal errors, not partial success" do
    {:ok, opts} = Subscription.options("fixture")
    {:ok, {model, _}} = Subscription.configure(model(), opts)

    details = %{
      "code" => "subscription_sharing_usage_limit_exceeded",
      "message" => "private diagnostic",
      "retry_after" => 17,
      "quota" => %{
        "remaining" => 0,
        "used" => 100,
        "window_seconds" => 18_000,
        "message" => "private diagnostic"
      }
    }

    bytes =
      sse("response.output_text.delta", %{"delta" => "partial"}) <>
        sse("response.failed", %{"response" => %{"status" => "failed", "error" => details}})

    response = native_response(bytes, model)
    metadata = ReqLLM.StreamResponse.MetadataHandle.await(response.metadata_handle)

    assert %Error{
             code: :subscription_sharing_usage_limit_exceeded,
             retry_after: 17,
             quota: %{remaining: 0}
           } = metadata.error

    refute inspect(metadata) =~ "private diagnostic"

    assert {:error, %Error{code: :subscription_sharing_usage_limit_exceeded, retryable: false}} =
             ReqLLM.StreamResponse.process_stream(response)

    completed =
      sse("response.output_text.delta", %{"delta" => "complete"}) <>
        sse("response.completed", %{
          "response" => %{"id" => "resp_complete", "status" => "completed", "output" => []}
        })

    assert {:ok, completed_response} =
             ReqLLM.StreamResponse.process_stream(native_response(completed, model))

    assert ReqLLM.Response.text(completed_response) == "complete"
    assert completed_response.finish_reason == :stop

    interrupted =
      native_response(sse("response.output_text.delta", %{"delta" => "partial"}), model)

    assert {:error, %Error{code: :stream_interrupted}} =
             ReqLLM.StreamResponse.process_stream(interrupted)
  end

  test "the native Jido loop emits safe request_failed for quota, eligibility and unsupported terminal events" do
    for {code, retryable, eligibility} <- [
          {"subscription_sharing_usage_limit_exceeded", false, nil},
          {"subscription_sharing_user_not_eligible", false, :ineligible},
          {"subscription_sharing_unsupported_capability", false, nil},
          {"subscription_sharing_usage_unavailable", true, nil}
        ] do
      bytes =
        sse("response.output_text.delta", %{"delta" => "partial answer"}) <>
          sse("response.failed", %{
            "response" => %{
              "status" => "failed",
              "error" => %{
                "code" => code,
                "message" => "private diagnostic",
                "retry_after" => 23,
                "quota" => %{"remaining" => 0}
              }
            }
          })

      {:ok, credentials} = Subscription.options("fixture")
      {:ok, {profile, opts}} = Subscription.configure(model(), credentials)
      fixture_model = %{profile | provider: FixtureProvider.provider_id()}
      opts = Keyword.update!(opts, :provider_options, &Keyword.put(&1, :fixture_sse, bytes))

      config =
        Config.new(
          model: fixture_model,
          streaming: true,
          max_iterations: 2,
          llm_opts: opts,
          capture_messages?: false,
          capture_thinking?: false
        )

      events = Runner.stream("Give a final answer", config) |> Enum.to_list()
      failure = Enum.find(events, &(&1.kind == :request_failed))
      assert failure != nil

      assert %Error{
               retryable: ^retryable,
               eligibility: ^eligibility,
               retry_after: 23,
               quota: %{remaining: 0}
             } = failure.data.error

      assert Atom.to_string(failure.data.error.code) == code
      refute Enum.any?(events, &(&1.kind == :request_completed))
      assert Enum.any?(events, &(&1.kind == :llm_delta))
      refute inspect(events, limit: :infinity) =~ "private diagnostic"
    end
  end

  test "completion, incomplete and eligibility failures are distinct terminal decoder outcomes" do
    completed =
      decode(
        sse("response.completed", %{
          "response" => %{"id" => "done", "status" => "completed", "output" => []}
        })
      )
      |> List.last()

    assert :completed = Subscription.classify_chunk(completed)

    incomplete =
      decode(
        sse("response.incomplete", %{
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"}
          }
        })
      )
      |> List.last()

    assert {:error, %Error{code: :stream_incomplete}} = Subscription.classify_chunk(incomplete)

    misleading_finish =
      decode(
        sse("response.incomplete", %{
          "response" => %{"status" => "incomplete", "incomplete_details" => %{"reason" => "stop"}}
        })
      )
      |> List.last()

    assert {:error, %Error{code: :stream_incomplete}} =
             Subscription.classify_chunk(misleading_finish)

    for code <- [
          "subscription_sharing_user_not_eligible",
          "subscription_sharing_unsupported_capability",
          "chatpass_v2_scope_not_authorized"
        ] do
      terminal = decode(sse("error", %{"error" => %{"code" => code}})) |> List.last()
      assert {:error, %Error{retryable: false} = error} = Subscription.classify_chunk(terminal)
      assert Atom.to_string(error.code) == code
    end
  end

  test "admission errors and temporary usage failures classify without billing fallback" do
    assert %Error{code: :subscription_sharing_usage_unavailable, retryable: true} =
             Subscription.classify_error(%{
               status: 503,
               body: %{"error" => %{"code" => "subscription_sharing_usage_unavailable"}},
               headers: %{"x-request-id" => ["req-fixture"]}
             })

    request_error =
      ReqLLM.Error.API.Request.exception(
        provider_code: "subscription_sharing_usage_limit_exceeded",
        reason: "private diagnostic"
      )

    assert %Error{code: :subscription_sharing_usage_limit_exceeded, status: nil, retryable: false} =
             Subscription.classify_error(request_error)

    error =
      Subscription.classify_error(%{
        status: 403,
        body: %{"detail" => "private diagnostic"},
        headers: %{}
      })

    assert error.status == 403
    refute error.retryable
    refute inspect(error) =~ "private diagnostic"
    assert {:error, %Error{code: :access_token_missing}} = Subscription.options(nil)
  end

  test "native pre-stream HTTP error objects keep only safe diagnostics at the host projection" do
    body = %{
      "error" => %{
        "code" => "subscription_sharing_user_not_eligible",
        "message" => "private diagnostic",
        "quota" => %{"remaining" => 0, "used" => 25}
      }
    }

    native =
      ReqLLM.Streaming.Failure.api_error(403, Jason.encode!(body), [
        {"openai-request-id", "req-native"},
        {"retry-after", "19"}
      ])

    assert %Error{
             code: :subscription_sharing_user_not_eligible,
             status: 403,
             request_id: "req-native",
             retry_after: 19,
             eligibility: :ineligible,
             quota: %{remaining: 0, used: 25}
           } =
             error =
             Subscription.classify_error(native)

    refute inspect(error) =~ "private diagnostic"
  end

  test "the vendored native failure boundary normalizes before logging, observers and materialization" do
    {:ok, opts} = Subscription.options("fixture")
    {:ok, {model, _}} = Subscription.configure(model(), opts)

    server =
      start_supervised!({ReqLLM.StreamServer, provider_mod: Provider, model: model},
        id: make_ref()
      )

    body = %{
      "error" => %{
        "code" => "subscription_sharing_usage_limit_exceeded",
        "message" => "private diagnostic",
        "quota" => %{"remaining" => 0}
      }
    }

    native =
      ReqLLM.Streaming.Failure.api_error(429, Jason.encode!(body), [
        {"openai-request-id", "req-boundary"},
        {"retry-after", "31"},
        {"set-cookie", "private-cookie"}
      ])

    native = %{native | request_body: "private request"}
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                %Error{
                  code: :subscription_sharing_usage_limit_exceeded,
                  status: 429,
                  retryable: false,
                  retry_after: 31,
                  request_id: "req-boundary"
                }} =
                 FinchClient.forward_stream_failure(server, native, {Provider, model}, fn event ->
                   send(parent, {:boundary_observer, event})
                 end)
      end)

    assert_receive {:boundary_observer, {:error, %Error{quota: %{remaining: 0}} = observed}}
    refute inspect(observed) =~ "private"
    refute log =~ "private"
    assert log =~ "subscription_sharing_usage_limit_exceeded"
    {:ok, metadata} = ReqLLM.StreamServer.await_metadata(server)
    assert %Error{code: :subscription_sharing_usage_limit_exceeded} = metadata.error
    refute Map.has_key?(metadata, :headers)
    refute inspect(metadata) =~ "private"
  end

  test "safe-boundary marker gates compatibility while ordinary provider failures stay unchanged" do
    assert ReqLLM.Streaming.Failure.normalization_version() == 1
    assert Subscription.boundary_supported?()
    refute Subscription.boundary_supported?(LegacyFailure)
    native = ReqLLM.Streaming.Failure.api_error(503, %{"detail" => "ordinary diagnostic"}, [])

    assert ReqLLM.Streaming.Failure.normalize(native, {ReqLLM.Providers.OpenAI, model()}) ==
             native
  end

  test "the native Jido loop also keeps safe pre-stream HTTP diagnostics" do
    error = %{
      "status" => 403,
      "body" => %{
        "error" => %{
          "code" => "subscription_sharing_user_not_eligible",
          "message" => "private diagnostic",
          "quota" => %{"remaining" => 0}
        }
      }
    }

    {:ok, credentials} = Subscription.options("fixture")
    {:ok, {profile, opts}} = Subscription.configure(model(), credentials)
    fixture_model = %{profile | provider: FixtureProvider.provider_id()}
    opts = Keyword.update!(opts, :provider_options, &Keyword.put(&1, :fixture_http_error, error))

    config =
      Config.new(
        model: fixture_model,
        streaming: true,
        max_iterations: 2,
        llm_opts: opts,
        capture_messages?: false,
        capture_thinking?: false
      )

    events = Runner.stream("Give a final answer", config) |> Enum.to_list()
    failed = Enum.find(events, &(&1.kind == :request_failed))

    assert %Error{
             code: :subscription_sharing_user_not_eligible,
             status: 403,
             eligibility: :ineligible,
             quota: %{remaining: 0}
           } = failed.data.error

    refute Enum.any?(events, &(&1.kind == :request_completed))
    refute inspect(events, limit: :infinity) =~ "private diagnostic"
  end

  test "request-scoped normalization protects explicit metered credentials too" do
    callback = &Subscription.normalize_stream_error/2
    context = Context.new([Context.user("Hello")])

    opts = [
      api_key: "fixture-explicit-api-key",
      stream_error_normalizer: callback,
      telemetry: [payloads: :none]
    ]

    processed =
      ReqLLM.Provider.Options.process_stream!(
        ReqLLM.Providers.OpenAI,
        :chat,
        model(),
        context,
        opts
      )

    assert processed[:stream_error_normalizer] == callback

    for invalid <- [nil, :not_a_callback, fn _error -> :ok end] do
      assert {:error, _reason} =
               ReqLLM.Provider.Options.process(
                 ReqLLM.Providers.OpenAI,
                 :chat,
                 model(),
                 Keyword.put(opts, :stream_error_normalizer, invalid)
               )
    end

    error =
      ReqLLM.Streaming.Failure.api_error(
        401,
        %{"error" => %{"code" => "invalid_token", "message" => "private diagnostic"}},
        []
      )

    normalized =
      ReqLLM.Streaming.Failure.normalize(error, {callback, %{model() | provider: :anthropic}})

    assert %Error{provider: :anthropic, code: :invalid_token, reauth_required: true} = normalized
    refute inspect(normalized) =~ "private diagnostic"
  end

  test "metered nonstream Req and native Jido errors normalize before the worker failure boundary" do
    parent = self()

    plug = fn conn ->
      send(parent, {:native_request_body, Req.Test.raw_body(conn)})

      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{
        "error" => %{
          "code" => "subscription_sharing_user_not_eligible",
          "message" => "private diagnostic"
        }
      })
    end

    opts = [
      api_key: "fixture-explicit-api-key",
      stream_error_normalizer: &Subscription.normalize_stream_error/2,
      telemetry: [payloads: :none],
      max_retries: 0
    ]

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:req_llm, :request, :exception],
        &__MODULE__.record_request_exception/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for selected_model <- [
          model(),
          %{
            model()
            | provider: :google,
              id: "gemini-2.5-flash",
              provider_model_id: "gemini-2.5-flash"
          }
        ] do
      config =
        Config.new(
          model: selected_model,
          streaming: false,
          max_iterations: 2,
          llm_opts: opts,
          req_http_options: [plug: plug],
          capture_messages?: false
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          events = Runner.stream("Give a final answer", config) |> Enum.to_list()
          failed = Enum.find(events, &(&1.kind == :request_failed))
          provider = selected_model.provider

          assert %Error{
                   provider: ^provider,
                   code: :subscription_sharing_user_not_eligible,
                   status: 403
                 } = failed.data.error

          refute inspect(events, limit: :infinity) =~ "private diagnostic"
          refute Enum.any?(events, &(&1.kind == :request_completed))
        end)

      assert_receive {:native_request_body, body}
      refute IO.iodata_to_binary(body) =~ "stream_error_normalizer"
      assert_receive {:native_error_telemetry, metadata}
      assert metadata.error.status == 403
      refute inspect(metadata, limit: :infinity) =~ "private"
      refute log =~ "private diagnostic"
    end
  end

  test "native telemetry projects exception diagnostics without bodies, headers or causes" do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:req_llm, :request, :exception],
        fn _event, _measurements, metadata, target ->
          send(target, {:safe_telemetry, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    context =
      ReqLLM.Telemetry.new_context(model(),
        api_key: "private-api-key",
        telemetry: [payloads: :none]
      )

    error =
      ReqLLM.Error.API.Request.exception(
        reason: "private diagnostic",
        status: 403,
        response_body: %{"private" => "private-body"},
        request_body: "private request",
        headers: [{"set-cookie", "private-cookie"}],
        cause: "private cause"
      )

    ReqLLM.Telemetry.exception_request(context, error)
    assert_receive {:safe_telemetry, metadata}
    assert metadata.error.status == 403
    refute inspect(metadata, limit: :infinity) =~ "private"
  end

  test "native stream and metadata status diagnostics omit fresh credentials and raw payloads" do
    server =
      start_supervised!({ReqLLM.StreamServer, provider_mod: Provider, model: model()},
        id: make_ref()
      )

    telemetry =
      ReqLLM.Telemetry.new_context(model(),
        access_token: "private-access",
        api_key: "private-api-key",
        telemetry: [payloads: :none]
      )

    :ok = ReqLLM.StreamServer.set_telemetry_context(server, telemetry)
    :ok = ReqLLM.StreamServer.http_event(server, {:headers, [{"set-cookie", "private-cookie"}]})
    refute inspect(:sys.get_status(server), limit: :infinity) =~ "private"

    formatted =
      ReqLLM.StreamServer.format_status(%{
        state: :sys.get_state(server),
        message: {:oauth_callback, "private-code", "private-verifier", "private-id-token"},
        reason: "private reason",
        log: ["private log"]
      })

    refute inspect(formatted, limit: :infinity) =~ "private"

    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{headers: [{"set-cookie", "private-cookie"}], access_token: "private-access"}
      end)

    ReqLLM.StreamResponse.MetadataHandle.await(handle)
    refute inspect(:sys.get_status(handle), limit: :infinity) =~ "private"
    ReqLLM.StreamResponse.MetadataHandle.stop(handle)
  end

  test "native abnormal stream termination has metadata-only crash diagnostics" do
    child = %{
      id: make_ref(),
      start: {ReqLLM.StreamServer, :start_link, [[provider_mod: Provider, model: model()]]},
      restart: :temporary
    }

    server = start_supervised!(child)

    telemetry =
      ReqLLM.Telemetry.new_context(model(),
        access_token: "private-access",
        api_key: "private-api-key",
        telemetry: [payloads: :none]
      )

    :ok = ReqLLM.StreamServer.set_telemetry_context(server, telemetry)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{}} =
                 GenServer.call(
                   server,
                   {:private_callback, "private-code", "private-verifier", "private-id-token"}
                 )
      end)

    refute log =~ "private"
  end

  test "native abnormal metadata callback termination cannot print credentials" do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(
        fn -> %{headers: [{"set-cookie", "private-cookie"}], access_token: "private-access"} end,
        {&Subscription.normalize_stream_error/2, model()}
      )

    Process.unlink(handle)
    ReqLLM.StreamResponse.MetadataHandle.await(handle)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{}} =
                 GenServer.call(handle, {:private_callback, "private-code", "private-verifier"})
      end)

    refute log =~ "private"
  end

  test "metadata collection failures neither print private data nor become success" do
    parent = self()
    context = {&Subscription.normalize_stream_error/2, model()}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, handle} =
          ReqLLM.StreamResponse.MetadataHandle.start_link(
            fn -> raise "private diagnostic with private token" end,
            context
          )

        metadata = ReqLLM.StreamResponse.MetadataHandle.await(handle)
        send(parent, {:metadata_failure, metadata})
        ReqLLM.StreamResponse.MetadataHandle.stop(handle)
      end)

    assert_receive {:metadata_failure, %{error: %Error{}, finish_reason: :error}}
    refute log =~ "private"
  end

  def record_request_exception(_event, _measurements, metadata, target) do
    send(target, {:native_error_telemetry, metadata})
  end

  test "request-builder exceptions are normalized before native diagnostics" do
    parent = self()
    opts = [stream_error_normalizer: &Subscription.normalize_stream_error/2]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result =
          FinchClient.build_stream_request(
            UnsafeBuildProvider,
            model(),
            Context.new(),
            opts,
            ReqLLM.Finch
          )

        send(parent, {:build_result, result})
      end)

    assert_receive {:build_result, {:error, %Error{code: :provider_error}}}
    refute log =~ "private"
  end

  defmodule UnsafeBuildProvider do
    def attach_stream(_model, _context, _opts, _finch) do
      raise "private access token, private PKCE verifier, private code and private ID token"
    end
  end

  defmodule LegacyFailure do
    def normalization_version, do: 0
  end

  defmodule FixtureProvider do
    use ReqLLM.Provider,
      id: :oh_my_jido_subscription_fixture,
      default_base_url: "https://api.openai.com/v1"

    @provider_schema Provider.provider_schema().schema ++
                       [fixture_sse: [type: :string], fixture_http_error: [type: :any]]

    @impl ReqLLM.Provider
    def stream_transport(_model, _opts), do: :in_process

    @impl ReqLLM.Provider
    def attach_in_process_stream(model, context, opts) do
      case opts[:provider_options][:fixture_http_error] do
        nil ->
          sse_stream(model, context, opts)

        %{"status" => status, "body" => body} ->
          native = ReqLLM.Streaming.Failure.api_error(status, body, [])
          {:ok, [{:error, ReqLLM.Streaming.Failure.normalize(native, {Provider, model})}]}
      end
    end

    defp sse_stream(model, _context, opts) do
      bytes = opts[:provider_options][:fixture_sse]
      midpoint = div(byte_size(bytes), 2)
      <<first::binary-size(^midpoint), rest::binary>> = bytes

      stream =
        [first, rest]
        |> ReqLLM.Streaming.SSE.parse_sse_stream()
        |> Stream.transform(
          fn -> Provider.init_stream_state(model) end,
          fn event, state -> Provider.decode_stream_event(event, model, state) end,
          fn state -> Provider.flush_stream_state(model, state) end,
          fn _state -> :ok end
        )

      {:ok, stream}
    end
  end

  defp native_response(bytes, model) do
    server =
      start_supervised!({ReqLLM.StreamServer, provider_mod: Provider, model: model},
        id: make_ref()
      )

    :ok = ReqLLM.StreamServer.http_event(server, {:status, 200})
    :ok = ReqLLM.StreamServer.http_event(server, {:headers, [{"x-request-id", "req-fixture"}]})
    midpoint = div(byte_size(bytes), 2)
    <<first::binary-size(^midpoint), rest::binary>> = bytes
    :ok = ReqLLM.StreamServer.http_event(server, {:data, first})
    :ok = ReqLLM.StreamServer.http_event(server, {:data, rest})
    :ok = ReqLLM.StreamServer.http_event(server, :done)

    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        {:ok, metadata} = ReqLLM.StreamServer.await_metadata(server)
        metadata
      end)

    stream =
      Stream.resource(
        fn -> server end,
        fn server ->
          case ReqLLM.StreamServer.next(server) do
            {:ok, chunk} -> {[chunk], server}
            :halt -> {:halt, server}
            {:error, error} -> raise error
          end
        end,
        fn _server -> :ok end
      )

    %ReqLLM.StreamResponse{
      stream: stream,
      metadata_handle: handle,
      cancel: fn -> ReqLLM.StreamServer.cancel(server) end,
      model: model,
      context: Context.new()
    }
  end

  defp model do
    %LLMDB.Model{
      provider: :openai,
      id: "gpt-6.1-sol",
      provider_model_id: "gpt-6.1-sol",
      limits: %{context: 100_000, output: 4096},
      extra: %{}
    }
  end

  defp sse(type, data),
    do: "event: " <> type <> "\ndata: " <> Jason.encode!(Map.put(data, "type", type)) <> "\n\n"

  defp decode(bytes) do
    midpoint = div(byte_size(bytes), 2)
    <<first::binary-size(^midpoint), rest::binary>> = bytes

    [first, rest]
    |> SSE.parse_sse_stream()
    |> Enum.reduce({[], Provider.init_stream_state(model())}, fn event, {chunks, state} ->
      {next, state} = Provider.decode_stream_event(event, model(), state)
      {Enum.reverse(next, chunks), state}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
