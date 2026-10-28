defmodule WebLLM.ProviderTest do
  use ExUnit.Case, async: false

  defmodule PageTransport do
    @moduledoc false
    @behaviour WebLLM.Transport

    @impl true
    def stream(request, _finch_name, acc, fun, _opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:page_request, request})

      body =
        if Jason.decode!(request.body)["stream"],
          do: Enum.map(chunks(), &{:data, &1}),
          else: [{:data, Jason.encode!(completion())}]

      type =
        if match?([{:data, "data:" <> _} | _], body),
          do: "text/event-stream",
          else: "application/json"

      entries = [{:status, 200}, {:headers, [{"content-type", type}]} | body]
      {:ok, Enum.reduce(entries, acc, fun)}
    end

    defp chunks do
      call = %{
        index: 0,
        id: "call_1",
        type: "function",
        function: %{name: "eval", arguments: ~s({"language":"javascript"})}
      }

      deltas = [
        {%{role: "assistant", content: "Hel"}, nil, nil},
        {%{content: "lo"}, nil, nil},
        {%{tool_calls: [call]}, nil, nil},
        {%{}, "tool_calls", %{prompt_tokens: 12, completion_tokens: 5, total_tokens: 17}}
      ]

      Enum.map(deltas, fn {delta, finish, usage} ->
        chunk = %{
          id: "chatcmpl-1",
          object: "chat.completion.chunk",
          created: 1,
          model: "Qwen3-8B-q4f16_1-MLC",
          choices: [%{index: 0, delta: delta, finish_reason: finish}]
        }

        "data: " <>
          Jason.encode!(if usage, do: Map.put(chunk, :usage, usage), else: chunk) <> "\n\n"
      end) ++ ["data: [DONE]\n\n"]
    end

    defp completion do
      %{
        id: "chatcmpl-2",
        object: "chat.completion",
        created: 1,
        model: "Qwen3-8B-q4f16_1-MLC",
        choices: [
          %{index: 0, message: %{role: "assistant", content: "Hi there"}, finish_reason: "stop"}
        ],
        usage: %{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5}
      }
    end
  end

  setup do
    Application.put_env(:web_llm, :transport, PageTransport)
    :persistent_term.put({PageTransport, :owner}, self())

    on_exit(fn ->
      Application.delete_env(:web_llm, :transport)
      :persistent_term.erase({PageTransport, :owner})
    end)
  end

  test "a streamed answer and tool call come back from the page, with no credential sent" do
    tool =
      ReqLLM.Tool.new!(
        name: "eval",
        description: "Evaluate code",
        parameter_schema: [language: [type: :string, required: true]],
        callback: fn _args -> {:ok, nil} end
      )

    model = WebLLM.model("Qwen3-8B-q4f16_1-MLC", client: "tab-1")
    assert {:ok, stream} = ReqLLM.stream_text(model, "Rename the title", tools: [tool])
    assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream)

    assert ReqLLM.Response.text(response) == "Hello"
    assert [call] = ReqLLM.Response.tool_calls(response)
    assert ReqLLM.ToolCall.name(call) == "eval"
    assert ReqLLM.ToolCall.args_map(call) == %{"language" => "javascript"}
    assert %{input_tokens: 12, output_tokens: 5} = ReqLLM.Response.usage(response)

    assert_received {:page_request, request}

    assert {request.host, request.path} ==
             {"web-llm.invalid", "/clients/tab-1/v1/chat/completions"}

    refute Enum.any?(request.headers, fn {name, _value} ->
             String.downcase(name) == "authorization"
           end)

    assert %{"model" => "Qwen3-8B-q4f16_1-MLC", "stream" => true} = Jason.decode!(request.body)
  end

  test "a non-streaming request is answered by the page as one completion" do
    model = WebLLM.model("Qwen3-8B-q4f16_1-MLC", client: "tab-1")

    assert {:ok, response} =
             ReqLLM.generate_text(model, "Say hi",
               req_http_options: [headers: [{WebLLM.client_header(), "tab-2"}]]
             )

    assert ReqLLM.Response.text(response) == "Hi there"
    assert_received {:page_request, request}
    assert {:ok, "tab-2"} = WebLLM.Transport.client(request)

    refute Enum.any?(request.headers, fn {name, _value} ->
             String.downcase(name) == "authorization"
           end)
  end

  test "the client header overrides the client in the base URL; invalid clients are refused" do
    model = WebLLM.model("Qwen3-8B-q4f16_1-MLC", client: "tab-1")

    header =
      Finch.build(:post, model.base_url <> "/chat/completions", [{"X-Web-LLM-Client", "tab-9"}])

    assert WebLLM.Transport.client(header) == {:ok, "tab-9"}

    bad = Finch.build(:post, model.base_url, [{"x-web-llm-client", "../other"}])
    assert WebLLM.Transport.client(bad) == {:error, :invalid_client}

    assert WebLLM.Transport.client(Finch.build(:post, WebLLM.base_url(nil))) ==
             {:error, :no_client}

    assert_raise ArgumentError, fn -> WebLLM.model("m", client: "a/b") end
  end
end
