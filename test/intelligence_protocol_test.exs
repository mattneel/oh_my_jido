defmodule OhMyJido.IntelligenceProtocolTest do
  use ExUnit.Case, async: false

  alias OhMyJido.Context
  alias OhMyJido.Extensions.MCP
  alias OhMyJido.Intelligence.{DAP, LSP, Stdio}

  setup do
    root =
      Path.join(System.tmp_dir!(), "oh_my_jido_protocol_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "sample.ex"),
      "defmodule Sample do\n  def value(), do: 1\n  def twice(), do: value() + value()\nend\n"
    )

    File.write!(Path.join(root, "program.steps"), "set counter 1\nadd counter 2\nadd counter 4\n")
    File.write!(Path.join(root, "resource.txt"), "owned resource\n")

    context = %Context{
      session_id: "protocol-#{System.unique_integer([:positive])}",
      workspace: root,
      permissions: MapSet.new([:lsp, :debug, :mcp, :read, :edit]),
      host: {__MODULE__.FixtureHost, []},
      limits: %{extension_result_bytes: 32_768}
    }

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, context: context}
  end

  test "LSP navigates real source, publishes diagnostics, and applies a guarded rename", %{
    context: context
  } do
    server = fixture(LSP, "lsp", context)
    context = %{context | adapters: %{lsp: {LSP, [server: server]}}}

    assert {:ok, %{capabilities: capabilities, identity: identity}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "initialize"})

    assert capabilities["renameProvider"]

    assert {:ok, %{snapshot: snapshot}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "sample.ex"})

    assert {:ok, %{result: [%{"name" => "value"} | _]}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "symbols", path: "sample.ex"})

    assert {:ok, %{result: %{"range" => %{"start" => %{"line" => 1}}}}} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "definition",
               path: "sample.ex",
               line: 2,
               character: 22
             })

    assert {:ok, %{result: references}} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "references",
               path: "sample.ex",
               line: 2,
               character: 22
             })

    assert [_, _, _] = references

    assert {:ok, %{diagnostics: []}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "diagnostics", path: "sample.ex"})

    assert {:ok, %{applied: true, files: [%{path: "sample.ex"}]}} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "rename",
               path: "sample.ex",
               line: 1,
               character: 7,
               new_name: "answer",
               snapshot: snapshot,
               apply: true
             })

    assert File.read!(Path.join(context.workspace, "sample.ex")) ==
             "defmodule Sample do\n  def answer(), do: 1\n  def twice(), do: answer() + answer()\nend\n"

    assert {:ok, %{result: [%{"name" => "answer"} | _]}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "symbols", path: "sample.ex"})

    assert {:error, _} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "rename",
               path: "sample.ex",
               line: 1,
               character: 7,
               new_name: "stale",
               snapshot: snapshot,
               apply: true
             })

    monitor = Process.monitor(server)
    assert {:ok, %{closed: true}} = run(OhMyJido.Tools.LSP, context, %{operation: "shutdown"})
    assert_receive {:DOWN, ^monitor, :process, ^server, _}, 5_000
    assert_resource_closed(identity.os_pid)
  end

  test "LSP surfaces malformed source and cannot write out-of-root server edits", %{
    context: context
  } do
    server = fixture(LSP, "lsp", context)
    context = %{context | adapters: %{lsp: {LSP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.LSP, context, %{operation: "initialize"})
    File.write!(Path.join(context.workspace, "broken.ex"), "defmodule Broken do\n")
    assert {:ok, _} = run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "broken.ex"})

    assert {:ok, %{diagnostics: [%{"severity" => 1} | _]}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "diagnostics", path: "broken.ex"})

    assert {:error, _} =
             run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "../outside.ex"})

    assert {:ok, %{snapshot: snapshot}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "sample.ex"})

    before = File.read!(Path.join(context.workspace, "sample.ex"))

    assert {:error, _} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "rename",
               path: "sample.ex",
               line: 1,
               character: 7,
               new_name: "escape",
               snapshot: snapshot,
               apply: true
             })

    assert File.read!(Path.join(context.workspace, "sample.ex")) == before
  end

  @tag :protocol_repair
  test "stale versioned rename rejects all documents even with current filesystem snapshots", %{
    context: context
  } do
    other_path = Path.join(context.workspace, "a_first.ex")
    File.write!(other_path, "defmodule First do\nend\n")
    server = fixture(LSP, "lsp", context, scenario: "stale-rename")
    context = %{context | adapters: %{lsp: {LSP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.LSP, context, %{operation: "initialize"})

    assert {:ok, %{snapshot: other_snapshot}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "a_first.ex"})

    assert {:ok, %{version: 1}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "sample.ex"})

    source_path = Path.join(context.workspace, "sample.ex")
    source = source_path |> File.read!() |> String.replace("value", "other")
    File.write!(source_path, source)

    assert {:ok, %{version: 2, snapshot: snapshot}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "change", path: "sample.ex"})

    other_before = File.read!(other_path)

    assert {:error, _} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "rename",
               path: "sample.ex",
               line: 1,
               character: 7,
               new_name: "answer",
               snapshot: snapshot,
               snapshots: %{"a_first.ex" => other_snapshot},
               apply: true
             })

    assert File.read!(source_path) == source
    assert File.read!(other_path) == other_before
  end

  @tag :protocol_repair
  test "matching versioned document edits remain applicable", %{context: context} do
    server = fixture(LSP, "lsp", context, scenario: "versioned-rename")
    context = %{context | adapters: %{lsp: {LSP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.LSP, context, %{operation: "initialize"})

    assert {:ok, %{snapshot: snapshot, version: 1}} =
             run(OhMyJido.Tools.LSP, context, %{operation: "open", path: "sample.ex"})

    assert {:ok, %{applied: true}} =
             run(OhMyJido.Tools.LSP, context, %{
               operation: "rename",
               path: "sample.ex",
               line: 1,
               character: 7,
               new_name: "answer",
               snapshot: snapshot,
               apply: true
             })

    assert File.read!(Path.join(context.workspace, "sample.ex")) =~ "def answer()"
  end

  test "DAP breakpoints stop execution, stepping changes variables, and terminate closes ownership",
       %{context: context} do
    server = fixture(DAP, "dap", context)
    context = %{context | adapters: %{debug: {DAP, [server: server]}}}

    assert {:ok, %{identity: identity}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "initialize"})

    assert identity.os_pid > 0

    assert {:ok, %{request_id: launch_id}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "launch", program: "program.steps"})

    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_initialized"})

    assert {:ok, %{result: %{"breakpoints" => [%{"verified" => true}]}}} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "breakpoints",
               path: "program.steps",
               lines: [2]
             })

    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "configuration_done"})

    assert {:ok, _} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "await_launch",
               request_id: launch_id
             })

    assert {:ok, %{event: %{"event" => "stopped"}}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "wait_stopped"})

    assert {:ok, %{result: %{"stackFrames" => [%{"id" => frame_id}]}}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "stack_trace", thread_id: 1})

    assert {:ok, %{result: %{"scopes" => [%{"variablesReference" => variables_ref}]}}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "scopes", frame_id: frame_id})

    assert {:ok, %{result: %{"variables" => [%{"name" => "counter", "value" => "1"}]}}} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "variables",
               variables_reference: variables_ref
             })

    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "step_over", thread_id: 1})
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_stopped"})

    assert {:ok, %{result: %{"variables" => [%{"name" => "counter", "value" => "3"}]}}} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "variables",
               variables_reference: variables_ref
             })

    monitor = Process.monitor(server)
    assert {:ok, %{closed: true}} = run(OhMyJido.Tools.Debug, context, %{operation: "terminate"})
    assert_receive {:DOWN, ^monitor, :process, ^server, _}, 5_000
    assert_resource_closed(identity.os_pid)
  end

  @tag :protocol_repair
  test "an expired launch await can collect its eventual response without another launch", %{
    context: context
  } do
    server = fixture(DAP, "dap", context)
    context = %{context | adapters: %{debug: {DAP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "initialize"})

    assert {:ok, %{request_id: launch_id}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "launch", program: "program.steps"})

    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_initialized"})
    assert {:error, _} = Stdio.await_response(server, launch_id, 20)
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "configuration_done"})
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_stopped"})

    assert {:ok, %{result: %{"launchCount" => 1}}} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "await_launch",
               request_id: launch_id
             })
  end

  @tag :protocol_repair
  test "a dead launch consumer cannot consume the eventual launch response", %{context: context} do
    server = fixture(DAP, "dap", context)
    context = %{context | adapters: %{debug: {DAP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "initialize"})

    assert {:ok, %{request_id: launch_id}} =
             run(OhMyJido.Tools.Debug, context, %{operation: "launch", program: "program.steps"})

    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_initialized"})
    :erlang.trace(server, true, [:receive])
    consumer = spawn(fn -> Stdio.await_response(server, launch_id, 5_000) end)
    monitor = Process.monitor(consumer)

    assert_receive {:trace, ^server, :receive, {:"$gen_call", {^consumer, _tag}, _request}},
                   1_000

    :erlang.trace(server, false, [:receive])
    assert {:ok, _} = Stdio.bind(server, context)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^consumer, :killed}
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "configuration_done"})
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_stopped"})

    assert {:ok, %{result: %{"launchCount" => 1}}} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "await_launch",
               request_id: launch_id
             })
  end

  @tag :protocol_repair
  test "bounded debug launch preserves a usable receipt after submission", %{context: context} do
    server = fixture(DAP, "dap", context)
    context = %{context | adapters: %{debug: {DAP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "initialize"})
    bounded = %{context | limits: %{extension_result_bytes: 64}}

    assert {:ok, %{request_id: launch_id, status: :pending} = receipt} =
             OhMyJido.Tools.Debug.run(
               %{operation: "launch", program: "program.steps"},
               bounded
             )

    assert byte_size(Jason.encode!(receipt)) <= 64
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_initialized"})
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "configuration_done"})

    assert {:ok, %{result: %{"launchCount" => 1}}} =
             run(OhMyJido.Tools.Debug, context, %{
               operation: "await_launch",
               request_id: launch_id
             })
  end

  @tag :protocol_repair
  test "an impossible debug receipt budget rejects launch before invoking the adapter", %{
    context: context
  } do
    context = %{
      context
      | host: {__MODULE__.RecordingHost, owner: self()},
        limits: %{extension_result_bytes: 4}
    }

    assert {:error, _} =
             OhMyJido.Tools.Debug.run(
               %{operation: "launch", program: "program.steps"},
               context
             )

    refute_receive :host_invoked
  end

  @tag :protocol_repair
  test "native launch admission accounts for the actual request ID before submission", %{
    context: context
  } do
    server = fixture(DAP, "dap", context)
    context = %{context | adapters: %{debug: {DAP, [server: server]}}}
    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "initialize"})

    for _ <- 1..8 do
      assert {:ok, _} = Stdio.request(server, "threads", %{})
    end

    limit = byte_size(Jason.encode!(%{request_id: 1, status: :pending}))
    bounded = %{context | limits: %{extension_result_bytes: limit}}

    assert {:error, _} =
             OhMyJido.Tools.Debug.run(
               %{operation: "launch", program: "program.steps"},
               bounded
             )

    refute File.exists?(Path.join(context.workspace, "dap-launch-count"))

    assert {:ok, _} =
             run(OhMyJido.Tools.Debug, context, %{operation: "launch", program: "program.steps"})

    assert {:ok, _} = run(OhMyJido.Tools.Debug, context, %{operation: "wait_initialized"})
    assert File.read!(Path.join(context.workspace, "dap-launch-count")) == "1"
  end

  test "MCP calls only scoped tools and reads actual granted resources", %{context: context} do
    server = fixture(MCP, "mcp", context)
    uri = "file://" <> Path.join(context.workspace, "resource.txt")

    context = %{
      context
      | adapters: %{mcp: {MCP, [server: server, tools: ["sum"], resources: [uri]]}}
    }

    assert {:ok, %{identity: identity}} =
             run(OhMyJido.Tools.MCP, context, %{operation: "initialize"})

    assert {:ok, %{"params" => %{"code" => -32_601}}} =
             OhMyJido.Intelligence.Stdio.await_event(server, "fixture/reverseRequestDenied")

    assert {:ok, %{result: %{"tools" => [%{"name" => "sum"}]}}} =
             run(OhMyJido.Tools.MCP, context, %{operation: "list_tools"})

    assert {:ok, %{result: %{"resources" => [%{"uri" => ^uri}]}}} =
             run(OhMyJido.Tools.MCP, context, %{operation: "list_resources"})

    assert {:ok, %{result: %{"content" => [%{"text" => "42"}]}}} =
             run(OhMyJido.Tools.MCP, context, %{
               operation: "call_tool",
               name: "sum",
               arguments: %{"values" => [19, 23]}
             })

    assert {:error, {:mcp_tool_not_granted, "write_file"}} =
             OhMyJido.Tools.MCP.run(
               %{operation: "call_tool", name: "write_file", arguments: %{}},
               context
             )

    refute File.exists?(Path.join(context.workspace, "forbidden-effect"))

    assert {:ok, %{result: %{"contents" => [%{"text" => "owned resource\n"}]}}} =
             run(OhMyJido.Tools.MCP, context, %{operation: "read_resource", uri: uri})

    assert {:error, {:mcp_resource_not_granted, _}} =
             OhMyJido.Tools.MCP.run(
               %{operation: "read_resource", uri: "file:///not-granted"},
               context
             )

    monitor = Process.monitor(server)
    assert {:ok, %{closed: true}} = run(OhMyJido.Tools.MCP, context, %{operation: "close"})
    assert_receive {:DOWN, ^monitor, :process, ^server, _}, 5_000
    assert_resource_closed(identity.os_pid)
  end

  @tag :protocol_repair
  test "MCP timeout cancels the submitted request using MCP and leaves its effect uncertain", %{
    context: context
  } do
    server = fixture(MCP, "mcp", context)
    context = %{context | adapters: %{mcp: {MCP, [server: server, tools: ["pending"]]}}}
    assert {:ok, _} = run(OhMyJido.Tools.MCP, context, %{operation: "initialize"})

    assert {:error, %{effect: :uncertain}} =
             OhMyJido.Tools.MCP.run(%{operation: "call_tool", name: "pending"}, context)

    assert File.read!(Path.join(context.workspace, "mcp-effect-submitted")) == "submitted"

    assert {:ok,
            %{
              "calls" => 1,
              "pending" => [],
              "cancellations" => [
                %{
                  "method" => "notifications/cancelled",
                  "params" => %{"requestId" => request_id},
                  "accepted" => true
                }
              ]
            }} = Stdio.request(server, "ping", %{})

    assert is_integer(request_id)
  end

  @tag :protocol_repair
  test "MCP initialization timeout never emits a forbidden initialization cancellation", %{
    context: context
  } do
    server = fixture(MCP, "mcp", context, scenario: "hold-initialize")
    assert {:ok, _} = Stdio.request(server, "ping", %{})
    assert {:error, _} = Stdio.request(server, "initialize", %{}, 20)

    assert {:ok,
            %{
              "cancellations" => [],
              "pending" => [%{"method" => "initialize"}]
            }} = Stdio.request(server, "ping", %{})
  end

  test "denied protocol capabilities never invoke a bound host", %{context: context} do
    host_context = %{
      context
      | permissions: MapSet.new(),
        host: {__MODULE__.RecordingHost, [owner: self()]}
    }

    for {action, operation, capability} <- [
          {OhMyJido.Tools.LSP, "initialize", :lsp},
          {OhMyJido.Tools.Debug, "initialize", :debug},
          {OhMyJido.Tools.MCP, "initialize", :mcp}
        ] do
      assert {:error, {:permission_denied, ^capability}} =
               action.run(%{operation: operation}, %{oh_my_jido: host_context})
    end

    refute_receive :host_invoked
  end

  test "protocol actions reject arbitrary RPC fields and require sensitive-effect approval", %{
    context: context
  } do
    recording = %{context | host: {__MODULE__.RecordingHost, [owner: self()]}}

    for {action, params} <- [
          {OhMyJido.Tools.LSP, %{operation: "initialize", method: "workspace/executeCommand"}},
          {OhMyJido.Tools.Debug, %{operation: "initialize", command: "runInTerminal"}},
          {OhMyJido.Tools.MCP, %{operation: "initialize", method: "sampling/createMessage"}},
          {OhMyJido.Tools.LSP,
           %{
             operation: "rename",
             path: "sample.ex",
             line: 1,
             character: 7,
             new_name: "answer",
             apply: "yes"
           }}
        ] do
      assert {:error, _} = action.run(params, recording)
    end

    refute_receive :host_invoked
    local = %{context | host: {OhMyJido.Host.Local, []}}

    assert {:error, :approval_required} =
             OhMyJido.Tools.Debug.run(%{operation: "launch", program: "program.steps"}, local)

    assert {:error, :approval_required} =
             OhMyJido.Tools.MCP.run(%{operation: "call_tool", name: "sum"}, local)
  end

  test "rename without edit permission never invokes a host and bounded MCP results preserve completed-effect status",
       %{context: context} do
    denied = %{
      context
      | permissions: MapSet.new([:lsp, :read]),
        host: {__MODULE__.RecordingHost, [owner: self()]}
    }

    snapshot = OhMyJido.Files.snapshot(File.read!(Path.join(context.workspace, "sample.ex")))

    assert {:error, {:permission_denied, :edit}} =
             OhMyJido.Tools.LSP.run(
               %{
                 operation: "rename",
                 path: "sample.ex",
                 line: 1,
                 character: 7,
                 new_name: "answer",
                 snapshot: snapshot,
                 apply: true
               },
               denied
             )

    refute_receive :host_invoked
    server = fixture(MCP, "mcp", context)

    bounded = %{
      context
      | adapters: %{mcp: {MCP, [server: server, tools: ["sum"]]}},
        limits: %{extension_result_bytes: 16}
    }

    assert {:error, %{reason: :mcp_result_limit, effect: :completed}} =
             OhMyJido.Tools.MCP.run(%{operation: "initialize"}, bounded)
  end

  test "unavailable protocol capability and foreign-session ownership fail explicitly", %{
    context: context
  } do
    assert {:error, {:capability_unavailable, :lsp}} =
             OhMyJido.Tools.LSP.run(%{operation: "initialize"}, context)

    assert {:error, {:capability_unavailable, :debug}} =
             OhMyJido.Tools.Debug.run(%{operation: "initialize"}, context)

    assert {:error, {:capability_unavailable, :mcp}} =
             OhMyJido.Tools.MCP.run(%{operation: "initialize"}, context)

    server = fixture(LSP, "lsp", context)

    foreign = %{
      context
      | session_id: "different-session",
        adapters: %{lsp: {LSP, [server: server]}}
    }

    assert {:error, :protocol_identity_mismatch} =
             OhMyJido.Tools.LSP.run(%{operation: "initialize"}, foreign)
  end

  test "owner death releases protocol process and extension cleanup is idempotent", %{
    context: context
  } do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    context = %{context | coordinator: owner}
    server = fixture(LSP, "lsp", context)
    assert {:ok, %{os_pid: os_pid}} = OhMyJido.Intelligence.Stdio.bind(server, context)
    monitor = Process.monitor(server)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^server, _}, 5_000
    assert_resource_closed(os_pid)
    context = %{context | adapters: %{lsp: {LSP, [server: server]}}}
    assert :ok = OhMyJido.Extensions.close_session(context)
  end

  test "a crashed external MCP server reports an uncertain effect and closes its owner", %{
    context: context
  } do
    server = fixture(MCP, "mcp", context)
    context = %{context | adapters: %{mcp: {MCP, [server: server, tools: ["crash"]]}}}
    assert {:ok, _} = run(OhMyJido.Tools.MCP, context, %{operation: "initialize"})
    assert {:ok, %{os_pid: os_pid}} = OhMyJido.Intelligence.Stdio.bind(server, context)
    monitor = Process.monitor(server)

    assert {:error, %{reason: :mcp_tool_outcome_unknown, effect: :uncertain}} =
             OhMyJido.Tools.MCP.run(%{operation: "call_tool", name: "crash"}, context)

    assert_receive {:DOWN, ^monitor, :process, ^server, _}, 5_000
    assert_resource_closed(os_pid)
  end

  test "an abruptly killed protocol owner still releases its OS process", %{context: context} do
    server = fixture(LSP, "lsp", context)
    assert {:ok, %{os_pid: os_pid}} = OhMyJido.Intelligence.Stdio.bind(server, context)
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 5_000
    assert_resource_closed(os_pid)
  end

  defp fixture(module, protocol, context, opts \\ []) do
    executable = System.find_executable("elixir")
    script = Path.expand("support/intelligence_server.ex", __DIR__)

    start_supervised!(
      {module,
       Keyword.merge(
         [
           executable: executable,
           args: [script, protocol, Keyword.get(opts, :scenario, "normal")],
           context: context,
           env: [{"ERL_FLAGS", "+S 2:2 +A 1"}],
           shutdown_timeout_ms: 1_000
         ],
         Keyword.delete(opts, :scenario)
       )}
    )
  end

  defp run(action, context, params) do
    Jido.Exec.run(action, params, %{oh_my_jido: context}, max_retries: 0, timeout: 15_000)
  end

  defp assert_resource_closed(pid),
    do: await_resource_closed(pid, System.monotonic_time(:millisecond) + 3_000)

  defp await_resource_closed(pid, deadline) do
    case OhMyJido.Process.capture_identity(pid) do
      {:error, reason} when reason in [:enoent, :esrch] ->
        :ok

      {:ok, %{state: state}} when state in ["Z", "X"] ->
        :ok

      result ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_resource_closed(pid, deadline)
        else
          flunk("Protocol OS resource remains alive: #{inspect(result)}")
        end
    end
  end

  defmodule FixtureHost do
    @behaviour OhMyJido.Host
    def authorize(_context, _capability, _effect, _opts), do: :ok
    def credentials(_context, _account, _opts), do: {:error, :not_available}
    def question(_context, _question, _opts), do: {:error, :not_available}

    def invoke(context, capability, request, opts),
      do: OhMyJido.Host.Local.invoke(context, capability, request, opts)
  end

  defmodule RecordingHost do
    @behaviour OhMyJido.Host
    def authorize(_context, _capability, _effect, _opts), do: :ok
    def credentials(_context, _account, _opts), do: {:error, :not_available}
    def question(_context, _question, _opts), do: {:error, :not_available}

    def invoke(_context, _capability, _request, opts) do
      send(opts[:owner], :host_invoked)
      {:ok, %{}}
    end
  end
end
