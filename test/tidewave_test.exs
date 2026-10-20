defmodule OhMyJido.TidewaveTest do
  use ExUnit.Case, async: false

  alias OhMyJido.Context
  alias OhMyJido.Extensions.{MCP, Tidewave}
  alias OhMyJido.Intelligence.Stdio

  @inspection ~w(get_logs)
  @tools @inspection ++ ~w(get_docs get_source_location project_eval clear_cache)
  @port 41_073
  @target "http://127.0.0.1:#{@port}/tidewave/mcp"

  setup do
    root =
      Path.join(System.tmp_dir!(), "oh_my_jido_tidewave_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    context = %Context{
      session_id: "tidewave-#{System.unique_integer([:positive])}",
      workspace: root,
      permissions: MapSet.new([:mcp]),
      host: {__MODULE__.PolicyHost, [owner: self()]},
      limits: %{extension_input_bytes: 16_384, extension_result_bytes: 32_768}
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{context: context, root: root}
  end

  test "owned JSONL discovery is scoped by effective grants and hides the trusted port", %{
    context: context
  } do
    server = fixture(context)
    opts = tidewave_opts(server)
    context = bind(context, opts)

    assert {:ok, initialized} = run(context, %{operation: "initialize"})
    assert initialized.trusted == false
    assert initialized.target == @target
    assert initialized.mode == :live
    assert initialized.identity.session_id == context.session_id
    assert initialized.identity.workspace == context.workspace
    assert initialized.identity.protocol == :mcp
    assert_schema_pinned(initialized.result["tools"], @inspection)

    assert {:ok, listed} = run(context, %{operation: "list_tools"})
    assert_schema_pinned(listed.result["tools"], @inspection)
    assert listed.result["nextCursor"] == "owned-next-page"
    assert listed.identity.id == initialized.identity.id

    refute_receive {:tidewave_authorization, :live_eval, _effect}
  end

  test "explicit tool allowlist stays authoritative even with the live grant", %{context: context} do
    context = live(context)
    server = fixture(context)
    opts = tidewave_opts(server, tools: MapSet.new(["get_docs", "project_eval"]))
    context = bind(context, opts)

    assert {:ok, initialized} = run(context, %{operation: "initialize"})
    assert_schema_pinned(initialized.result["tools"], ["get_docs", "project_eval"])

    assert {:ok, listed} = run(context, %{operation: "list_tools"})
    assert_schema_pinned(listed.result["tools"], ["get_docs", "project_eval"])
    assert Enum.all?(listed.result["tools"], &(&1["annotations"]["readOnlyHint"] == false))

    assert {:error, {:mcp_tool_not_granted, "clear_cache"}} =
             Tidewave.invoke(context, %{operation: :call_tool, name: "clear_cache"}, opts)

    assert {:error, _native_action_error} =
             run(context, %{operation: "call_tool", name: "clear_cache"})

    assert calls(context) == []
  end

  test "trusted port and explicit allowlist are validated before policy or protocol I/O", %{
    context: context
  } do
    server = fixture(context)
    opts = tidewave_opts(server)

    for invalid <- [nil, 0, -1, 65_536, "41073", 41_073.0] do
      assert {:error, :invalid_tidewave_port} =
               Tidewave.invoke(
                 context,
                 %{operation: :initialize},
                 Keyword.put(opts, :port, invalid)
               )

      assert {:error, :invalid_tidewave_port} =
               Tidewave.close_session(context, Keyword.put(opts, :port, invalid))
    end

    assert {:error, :tidewave_tools_allowlist_required} =
             Tidewave.invoke(context, %{operation: :initialize}, Keyword.delete(opts, :tools))

    assert {:error, :invalid_tidewave_tools_allowlist} =
             Tidewave.invoke(
               context,
               %{operation: :initialize},
               Keyword.put(opts, :tools, [:get_docs])
             )

    assert messages(context) == []
    refute_receive {:tidewave_authorization, :mcp, %{operation: :initialize}}
  end

  test "model port and target selectors are rejected rather than overwritten", %{context: context} do
    server = fixture(context)
    opts = tidewave_opts(server)
    context = bind(context, opts)
    assert {:ok, _initialized} = run(context, %{operation: "initialize"})

    for key <- ["port", :port, "target", :target, "host", :host, "url", :url, "node", :node] do
      request = %{
        operation: :call_tool,
        name: "get_docs",
        arguments: Map.put(%{"reference" => "Enum"}, key, @port)
      }

      assert {:error, :tidewave_target_selector_forbidden} =
               Tidewave.invoke(context, request, opts)

      assert {:error, :tidewave_target_selector_forbidden} =
               Tidewave.invoke(context, Map.put(%{operation: :list_tools}, key, @port), opts)
    end

    assert {:error, _native_action_error} =
             run(context, %{
               operation: "call_tool",
               name: "get_docs",
               arguments: %{"reference" => "Enum", "port" => @port}
             })

    assert calls(context) == []
  end

  test "direct invocation cannot bypass either grant or denied host policy", %{context: context} do
    server = fixture(context)
    opts = tidewave_opts(server)
    no_mcp = %{context | permissions: MapSet.new([:live_eval])}

    assert {:error, {:permission_denied, :mcp}} =
             Tidewave.invoke(no_mcp, %{operation: :initialize}, opts)

    assert {:error, {:permission_denied, :mcp}} =
             Tidewave.invoke(no_mcp, eval_request(), opts)

    for name <- ["get_docs", "get_source_location", "project_eval", "clear_cache"] do
      assert {:error, {:permission_denied, :live_eval}} =
               Tidewave.invoke(context, %{operation: :call_tool, name: name}, opts)
    end

    for capability <- [:mcp, :live_eval] do
      denied = %{live(context) | host: {__MODULE__.PolicyHost, [owner: self(), deny: capability]}}
      assert {:error, :fixture_policy_denied} = Tidewave.invoke(denied, eval_request(), opts)
    end

    assert calls(context) == []
    assert messages(context) == []
  end

  test "the normal MCP approval and targeted live approval remain explicit", %{context: context} do
    server = fixture(context)
    opts = tidewave_opts(server)
    local = %{live(context) | host: {OhMyJido.Host.Local, []}}
    assert {:error, :approval_required} = Tidewave.invoke(local, eval_request(), opts)

    targeted = %{
      live(context)
      | host: {__MODULE__.PolicyHost, [owner: self(), approval: :live_eval]}
    }

    assert {:error, :approval_required} = Tidewave.invoke(targeted, eval_request(), opts)
    targeted = bind(targeted, opts)

    assert {:error, _native_action_error} =
             run(targeted, %{operation: "call_tool", name: "project_eval"})

    assert calls(context) == []
  end

  test "live authorization identifies the real target and bounded digests without raw secrets", %{
    context: context
  } do
    context = live(context)
    server = fixture(context)
    opts = tidewave_opts(server)
    context = bind(context, opts)
    assert {:ok, _initialized} = run(context, %{operation: "initialize"})
    source = ~s|IO.puts("fixture-secret-do-not-copy")|
    arguments = %{"code" => source, "arguments" => ["other-private-value"], "timeout" => 1_000}

    assert {:ok, _response} =
             run(context, %{operation: "call_tool", name: "project_eval", arguments: arguments})

    assert_receive {:tidewave_authorization, :live_eval, effect}
    assert effect.operation == :call_tool
    assert effect.tool == "project_eval"
    assert effect.target == @target
    assert effect.mode == :live
    assert effect.sensitive
    assert effect.code_sha256 == digest(source)

    assert effect.arguments_sha256 ==
             digest(Jason.encode_to_iodata!(Map.put(arguments, "port", @port)))

    assert byte_size(effect.intent) <= 128
    refute String.contains?(inspect(effect), "fixture-secret-do-not-copy")
    refute String.contains?(inspect(effect), "other-private-value")
    refute Map.has_key?(effect, :code)
    refute Map.has_key?(effect, :arguments)

    assert {:ok, _response} =
             run(context, %{
               operation: "call_tool",
               name: "clear_cache",
               arguments: %{"key" => "cache"}
             })

    assert_receive {:tidewave_authorization, :live_eval, other_effect}
    assert other_effect.tool == "clear_cache"
    assert other_effect.target == @target
    assert other_effect.sensitive
    assert byte_size(other_effect.intent) <= 128
    refute Map.has_key?(other_effect, :code_sha256)
  end

  test "direct requests enforce input budgets and preserve completed-result limits", %{
    context: context
  } do
    server = fixture(context)
    opts = tidewave_opts(server)
    assert {:ok, _initialized} = Tidewave.invoke(context, %{operation: :initialize}, opts)
    small_input = %{context | limits: Map.put(context.limits, :extension_input_bytes, 128)}

    request = %{
      operation: :call_tool,
      name: "get_docs",
      arguments: %{"reference" => String.duplicate("x", 256)}
    }

    assert {:error, {:mcp_input_limit, 128}} = Tidewave.invoke(small_input, request, opts)
    assert calls(context) == []

    small_result = %{context | limits: Map.put(context.limits, :extension_result_bytes, 16)}

    assert {:error, %{reason: :mcp_result_limit, effect: :completed, result: :unavailable}} =
             Tidewave.invoke(
               small_result,
               %{operation: :call_tool, name: "get_logs", arguments: %{"tail" => 1}},
               opts
             )

    assert [_call] = calls(context)
  end

  test "unavailable native discovery is an error, never a fabricated catalog or fallback", %{
    context: context
  } do
    server = fixture(context, "list-error")
    context = bind(context, tidewave_opts(server))
    assert {:ok, _initialized} = run(context, %{operation: "initialize"})
    assert {:error, _native_action_error} = run(context, %{operation: "list_tools"})
    assert Enum.count(messages(context), &(&1["method"] == "tools/list")) == 1
    assert calls(context) == []

    assert {:error, {:capability_unavailable, :mcp}} =
             Tidewave.invoke(
               context,
               eval_request(),
               Keyword.delete(tidewave_opts(server), :server)
             )
  end

  test "malformed discovery never manufactures an empty successful catalog", %{context: context} do
    server = fixture(context, "list-malformed")
    opts = tidewave_opts(server)
    context = bind(context, opts)
    assert {:ok, _initialized} = run(context, %{operation: "initialize"})

    assert {:error, %{details: %{reason: :invalid_mcp_tool_list}}} =
             run(context, %{operation: "list_tools"})

    assert Enum.count(messages(context), &(&1["method"] == "tools/list")) == 1
    assert calls(context) == []
  end

  test "initialization failure never triggers a live tool or an implicit fallback", %{
    context: context
  } do
    server = fixture(context, "initialize-error")
    context = bind(context, tidewave_opts(server))
    assert {:error, _native_action_error} = run(context, %{operation: "initialize"})
    assert Enum.count(messages(context), &(&1["method"] == "initialize")) == 1
    assert calls(context) == []
  end

  test "a dropped executed call preserves the real unknown-outcome marker without retry", %{
    context: context
  } do
    context = live(context)
    server = fixture(context, "drop")
    opts = tidewave_opts(server)
    context = bind(context, opts)
    assert {:ok, _initialized} = run(context, %{operation: "initialize"})
    monitor = Process.monitor(server)

    assert {:error,
            %{
              details: %{
                reason: %{reason: :mcp_tool_outcome_unknown, effect: :uncertain, cause: _cause},
                retry: false
              }
            }} =
             run(context, %{
               operation: "call_tool",
               name: "project_eval",
               arguments: %{"code" => ":ok"}
             })

    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 5_000
    assert [_call] = calls(context)
    assert :ok = Tidewave.close_session(context, opts)
  end

  test "session identity and lifecycle stay scoped, including cleanup after grant revocation", %{
    context: context
  } do
    server = fixture(context)
    opts = tidewave_opts(server)
    assert {:ok, initialized} = Tidewave.invoke(context, %{operation: :initialize}, opts)
    foreign = %{context | session_id: "another-session"}

    assert {:error, :protocol_identity_mismatch} =
             Tidewave.invoke(foreign, %{operation: :list_tools}, opts)

    assert {:error, :protocol_identity_mismatch} = Tidewave.close_session(foreign, opts)
    assert Process.alive?(server)
    assert {:ok, identity} = Stdio.bind(server, context)
    assert identity.id == initialized.identity.id
    monitor = Process.monitor(server)
    revoked = %{context | permissions: MapSet.new()}
    assert :ok = Tidewave.close_session(revoked, opts)
    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 5_000
    assert :ok = Tidewave.close_session(revoked, opts)
  end

  test "explicit close delegates confirmed cleanup and preserves target identity", %{
    context: context
  } do
    server = fixture(context)
    opts = tidewave_opts(server)
    context = bind(context, opts)
    assert {:ok, initialized} = run(context, %{operation: "initialize"})
    monitor = Process.monitor(server)

    assert {:ok,
            %{
              closed: true,
              cleanup: :confirmed,
              identity: identity,
              target: @target,
              mode: :live,
              trusted: false
            }} =
             run(context, %{operation: "close"})

    assert identity.id == initialized.identity.id
    assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 5_000
  end

  defp fixture(context, scenario \\ "normal") do
    opts = [
      executable: System.find_executable("elixir"),
      args: [Path.expand("support/tidewave_proxy.ex", __DIR__), scenario],
      context: context,
      env: [{"ERL_FLAGS", "+S 2:2 +A 1"}],
      shutdown_timeout_ms: 1_000
    ]

    start_supervised!({MCP, opts})
  end

  defp tidewave_opts(server, opts \\ []),
    do: Keyword.merge([server: server, port: @port, tools: @tools], opts)

  defp bind(context, opts), do: %{context | adapters: %{mcp: {Tidewave, opts}}}
  defp live(context), do: %{context | permissions: MapSet.put(context.permissions, :live_eval)}

  defp eval_request,
    do: %{operation: :call_tool, name: "project_eval", arguments: %{"code" => ":ok"}}

  defp run(context, params),
    do: Jido.Exec.run(OhMyJido.Tools.MCP, params, %{oh_my_jido: context}, timeout: 15_000)

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp calls(context), do: Enum.filter(messages(context), &(&1["method"] == "tools/call"))

  defp messages(context) do
    case File.read(Path.join(context.workspace, "tidewave-requests.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp assert_schema_pinned(tools, names) do
    assert Enum.sort(Enum.map(tools, & &1["name"])) == Enum.sort(names)

    for tool <- tools do
      schema = tool["inputSchema"]
      refute Map.has_key?(schema["properties"], "port")
      refute "port" in schema["required"]
    end
  end

  defmodule PolicyHost do
    @behaviour OhMyJido.Host

    def authorize(_context, capability, effect, opts) do
      send(opts[:owner], {:tidewave_authorization, capability, effect})

      cond do
        opts[:deny] == capability -> {:error, :fixture_policy_denied}
        opts[:approval] == capability -> {:approval, %{kind: :effect, effect: effect}}
        true -> :ok
      end
    end

    def credentials(_context, _account, _opts), do: {:error, :not_available}
    def question(_context, _question, _opts), do: {:error, :not_available}

    def invoke(context, capability, request, opts),
      do: OhMyJido.Host.Local.invoke(context, capability, request, opts)
  end
end
