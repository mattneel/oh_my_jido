defmodule OhMyJido.ProtocolFixture do
  @moduledoc false

  def run(protocol, scenario) do
    :ok = :io.setopts(:standard_io, binary: true, encoding: :latin1)

    state = %{
      protocol: protocol,
      scenario: scenario,
      seq: 1,
      documents: %{},
      initial_documents: %{},
      document_versions: %{},
      lsp_requests: [],
      lsp_configuration: nil,
      mcp_pending: %{},
      mcp_cancellations: [],
      mcp_calls: 0,
      breakpoints: [],
      line: 1,
      variables: %{},
      instructions: [],
      program: nil,
      launch_request: nil,
      launch_count: 0
    }

    loop(state)
  end

  defp loop(state) do
    case receive_message(state.protocol) do
      :eof ->
        :ok

      message ->
        {response, events, state, exit?} = dispatch(message, state)
        if response, do: send_message(state.protocol, response)
        Enum.each(events, &send_message(state.protocol, &1))
        if exit?, do: :ok, else: loop(state)
    end
  end

  defp receive_message("mcp") do
    case IO.binread(:stdio, :line) do
      :eof -> :eof
      line -> :json.decode(line)
    end
  end

  defp receive_message(_protocol) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :eof

      line ->
        [_, length] = Regex.run(~r/^Content-Length: (\d+)\r?\n$/i, line)
        read_header_end()
        :json.decode(IO.binread(:stdio, String.to_integer(length)))
    end
  end

  defp read_header_end do
    case IO.binread(:stdio, :line) do
      "\r\n" -> :ok
      "\n" -> :ok
      _ -> read_header_end()
    end
  end

  defp send_message(protocol, message) do
    payload =
      message
      |> :json.encode(fn
        nil, _encoder -> "null"
        value, encoder -> :json.encode_value(value, encoder)
      end)
      |> IO.iodata_to_binary()

    framing =
      if protocol == "mcp",
        do: [payload, "\n"],
        else: ["Content-Length: ", Integer.to_string(byte_size(payload)), "\r\n\r\n", payload]

    IO.binwrite(:stdio, framing)
  end

  defp dispatch(%{"method" => "exit"}, state), do: {nil, [], state, true}
  defp dispatch(%{"method" => "notifications/initialized"}, state), do: {nil, [], state, false}
  defp dispatch(%{"method" => "initialized"}, state), do: {nil, [], state, false}

  defp dispatch(
         %{"method" => "textDocument/didOpen", "params" => %{"textDocument" => document}},
         state
       ) do
    uri = document["uri"]

    state = %{
      state
      | documents: Map.put(state.documents, uri, document["text"]),
        initial_documents: Map.put_new(state.initial_documents, uri, document["text"]),
        document_versions: Map.put(state.document_versions, uri, document["version"])
    }

    diagnostic =
      case Code.string_to_quoted(document["text"]) do
        {:ok, _} ->
          []

        {:error, _} ->
          [
            %{
              "range" => range(0, 0, 1),
              "severity" => 1,
              "message" => "Elixir source is not syntactically complete"
            }
          ]
      end

    event = %{
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => %{"uri" => document["uri"], "diagnostics" => diagnostic}
    }

    {nil, [event], state, false}
  end

  defp dispatch(%{"method" => "textDocument/didChange", "params" => params}, state) do
    text = hd(params["contentChanges"])["text"]

    dispatch(
      %{
        "method" => "textDocument/didOpen",
        "params" => %{
          "textDocument" => %{
            "uri" => params["textDocument"]["uri"],
            "version" => params["textDocument"]["version"],
            "text" => text
          }
        }
      },
      state
    )
  end

  defp dispatch(%{"method" => "textDocument/didClose", "params" => params}, state) do
    {nil, [], %{state | documents: Map.delete(state.documents, params["textDocument"]["uri"])},
     false}
  end

  defp dispatch(
         %{"id" => 9_998, "result" => [settings]},
         %{protocol: "lsp", scenario: "native-rename"} = state
       ) do
    event = %{"jsonrpc" => "2.0", "method" => "fixture/configurationReady", "params" => %{}}
    {nil, [event], %{state | lsp_configuration: %{"elixirLS" => settings}}, false}
  end

  defp dispatch(
         %{"id" => id, "method" => "fixture/state"},
         %{protocol: "lsp"} = state
       ) do
    result = %{
      "documents" => state.documents,
      "documentVersions" => state.document_versions,
      "requests" => state.lsp_requests,
      "configuration" => state.lsp_configuration
    }

    {%{"jsonrpc" => "2.0", "id" => id, "result" => result}, [], state, false}
  end

  defp dispatch(%{"id" => id, "method" => method} = message, %{protocol: "lsp"} = state) do
    params = Map.get(message, "params", %{})
    uri = get_in(params, ["textDocument", "uri"])

    documents =
      if method == "textDocument/rename" and state.scenario == "stale-rename",
        do: state.initial_documents,
        else: state.documents

    source = Map.get(documents, uri, "")
    token = token_at(source, Map.get(params, "position", %{}))

    result =
      if state.scenario == "native-rename",
        do: native_lsp_result(method, params, uri, source, token, state),
        else: lsp_result(method, params, uri, source, token)

    result = versioned_rename(result, method, uri, state)

    response =
      if result == :unsupported,
        do: error(id, -32_601, "method not supported"),
        else: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    events =
      if state.scenario == "native-rename" and method == "initialize" and
           get_in(params, ["capabilities", "workspace", "configuration"]) == true do
        [
          %{
            "jsonrpc" => "2.0",
            "id" => 9_998,
            "method" => "workspace/configuration",
            "params" => %{"items" => [%{"section" => "elixirLS"}]}
          }
        ]
      else
        []
      end

    state = %{
      state
      | lsp_requests: state.lsp_requests ++ [Map.take(message, ["method", "params"])]
    }

    {response, events, state, false}
  end

  defp dispatch(%{"id" => 9_999, "error" => %{"code" => -32_601}}, %{protocol: "mcp"} = state) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "fixture/reverseRequestDenied",
      "params" => %{"code" => -32_601}
    }

    {nil, [notification], state, false}
  end

  defp dispatch(
         %{"id" => id, "method" => "initialize"},
         %{protocol: "mcp", scenario: "hold-initialize"} = state
       ) do
    {nil, [], %{state | mcp_pending: Map.put(state.mcp_pending, id, "initialize")}, false}
  end

  defp dispatch(
         %{"id" => id, "method" => "tools/call", "params" => %{"name" => "pending"}},
         %{protocol: "mcp"} = state
       ) do
    File.write!("mcp-effect-submitted", "submitted")

    {nil, [],
     %{
       state
       | mcp_pending: Map.put(state.mcp_pending, id, "tools/call"),
         mcp_calls: state.mcp_calls + 1
     }, false}
  end

  defp dispatch(
         %{"method" => method, "params" => params},
         %{protocol: "mcp"} = state
       )
       when method in ["notifications/cancelled", "$/cancelRequest"] do
    id = params["requestId"]
    accepted = method == "notifications/cancelled" and Map.has_key?(state.mcp_pending, id)
    cancellation = %{"method" => method, "params" => params, "accepted" => accepted}

    pending =
      if accepted, do: Map.delete(state.mcp_pending, id), else: state.mcp_pending

    {nil, [],
     %{
       state
       | mcp_pending: pending,
         mcp_cancellations: state.mcp_cancellations ++ [cancellation]
     }, false}
  end

  defp dispatch(%{"id" => id, "method" => "ping"}, %{protocol: "mcp"} = state) do
    result = %{
      "pending" =>
        Enum.map(state.mcp_pending, fn {id, method} -> %{"id" => id, "method" => method} end),
      "cancellations" => state.mcp_cancellations,
      "calls" => state.mcp_calls
    }

    {%{"jsonrpc" => "2.0", "id" => id, "result" => result}, [], state, false}
  end

  defp dispatch(%{"id" => id, "method" => method} = message, %{protocol: "mcp"} = state) do
    params = Map.get(message, "params", %{})

    result = mcp_result(method, params)

    response =
      if result == :unsupported,
        do: error(id, -32_601, "method not supported"),
        else: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

    events =
      if method == "initialize",
        do: [
          %{
            "jsonrpc" => "2.0",
            "id" => 9_999,
            "method" => "sampling/createMessage",
            "params" => %{
              "messages" => [
                %{
                  "role" => "user",
                  "content" => %{"type" => "text", "text" => "Untrusted server request"}
                }
              ]
            }
          }
        ],
        else: []

    {response, events, state, false}
  end

  defp dispatch(
         %{"seq" => seq, "command" => "launch", "arguments" => args},
         %{protocol: "dap"} = state
       ) do
    instructions = args["program"] |> File.read!() |> String.split("\n", trim: true)
    File.write!("dap-launch-count", Integer.to_string(state.launch_count + 1))

    {nil, [event("initialized", nil)],
     %{
       state
       | program: args["program"],
         instructions: instructions,
         launch_request: seq,
         launch_count: state.launch_count + 1
     }, false}
  end

  defp dispatch(%{"seq" => seq, "command" => command} = message, %{protocol: "dap"} = state) do
    args = Map.get(message, "arguments", %{})

    {body, events, state, exit?} = dap_result(command, args, state)

    response = %{
      "seq" => state.seq,
      "type" => "response",
      "request_seq" => seq,
      "command" => command,
      "success" => body != :unsupported,
      "body" => if(body == :unsupported, do: %{}, else: body)
    }

    {response, events, %{state | seq: state.seq + 1}, exit?}
  end

  defp dispatch(_notification, state), do: {nil, [], state, false}

  defp native_lsp_result("initialize", params, uri, source, token, _state) do
    lsp_result("initialize", params, uri, source, token)
    |> put_in(["capabilities", "renameProvider"], false)
    |> Map.put("serverInfo", %{"name" => "ElixirLS", "version" => "0.31.1"})
  end

  defp native_lsp_result("textDocument/rename", _params, _uri, _source, _token, _state),
    do: :unsupported

  defp native_lsp_result(
         "workspace/executeCommand",
         %{"command" => "llmEnvironment:oh_my_jido_rename", "arguments" => [location]},
         _uri,
         _source,
         _token,
         state
       ) do
    [_, uri, line, column] = Regex.run(~r/\A(.+):(\d+):(\d+)\z/, location)
    line = String.to_integer(line)
    source = Map.fetch!(state.documents, uri)
    [_, module] = Regex.run(~r/\bdefmodule\s+([\w.]+)/, source)

    definitions =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {text, number} ->
        case Regex.run(~r/\bdef\s+(\w+)\(([^)]*)\)/, text) do
          [_, name, ""] -> [{number, "#{name}/0"}]
          [_, name, args] -> [{number, "#{name}/#{length(String.split(args, ","))}"}]
          nil -> []
        end
      end)

    {_number, function} =
      definitions |> Enum.filter(fn {number, _function} -> number <= line end) |> List.last()

    imports =
      for {name, arity} <- Kernel.__info__(:functions) ++ Kernel.__info__(:macros),
          do: %{"module" => "Kernel", "function" => "#{name}/#{arity}"}

    %{
      "location" => %{"uri" => uri, "line" => line, "column" => String.to_integer(column)},
      "context" => %{"module" => module, "function" => function},
      "imports" => imports,
      "variables" => [],
      "definitions" => %{
        "functions_defined" => Enum.map(definitions, fn {_line, mfa} -> "#{module}.#{mfa}" end)
      }
    }
  end

  defp native_lsp_result(method, params, uri, source, _token, state)
       when method in ["textDocument/definition", "textDocument/references", "textDocument/hover"] do
    symbols =
      if is_nil(state.lsp_configuration),
        do: [],
        else:
          "native_rename_locations.json"
          |> File.read!()
          |> :json.decode()
          |> Map.fetch!("symbols")

    symbol =
      Enum.find(symbols, fn symbol ->
        Enum.any?(symbol["references"], &contains_position?(&1, uri, params["position"]))
      end)

    case {method, symbol} do
      {"textDocument/definition", nil} -> native_sdk_result(method, params, source)
      {"textDocument/definition", symbol} -> symbol["definition"]
      {"textDocument/references", nil} -> []
      {"textDocument/references", symbol} -> symbol["references"]
      {"textDocument/hover", _symbol} -> native_sdk_result(method, params, source)
    end
  end

  defp native_lsp_result(method, params, uri, source, token, _state),
    do: lsp_result(method, params, uri, source, token)

  defp native_sdk_result(method, %{"position" => point}, source) do
    text = source |> String.split("\n") |> Enum.at(point["line"], "")
    utf16 = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    offset = point["character"] * 2

    if offset + 2 <= byte_size(utf16) and binary_part(utf16, offset, 2) == <<?+, 0>> do
      case method do
        "textDocument/definition" ->
          %{"uri" => "file:///oh-my-jido-native-sdk-fixture/kernel.ex", "range" => range(0, 0, 1)}

        "textDocument/hover" ->
          %{
            "contents" => %{
              "kind" => "markdown",
              "value" => "```elixir\nKernel.+(left, right)\n```\n\n*function*\n"
            },
            "range" => range(point["line"], point["character"], 1)
          }
      end
    end
  end

  defp contains_position?(location, uri, position) do
    range = location["range"]
    start = range["start"]
    ending = range["end"]

    location["uri"] == uri and start["line"] == position["line"] and
      ending["line"] == position["line"] and start["character"] <= position["character"] and
      position["character"] < ending["character"]
  end

  defp lsp_result("initialize", _params, _uri, _source, _token) do
    %{
      "capabilities" => %{
        "textDocumentSync" => 1,
        "definitionProvider" => true,
        "referencesProvider" => true,
        "documentSymbolProvider" => true,
        "renameProvider" => true
      }
    }
  end

  defp lsp_result("shutdown", _params, _uri, _source, _token), do: nil

  defp lsp_result("textDocument/documentSymbol", _params, _uri, source, _token),
    do: symbols(source)

  defp lsp_result("textDocument/definition", _params, uri, source, token) do
    Enum.find_value(symbols(source), fn symbol ->
      if symbol["name"] == token, do: %{"uri" => uri, "range" => symbol["selectionRange"]}
    end)
  end

  defp lsp_result("textDocument/references", _params, uri, source, token),
    do: Enum.map(occurrences(source, token), &Map.put(&1, "uri", uri))

  defp lsp_result("textDocument/rename", params, uri, source, token) do
    changes = %{
      uri =>
        Enum.map(
          occurrences(source, token),
          &%{"range" => &1["range"], "newText" => params["newName"]}
        )
    }

    changes =
      if params["newName"] == "escape",
        do:
          Map.put(changes, "file:///not-granted.ex", [
            %{"range" => range(0, 0, 0), "newText" => "outside"}
          ]),
        else: changes

    %{"changes" => changes}
  end

  defp lsp_result(_method, _params, _uri, _source, _token), do: :unsupported

  defp versioned_rename(%{"changes" => changes}, "textDocument/rename", uri, state)
       when state.scenario in ["versioned-rename", "stale-rename"] do
    version =
      case state.scenario do
        "stale-rename" -> state.document_versions[uri] - 1
        "versioned-rename" -> state.document_versions[uri]
      end

    documents = [
      %{"textDocument" => %{"uri" => uri, "version" => version}, "edits" => changes[uri]}
    ]

    documents =
      if state.scenario == "stale-rename" do
        other_uri = "file://" <> Path.join(File.cwd!(), "a_first.ex")

        [
          %{
            "textDocument" => %{
              "uri" => other_uri,
              "version" => state.document_versions[other_uri]
            },
            "edits" => [%{"range" => range(0, 0, 0), "newText" => "# renamed\n"}]
          }
          | documents
        ]
      else
        documents
      end

    %{"documentChanges" => documents}
  end

  defp versioned_rename(result, _method, _uri, _state), do: result

  defp mcp_result("initialize", _params) do
    %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}, "resources" => %{}},
      "serverInfo" => %{"name" => "stateful-fixture", "version" => "1"}
    }
  end

  defp mcp_result("tools/list", _params) do
    %{
      "tools" => [
        %{
          "name" => "sum",
          "description" => "Adds numeric inputs",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "values" => %{"type" => "array", "items" => %{"type" => "number"}}
            }
          }
        },
        %{"name" => "write_file", "inputSchema" => %{"type" => "object"}}
      ]
    }
  end

  defp mcp_result("resources/list", _params) do
    %{
      "resources" => [
        %{
          "uri" => "file://" <> Path.join(File.cwd!(), "resource.txt"),
          "name" => "owned resource"
        },
        %{"uri" => "file:///not-granted", "name" => "hidden resource"}
      ]
    }
  end

  defp mcp_result("resources/read", params) do
    %{
      "contents" => [
        %{
          "uri" => params["uri"],
          "mimeType" => "text/plain",
          "text" => params["uri"] |> URI.parse() |> Map.fetch!(:path) |> File.read!()
        }
      ]
    }
  end

  defp mcp_result("tools/call", params), do: mcp_tool(params["name"], params["arguments"])
  defp mcp_result(_method, _params), do: :unsupported

  defp mcp_tool("sum", arguments) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => Integer.to_string(Enum.sum(arguments["values"]))
        }
      ],
      "isError" => false
    }
  end

  defp mcp_tool("write_file", _arguments) do
    File.write!("forbidden-effect", "not granted")
    %{"content" => []}
  end

  defp mcp_tool("crash", _arguments), do: System.halt(7)

  defp dap_result("initialize", _args, state) do
    {%{"supportsConfigurationDoneRequest" => true, "supportsTerminateRequest" => true}, [], state,
     false}
  end

  defp dap_result("setBreakpoints", args, state) do
    lines = Enum.map(args["breakpoints"], & &1["line"])

    {%{"breakpoints" => Enum.map(lines, &%{"verified" => true, "line" => &1})}, [],
     %{state | breakpoints: lines}, false}
  end

  defp dap_result("configurationDone", _args, state) do
    state = advance_until_breakpoint(state)

    launch_response = %{
      "seq" => state.seq,
      "type" => "response",
      "request_seq" => state.launch_request,
      "command" => "launch",
      "success" => true,
      "body" => %{"launchCount" => state.launch_count}
    }

    {%{}, [launch_response, event("stopped", %{"reason" => "breakpoint", "threadId" => 1})],
     state, false}
  end

  defp dap_result("threads", _args, state),
    do: {%{"threads" => [%{"id" => 1, "name" => "fixture program"}]}, [], state, false}

  defp dap_result("stackTrace", _args, state) do
    {%{
       "stackFrames" => [
         %{
           "id" => 1,
           "name" => "main",
           "line" => state.line,
           "column" => 1,
           "source" => %{"path" => state.program}
         }
       ],
       "totalFrames" => 1
     }, [], state, false}
  end

  defp dap_result("scopes", _args, state) do
    {%{"scopes" => [%{"name" => "Locals", "variablesReference" => 1, "expensive" => false}]}, [],
     state, false}
  end

  defp dap_result("variables", _args, state) do
    {%{
       "variables" =>
         Enum.map(state.variables, fn {name, value} ->
           %{
             "name" => name,
             "value" => Integer.to_string(value),
             "type" => "integer",
             "variablesReference" => 0
           }
         end)
     }, [], state, false}
  end

  defp dap_result(step, _args, state) when step in ["next", "stepIn", "stepOut"] do
    state = advance(state)
    {%{}, [event("stopped", %{"reason" => "step", "threadId" => 1})], state, false}
  end

  defp dap_result("continue", _args, state) do
    state = advance_until_breakpoint(advance(state))

    {%{"allThreadsContinued" => true},
     [event("stopped", %{"reason" => "breakpoint", "threadId" => 1})], state, false}
  end

  defp dap_result("pause", _args, state),
    do: {%{}, [event("stopped", %{"reason" => "pause", "threadId" => 1})], state, false}

  defp dap_result(close, _args, state) when close in ["terminate", "disconnect"],
    do: {%{}, [event("terminated", %{})], state, true}

  defp dap_result(_command, _args, state), do: {:unsupported, [], state, false}

  defp advance_until_breakpoint(state) do
    cond do
      state.line in state.breakpoints -> state
      state.line > length(state.instructions) -> state
      true -> advance_until_breakpoint(advance(state))
    end
  end

  defp advance(state) do
    case Enum.at(state.instructions, state.line - 1) do
      nil ->
        state

      instruction ->
        [operation, name, amount] = String.split(instruction)
        value = String.to_integer(amount)

        variables =
          case operation do
            "set" -> Map.put(state.variables, name, value)
            "add" -> Map.update!(state.variables, name, &(&1 + value))
          end

        %{state | variables: variables, line: state.line + 1}
    end
  end

  defp symbols(source) do
    source
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, number} ->
      case Regex.run(~r/\bdef\s+(\w+)/, line, return: :index) do
        [_, {start, length}] ->
          name = binary_part(line, start, length)

          [
            %{
              "name" => name,
              "kind" => 12,
              "range" => range(number, start, length),
              "selectionRange" => range(number, start, length)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp token_at(source, %{"line" => line, "character" => character}) do
    text = source |> String.split("\n") |> Enum.at(line, "")

    Regex.scan(~r/\b\w+\b/, text, return: :index)
    |> Enum.find_value("", fn [{start, length}] ->
      if character >= start and character < start + length, do: binary_part(text, start, length)
    end)
  end

  defp token_at(_source, _position), do: ""

  defp occurrences(_source, ""), do: []

  defp occurrences(source, token) do
    source
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, number} ->
      Regex.scan(Regex.compile!("\\b" <> Regex.escape(token) <> "\\b"), line, return: :index)
      |> Enum.map(fn [{start, length}] -> %{"range" => range(number, start, length)} end)
    end)
  end

  defp range(line, start, length),
    do: %{
      "start" => %{"line" => line, "character" => start},
      "end" => %{"line" => line, "character" => start + length}
    }

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp event(name, body), do: %{"seq" => 1, "type" => "event", "event" => name, "body" => body}
end

OhMyJido.ProtocolFixture.run(hd(System.argv()), Enum.at(System.argv(), 1, "normal"))
