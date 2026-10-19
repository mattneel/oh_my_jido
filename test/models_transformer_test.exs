defmodule OhMyJido.Models.TransformerTest do
  use Jido.AI.TestCase, async: false

  alias Jido.AI.Reasoning.ReAct.{Config, State}
  alias OhMyJido.{Context, ContextPolicy}
  alias OhMyJido.Models.Transformer

  defmodule ReadAction do
    use Jido.Action,
      name: "read_fixture",
      description: "Read the fixture",
      schema: Zoi.object(%{path: Zoi.string()})

    def capability, do: :read

    def run(%{path: path}, execution_context) do
      with :ok <- OhMyJido.Tool.authorize(execution_context, :read, %{path: path}),
           {:ok, absolute} <- OhMyJido.Workspace.resolve(execution_context, path),
           {:ok, content} <- File.read(absolute) do
        {:ok, %{content: content}}
      end
    end
  end

  defmodule EditAction do
    use Jido.Action,
      name: "edit_fixture",
      description: "Edit the fixture",
      schema: Zoi.object(%{path: Zoi.string()})

    def capability, do: :edit

    def run(%{path: path}, execution_context) do
      with :ok <- OhMyJido.Tool.authorize(execution_context, :edit, %{path: path}),
           {:ok, absolute} <-
             OhMyJido.Workspace.resolve(execution_context, path, allow_missing: true),
           :ok <- File.write(absolute, "edited fixture") do
        {:ok, %{written: true}}
      end
    end
  end

  defmodule MissingCapabilityAction do
    use Jido.Action,
      name: "undeclared_fixture",
      description: "No declared authority",
      schema: Zoi.object(%{})

    def run(params, _context), do: {:ok, params}
  end

  defmodule CredentialsHost do
    def credentials(_context, account, opts) do
      send(opts[:observer], {:credential_request, account})

      Agent.get_and_update(opts[:counter], fn generation ->
        next = generation + 1

        {{:ok,
          [
            api_key: "fixture-key-generation-#{next}",
            auth_mode: :api_key,
            telemetry: [payloads: :raw]
          ]}, next}
      end)
    end
  end

  defmodule RequestOptionsHost do
    def credentials(_context, _account, opts), do: {:ok, Keyword.fetch!(opts, :request_opts)}
  end

  defmodule SubscriptionHost do
    def credentials(_context, _account, _opts),
      do: OhMyJido.Models.Subscription.options("fixture-subscription-token")
  end

  defmodule EmptyCredentialsHost do
    def credentials(_context, _account, _opts), do: {:ok, []}
  end

  defmodule DeniedCredentialsHost do
    def credentials(_context, _account, _opts), do: {:error, :subscription_expired}
  end

  defmodule FixtureHost do
    def credentials(_context, _account, _opts), do: {:error, :credentials_not_expected}

    def authorize(_context, :read, effect, opts) do
      send(Keyword.fetch!(opts, :observer), {:authorized, :read, effect})
      :ok
    end

    def authorize(_context, _capability, _effect, _opts), do: {:error, :not_granted}
  end

  defmodule Registry do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      {:ok, policy} = ContextPolicy.new([])
      {:ok, %{observer: opts[:observer], policy: policy, mode: opts[:mode] || :normal}}
    end

    def handle_call({:register_secrets, values}, _from, state) do
      case state.mode do
        :normal ->
          send(state.observer, {:registered_secrets, values})
          {:reply, :ok, state}

        :refuse ->
          send(state.observer, {:registration_attempt, values})
          {:reply, {:error, %{reason: :refused, tokens: values}}, state}

        :exit ->
          send(state.observer, {:registration_attempt, values})
          {:stop, :normal, state}
      end
    end

    def handle_call({:compact_context, messages}, _from, state) do
      send(state.observer, :context_projection)
      result = ContextPolicy.compact(state.policy, messages)

      case result do
        {:ok, projection} -> {:reply, result, %{state | policy: projection.state}}
        {:error, _reason} -> {:reply, result, state}
      end
    end
  end

  test "the installed transform_request/4 contract selects Context.model and obtains fresh credentials every turn" do
    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})
    context = context(registry, {CredentialsHost, counter: counter, observer: self()})

    config =
      Config.new(model: :fast, tools: [ReadAction, EditAction], request_transformer: Transformer)

    state = State.new("Inspect", "old configured prompt")
    request = request(config, state)

    assert {:ok, first} =
             Transformer.transform_request(request, state, config, %{oh_my_jido: context})

    assert first.model == context.model
    assert first.llm_opts[:api_key] == "fixture-key-generation-1"
    refute Keyword.has_key?(first.llm_opts, :access_token)
    assert first.llm_opts[:auth_mode] == :api_key
    assert_receive {:credential_request, "account-ref"}
    assert_receive {:registered_secrets, ["fixture-key-generation-1"]}
    assert_receive :context_projection

    assert {:ok, second} =
             Transformer.transform_request(request, state, config, %{oh_my_jido: context})

    assert second.llm_opts[:api_key] == "fixture-key-generation-2"
    assert_receive {:credential_request, "account-ref"}
    assert_receive {:registered_secrets, ["fixture-key-generation-2"]}
    assert_receive :context_projection

    assert [%{role: :system, content: prompt} | _] = first.messages
    assert prompt =~ "openai:turn-model"
    assert prompt =~ "old configured prompt"
    assert Enum.count(first.messages, &(Map.get(&1, :role) == :system)) == 1
  end

  test "tool gating returns one registry shared with regenerated installed ReqLLM definitions" do
    script =
      expect_react do
        user("Inspect")
        answer("Read-only result")
      end

    config =
      Config.new(
        model: :fast,
        tools: [ReadAction, EditAction, MissingCapabilityAction],
        llm_opts: react_llm_opts(script)
      )

    state = State.new("Inspect", nil)

    context = %{
      context(nil, {EmptyCredentialsHost, []})
      | account: nil,
        tools: [ReadAction, EditAction, MissingCapabilityAction]
    }

    assert {:ok, override} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: context
             })

    assert override.tools == %{"read_fixture" => ReadAction}
    definitions = Config.reqllm_tools(%{config | tools: override.tools})
    assert Enum.map(definitions, & &1.name) == Map.keys(override.tools)
    assert hd(override.messages).content =~ "read_fixture"
    refute hd(override.messages).content =~ "edit_fixture"
  end

  test "model capability limits and explicit custom grants use the same registry policy" do
    script =
      expect_react do
        user("Inspect")
        answer("Read-only result")
      end

    config =
      Config.new(
        model: :fast,
        tools: [ReadAction, MissingCapabilityAction],
        llm_opts: react_llm_opts(script)
      )

    state = State.new("Inspect", nil)

    context = %{
      context(nil, {EmptyCredentialsHost, []})
      | account: nil,
        tools: [ReadAction, MissingCapabilityAction],
        permissions: MapSet.new([:custom])
    }

    assert {:ok, custom} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: context
             })

    assert custom.tools == %{"undeclared_fixture" => MissingCapabilityAction}

    text_model = %{id: "no-tools", provider: :openai, capabilities: %{tools: %{enabled: false}}}

    assert {:ok, disabled} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: %{context | model: text_model}
             })

    assert disabled.tools == %{}
  end

  test "only explicit valid native Jido scripts bypass credentials, never test env, flags or ambient registrations" do
    script =
      expect_react do
        user("Inspect")
        answer("Scripted result")
      end

    context = %{
      context(nil, {EmptyCredentialsHost, []})
      | account: nil,
        metadata: %{test_mode: true}
    }

    state = State.new("Inspect", nil)
    config = Config.new(model: :fast, tools: [])
    base = request(config, state)

    assert {:error, :account_required} =
             Transformer.transform_request(base, state, config, %{oh_my_jido: context})

    assert {:error, :invalid_react_script} =
             Transformer.transform_request(
               %{base | llm_opts: [jido_ai_react_script: true]},
               state,
               config,
               %{oh_my_jido: context}
             )

    assert {:error, :invalid_react_script} =
             Transformer.transform_request(
               %{base | llm_opts: [jido_ai_react_script: %{enabled: true}]},
               state,
               config,
               %{oh_my_jido: context}
             )

    assert {:error, :test_scripts_not_enabled} =
             Transformer.transform_request(
               %{base | llm_opts: react_llm_opts(script)},
               state,
               config,
               %{oh_my_jido: context}
             )

    approved = %{context | metadata: %{runtime_config: %{allow_test_scripts: true}}}

    assert {:ok, scripted} =
             Transformer.transform_request(
               %{base | llm_opts: react_llm_opts(script)},
               state,
               config,
               %{oh_my_jido: approved}
             )

    assert scripted.llm_opts[:jido_ai_react_script] == script
    refute Keyword.has_key?(scripted.llm_opts, :api_key)
  end

  test "a permitted but exhausted explicit script fails at the native boundary without credential fallback" do
    script =
      expect_react do
        user("Inspect")
        answer("Only scripted answer")
      end

    config = Config.new(model: :fast, tools: [], llm_opts: react_llm_opts(script))
    state = State.new("Inspect", nil)

    messages = [
      %{role: :user, content: "Inspect"},
      %{
        role: :assistant,
        content: "",
        tool_calls: [
          %{id: "already-consumed", name: "read_fixture", arguments: %{path: "fixture.ex"}}
        ]
      },
      %{role: :tool, tool_call_id: "already-consumed", name: "read_fixture", content: "observed"}
    ]

    request = %{request(config, state) | messages: messages}
    context = %{context(nil, {DeniedCredentialsHost, []}) | account: nil}

    assert {:ok, override} =
             Transformer.transform_request(request, state, config, %{oh_my_jido: context})

    assert {:error, %{type: :react_test_script_exhausted}} =
             Jido.AI.Test.ReActScript.next_response(override.llm_opts, override.messages)

    refute Keyword.has_key?(override.llm_opts, :api_key)
  end

  test "denied or empty host credentials never reuse request credentials or change billing mode" do
    registry = start_supervised!({Registry, observer: self()})
    state = State.new("Inspect", nil)
    config = Config.new(model: :fast, tools: [])
    request = request(config, state)
    context = context(registry, {EmptyCredentialsHost, []})

    assert {:error, :explicit_credentials_required} =
             Transformer.transform_request(request, state, config, %{oh_my_jido: context})

    assert {:error, :subscription_expired} =
             Transformer.transform_request(request, state, config, %{
               oh_my_jido: %{context | host: {DeniedCredentialsHost, []}}
             })

    refute_receive {:registered_secrets, _}
  end

  test "base credentials are rejected before host access rather than cleared from retained native config" do
    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})
    context = context(registry, {CredentialsHost, counter: counter, observer: self()})
    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)
    base = request(config, state)

    for imported <- [
          [api_key: "fixture-imported-key"],
          [access_token: "fixture-imported-token"],
          [auth_mode: :oauth],
          [oauth_file: "/not-read/oauth.json"],
          [
            provider_options: [
              openai: [access_token: "fixture-imported-token", auth_mode: :oauth]
            ]
          ],
          [provider_options: %{"openai" => %{"oauth_file" => "/not-read/oauth.json"}}],
          [req_http_options: [headers: [{"authorization", "Bearer fixture-imported-token"}]]]
        ] do
      request = %{base | llm_opts: Keyword.merge(base.llm_opts, imported)}

      assert {:error, :credentials_must_come_from_host} =
               Transformer.transform_request(request, state, config, %{oh_my_jido: context})
    end

    assert Agent.get(counter, & &1) == 0
    refute_receive {:credential_request, _}
    refute_receive {:registered_secrets, _}
  end

  test "host inference options cannot carry refresh, identity or credential-file lifecycle storage" do
    registry = start_supervised!({Registry, observer: self()})
    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)

    for lifecycle <- [
          [refresh_token: "fixture-refresh-token"],
          [id_token: "fixture-id-token"],
          [oauth_file: "/not-read/oauth.json"],
          [refresh: "fixture-refresh-alias"],
          [access: "fixture-access-alias"],
          [req_http_options: [headers: [{"authorization", "Bearer fixture-secondary-token"}]]],
          [provider_options: [openai: [id_token: "fixture-id-token"]]],
          [provider_options: [oauth_file: "/not-read/oauth.json"]]
        ] do
      fresh = Keyword.merge([api_key: "fixture-inference-key"], lifecycle)
      context = context(registry, {RequestOptionsHost, request_opts: fresh})

      assert {:error, :credential_lifecycle_options_not_allowed} =
               Transformer.transform_request(request(config, state), state, config, %{
                 oh_my_jido: context
               })
    end

    refute_receive {:registered_secrets, _}

    context =
      context(
        registry,
        {RequestOptionsHost,
         request_opts: [api_key: "fixture-inference-key", provider_options: [store: false]]}
      )

    assert {:ok, override} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: context
             })

    assert override.llm_opts[:provider_options][:store] == false
  end

  test "unsafe native debug logging blocks production before credentials while approved scripts remain network-free" do
    previous = Application.fetch_env(:req_llm, :debug)
    Application.put_env(:req_llm, :debug, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, :debug, value)
        :error -> Application.delete_env(:req_llm, :debug)
      end
    end)

    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})
    context = context(registry, {CredentialsHost, counter: counter, observer: self()})
    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)
    base = request(config, state)

    assert {:error, :unsafe_model_debug_configuration} =
             Transformer.transform_request(base, state, config, %{oh_my_jido: context})

    assert Agent.get(counter, & &1) == 0
    refute_receive {:credential_request, _}

    script =
      expect_react do
        user("Inspect")
        answer("Approved test result")
      end

    assert {:ok, scripted} =
             Transformer.transform_request(
               %{base | llm_opts: react_llm_opts(script)},
               state,
               config,
               %{oh_my_jido: context}
             )

    assert scripted.llm_opts[:jido_ai_react_script] == script
    assert Agent.get(counter, & &1) == 0
  end

  test "credentials require a synchronous secret registry and invalid context is rejected before model access" do
    counter = start_supervised!({Agent, fn -> 0 end})
    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)
    context = context(nil, {CredentialsHost, counter: counter, observer: self()})

    assert {:error, :missing_secret_registry} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: context
             })

    assert {:error, :missing_context} =
             Transformer.transform_request(request(config, state), state, config, %{})
  end

  test "fresh secrets are registered before prompt composition can fail" do
    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})
    context = context(registry, {CredentialsHost, counter: counter, observer: self()})

    context = %{
      context
      | metadata: %{runtime_config: %{instructions: fn -> "must not execute" end}}
    }

    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)

    assert {:error, :invalid_instructions} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: context
             })

    assert_receive {:registered_secrets, ["fixture-key-generation-1"]}
    refute_receive :context_projection
  end

  test "credentialled turns override host and request raw telemetry with explicit metadata-only options" do
    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})
    context = context(registry, {CredentialsHost, counter: counter, observer: self()})
    raw_normalizer = fn reason, _model -> reason end

    config =
      Config.new(
        model: :fast,
        tools: [],
        llm_opts: [telemetry: [payloads: :raw], stream_error_normalizer: raw_normalizer]
      )

    state = State.new("Inspect", nil)
    base = request(config, state)

    assert {:ok, override} =
             Transformer.transform_request(base, state, config, %{oh_my_jido: context})

    assert override.llm_opts[:telemetry] == [payloads: :none]
    effective = Config.merge_llm_opts(config, base.llm_opts, override.llm_opts, override.model)
    assert effective[:telemetry] == [payloads: :none]
    assert is_function(effective[:stream_error_normalizer], 2)
    assert effective[:stream_error_normalizer] != raw_normalizer

    assert effective[:stream_error_normalizer] ==
             (&OhMyJido.Models.Subscription.normalize_stream_error/2)

    model = ReqLLM.model!(context.model)

    assert %OhMyJido.Auth.Error{provider: :openai} =
             effective[:stream_error_normalizer].(
               %{response_body: %{secret: "fixture-secret"}},
               model
             )

    synchronous = %{config | streaming: false}

    assert {:ok, sync_override} =
             Transformer.transform_request(request(synchronous, state), state, synchronous, %{
               oh_my_jido: context
             })

    assert sync_override.llm_opts[:telemetry] == [payloads: :none]

    assert sync_override.llm_opts[:stream_error_normalizer] ==
             (&OhMyJido.Models.Subscription.normalize_stream_error/2)
  end

  test "explicit API-key credentials admit the next native OpenRouter turn without unrelated auth or server context" do
    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})

    context = %{
      context(registry, {CredentialsHost, counter: counter, observer: self()})
      | model: %{provider: :openrouter, id: "openai/gpt-4o"},
        tools: []
    }

    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil) |> State.put_llm_response_id("previous-route-response")
    base = request(config, state)

    base = %{
      base
      | llm_opts:
          Keyword.put(base.llm_opts, :provider_options,
            previous_response_id: state.llm_response_id
          )
    }

    assert {:ok, override} =
             Transformer.transform_request(base, state, config, %{
               oh_my_jido: context
             })

    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer fixture-key-generation-1"
             ]

      body = conn |> Req.Test.raw_body() |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["model"] == "openai/gpt-4o"

      Req.Test.json(conn, %{
        id: "openrouter-fixture-response",
        object: "chat.completion",
        model: "openai/gpt-4o",
        choices: [
          %{
            index: 0,
            message: %{role: "assistant", content: "Native admission succeeded."},
            finish_reason: "stop"
          }
        ],
        usage: %{prompt_tokens: 12, completion_tokens: 4, total_tokens: 16}
      })
    end

    assert {:ok, response} =
             ReqLLM.generate_text(
               override.model,
               override.messages,
               Keyword.put(override.llm_opts, :req_http_options, plug: plug)
             )

    assert ReqLLM.Response.text(response) == "Native admission succeeded."
  end

  test "production diagnostic callback binds safe failures to the actual model rather than reason metadata" do
    model = LLMDB.Model.new!(%{id: "bound-model", provider: :anthropic})

    reason = %{
      status: 429,
      provider: :openai,
      response_body: %{
        "error" => %{"code" => "rate_limit_exceeded", "message" => "Bearer fixture-secret-token"}
      },
      cause: %{authorization: "Bearer fixture-secret-token"},
      headers: %{"authorization" => "Bearer fixture-secret-token"}
    }

    error = OhMyJido.Models.Subscription.normalize_stream_error(reason, model)
    assert %OhMyJido.Auth.Error{provider: :anthropic, code: :rate_limited, status: 429} = error
    refute inspect(error) =~ "fixture-secret-token"
    refute Map.has_key?(Map.from_struct(error), :response_body)
    refute Map.has_key?(Map.from_struct(error), :cause)
    assert :cancelled = OhMyJido.Models.Subscription.normalize_stream_error(:cancelled, model)

    profile = %{model | provider: OhMyJido.Models.Subscription.provider_id()}

    assert %OhMyJido.Auth.Error{provider: :openai} =
             OhMyJido.Models.Subscription.normalize_stream_error(reason, profile)
  end

  test "secret registry refusal and GenServer call exits return only a safe failure atom" do
    counter = start_supervised!({Agent, fn -> 0 end})
    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)

    for mode <- [:refuse, :exit] do
      spec =
        Supervisor.child_spec({Registry, observer: self(), mode: mode},
          id: {Registry, mode},
          restart: :temporary
        )

      registry = start_supervised!(spec)
      context = context(registry, {CredentialsHost, counter: counter, observer: self()})

      result =
        Transformer.transform_request(request(config, state), state, config, %{
          oh_my_jido: context
        })

      assert result == {:error, :secret_registration_failed}
      refute inspect(result) =~ "fixture-key-generation"
      assert_receive {:registration_attempt, secrets}
      assert Enum.any?(secrets, &String.starts_with?(&1, "fixture-key-generation-"))
    end

    refute_receive :context_projection
  end

  test "host account references can be durable opaque tuples without credential maps" do
    counter = start_supervised!({Agent, fn -> 0 end})
    registry = start_supervised!({Registry, observer: self()})
    selected = {:host_account, "opaque-registration"}

    context = %{
      context(registry, {CredentialsHost, counter: counter, observer: self()})
      | account: selected
    }

    config = Config.new(model: :fast, tools: [])
    state = State.new("Inspect", nil)

    assert {:ok, _override} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: context
             })

    assert_receive {:credential_request, ^selected}
  end

  test "subscription requests use the installed public Responses profile and reject explicit forbidden preferences" do
    registry = start_supervised!({Registry, observer: self()})
    context = context(registry, {SubscriptionHost, []})
    state = State.new("Inspect", nil)
    config = Config.new(model: :fast, tools: [])
    base = request(config, state)

    base = %{
      base
      | llm_opts:
          Keyword.put(base.llm_opts, :provider_options,
            previous_response_id: "generated-previous-id"
          )
    }

    assert {:ok, override} =
             Transformer.transform_request(base, state, config, %{oh_my_jido: context})

    assert override.model.id == context.model.id
    assert override.llm_opts[:base_url] == "https://api.openai.com/v1"
    assert override.llm_opts[:auth_mode] == :oauth
    assert override.llm_opts[:provider_options][:access_token] == "fixture-subscription-token"
    assert override.llm_opts[:provider_options][:store] == false
    refute Keyword.has_key?(override.llm_opts[:provider_options], :previous_response_id)
    assert is_function(override.llm_opts[:on_finch_request], 1)
    assert_receive {:registered_secrets, secrets}
    assert "fixture-subscription-token" in secrets

    forbidden = Config.new(model: :fast, tools: [], llm_opts: [temperature: 0.7])

    assert {:error, %OhMyJido.Auth.Error{}} =
             Transformer.transform_request(request(forbidden, state), state, forbidden, %{
               oh_my_jido: context
             })

    nonstreaming = %{config | streaming: false}

    assert {:error, :subscription_streaming_required} =
             Transformer.transform_request(request(nonstreaming, state), state, nonstreaming, %{
               oh_my_jido: context
             })

    mismatch = %{context | model: %{id: "wrong-provider", provider: :anthropic}}

    assert {:error, %OhMyJido.Auth.Error{}} =
             Transformer.transform_request(request(config, state), state, config, %{
               oh_my_jido: mismatch
             })
  end

  test "the native Jido runner executes only the granted registry with an explicit script" do
    root =
      Path.join(System.tmp_dir!(), "omj-transform-fixture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "fixture.ex"), "observed fixture contents")
    on_exit(fn -> File.rm_rf!(root) end)

    script =
      expect_react do
        user("Inspect")
        call("read_fixture", %{path: "fixture.ex"})
        call("edit_fixture", %{path: "fixture.ex"})
        answer("Inspected with the read-only tool")
      end

    context = %{context(nil, {FixtureHost, observer: self()}) | account: nil, workspace: root}

    config =
      Config.new(
        model: :fast,
        tools: [ReadAction, EditAction],
        request_transformer: Transformer,
        llm_opts: react_llm_opts(script)
      )

    result = Jido.AI.Reasoning.ReAct.run("Inspect", config, context: %{oh_my_jido: context})
    assert_final_answer(result, "Inspected with the read-only tool")
    assert_tool_called(result, "read_fixture", %{path: "fixture.ex"})
    assert_tool_called(result, "edit_fixture", %{path: "fixture.ex"})
    assert_no_runtime_failure(result)

    completed =
      result.trace
      |> Enum.filter(&(&1.kind == :tool_completed))
      |> Map.new(fn event ->
        content = Jido.AI.Turn.format_tool_result_content(event.data.result)
        {event.tool_name, Jason.decode!(content)}
      end)

    assert %{"ok" => true, "result" => %{"content" => "observed fixture contents"}} =
             completed["read_fixture"]

    assert %{"ok" => false} = completed["edit_fixture"]
    assert_receive {:authorized, :read, %{path: "fixture.ex"}}

    assert File.read!(Path.join(root, "fixture.ex")) == "observed fixture contents"
  end

  defp context(coordinator, host) do
    %Context{
      session_id: "transform-session",
      workspace: "/workspace",
      permissions: MapSet.new([:read]),
      coordinator: coordinator,
      account: "account-ref",
      model: %{id: "turn-model", provider: :openai, capabilities: %{tools: %{enabled: true}}},
      tools: [ReadAction, EditAction],
      host: host,
      metadata: %{
        runtime_config: %{
          instructions: "Host rule: avoid unrelated edits",
          allow_test_scripts: true
        }
      }
    }
  end

  defp request(config, state) do
    %{
      messages: Jido.AI.Context.to_messages(state.context),
      model: config.model,
      tools: config.tools,
      llm_opts: Config.llm_opts(config)
    }
  end
end
