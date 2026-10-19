defmodule OhMyJido.TidewaveProxyFixture do
  @moduledoc false

  # An owned JSONL protocol fixture, not a replacement Tidewave runtime. Native
  # Tidewave execution is exercised separately by the opt-in external fixture.
  @tools [
    {"get_docs", "reference", "string"},
    {"get_logs", "tail", "integer"},
    {"get_source_location", "reference", "string"},
    {"project_eval", "code", "string"},
    {"clear_cache", "key", "string"}
  ]

  def run(scenario) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :ok

      line when is_binary(line) ->
        message = :json.decode(line)
        File.write!("tidewave-requests.jsonl", [:json.encode(message), "\n"], [:append])
        dispatch(message, scenario)
        run(scenario)
    end
  end

  defp dispatch(%{"id" => id, "method" => "initialize"}, "initialize-error"),
    do: error(id, -32_603, "fixture initialization refused")

  defp dispatch(%{"id" => id, "method" => "initialize"}, _scenario) do
    reply(id, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "owned-tidewave-protocol-fixture", "version" => "1"},
      "tools" => tools()
    })
  end

  defp dispatch(%{"method" => "notifications/initialized"}, _scenario), do: :ok

  defp dispatch(%{"id" => id, "method" => "tools/list"}, "list-error"),
    do: error(id, -32_601, "fixture tool discovery unavailable")

  defp dispatch(%{"id" => id, "method" => "tools/list"}, "list-malformed"),
    do: reply(id, %{"nextCursor" => "not-a-tool-catalog"})

  defp dispatch(%{"id" => id, "method" => "tools/list"}, _scenario),
    do: reply(id, %{"tools" => tools(), "nextCursor" => "owned-next-page"})

  defp dispatch(%{"id" => id, "method" => "tools/call", "params" => params}, scenario) do
    case params do
      %{"name" => name, "arguments" => %{"port" => port} = arguments}
      when is_integer(port) and port in 1..65_535 ->
        if known_tool?(name) do
          dispatch_tool(id, name, arguments, scenario)
        else
          error(id, -32_602, "unknown fixture tool")
        end

      _invalid ->
        error(id, -32_602, "native proxy requires an integer port")
    end
  end

  defp dispatch(%{"id" => id}, _scenario), do: error(id, -32_601, "method unavailable")
  defp dispatch(_message, _scenario), do: :ok

  defp known_tool?(name), do: Enum.any?(@tools, fn {tool, _, _} -> tool == name end)

  defp dispatch_tool(_id, _name, _arguments, "drop"), do: System.halt(0)

  defp dispatch_tool(id, name, arguments, _scenario) do
    payload = %{"tool" => name, "arguments" => arguments, "external_pid" => System.pid()}

    reply(id, %{
      "content" => [
        %{"type" => "text", "text" => :json.encode(payload) |> IO.iodata_to_binary()}
      ],
      "isError" => false
    })
  end

  defp tools do
    Enum.map(@tools, fn {name, field, type} ->
      %{
        "name" => name,
        "description" => "Owned protocol fixture for #{name}",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            field => %{"type" => type},
            "port" => %{"type" => "integer", "minimum" => 1, "maximum" => 65_535}
          },
          "required" => [field, "port"]
        }
      }
    end)
  end

  defp reply(id, result), do: send_message(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, code, message),
    do:
      send_message(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })

  defp send_message(message), do: IO.binwrite(:stdio, [:json.encode(message), "\n"])
end

OhMyJido.TidewaveProxyFixture.run(List.first(System.argv()) || "normal")
