defmodule WebLLM.LiveTest do
  use ExUnit.Case, async: false

  # Failure-path tests make the transport log the reason it gave up.
  @moduletag :capture_log

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint WebLLMTest.Endpoint

  setup do
    Application.delete_env(:web_llm, :transport)
    %{conn: build_conn()}
  end

  test "a model request streams through the browser's LiveView socket", %{conn: conn} do
    {view, client} = page(conn)
    assert WebLLM.Live.connected?(client)

    task =
      Task.async(fn ->
        model = WebLLM.model("Qwen3-8B-q4f16_1-MLC", client: client)
        {:ok, stream} = ReqLLM.stream_text(model, "Say hello")
        ReqLLM.StreamResponse.to_response(stream)
      end)

    assert_push_event(view, "web_llm:request", %{
      target: "web-llm",
      request: %{"id" => id, "body" => body}
    })

    assert %{"stream" => true, "model" => "Qwen3-8B-q4f16_1-MLC"} = Jason.decode!(body)

    for event <- [
          %{"type" => "status", "status" => 200},
          %{"type" => "headers", "headers" => [["content-type", "text/event-stream"]]},
          %{"type" => "data", "data" => chunk(%{content: "Hello"}, nil)},
          %{"type" => "data", "data" => chunk(%{content: " there"}, "stop")},
          %{"type" => "data", "data" => "data: [DONE]\n\n"},
          %{"type" => "done"}
        ] do
      view |> element("#web-llm") |> render_hook("web_llm:event", Map.put(event, "id", id))
    end

    assert {:ok, response} = Task.await(task)
    assert ReqLLM.Response.text(response) == "Hello there"
  end

  test "the request fails when the browser's LiveView goes away", %{conn: conn} do
    {view, client} = page(conn)
    task = Task.async(fn -> raw_stream(client, 5_000) end)

    assert_push_event(view, "web_llm:request", %{request: %{"id" => _id}})
    Process.exit(view.pid, :kill)

    assert {:error, %Req.TransportError{reason: :client_disconnected}, []} = Task.await(task)
    refute WebLLM.Live.connected?(client)
  end

  test "a silent page times out and the generation is cancelled", %{conn: conn} do
    {view, client} = page(conn)

    assert {:error, %Req.TransportError{reason: :timeout}, []} = raw_stream(client, 50)
    assert_push_event(view, "web_llm:request", %{request: %{"id" => id}})
    assert_push_event(view, "web_llm:cancel", %{id: ^id})
  end

  test "a caller that exits mid-generation cancels it in the page", %{conn: conn} do
    {view, client} = page(conn)
    task = Task.async(fn -> raw_stream(client, 5_000) end)

    assert_push_event(view, "web_llm:request", %{request: %{"id" => id}})
    Task.shutdown(task, :brutal_kill)

    assert_push_event(view, "web_llm:cancel", %{id: ^id})
  end

  test "requests for a client without a connected browser are refused" do
    assert {:error, %Req.TransportError{reason: :client_not_connected}, []} =
             raw_stream(WebLLM.new_client(), 1_000)
  end

  test "eval runs JavaScript in the page only when the component allows it", %{conn: conn} do
    {view, client} = page(conn, allow_eval: true)
    task = Task.async(fn -> WebLLM.Live.eval(client, "return 1 + 1") end)

    assert_push_event(view, "web_llm:eval", %{id: id, source: "return 1 + 1"})

    view
    |> element("#web-llm")
    |> render_hook("web_llm:eval_result", %{"id" => id, "ok" => true, "value" => 2})

    assert Task.await(task) == {:ok, 2}

    {_locked, locked_client} = page(conn)
    assert WebLLM.Live.eval(locked_client, "return 1") == {:error, {:page, "eval is not allowed"}}
  end

  test "load progress reported by the hook is rendered", %{conn: conn} do
    {view, _client} = page(conn)

    html =
      view
      |> element("#web-llm")
      |> render_hook("web_llm:status", %{
        "state" => "loading",
        "progress" => 0.5,
        "text" => "Fetching weights"
      })

    assert html =~ "Fetching weights"
    assert html =~ ~s(data-state="loading")
  end

  defp page(conn, opts \\ []) do
    client = WebLLM.new_client()
    session = %{"client" => client, "allow_eval" => Keyword.get(opts, :allow_eval, false)}
    {:ok, view, _html} = live_isolated(conn, WebLLMTest.PageLive, session: session)
    {view, client}
  end

  defp raw_stream(client, timeout) do
    request = Finch.build(:post, WebLLM.base_url(client) <> "/chat/completions", [], "{}")
    WebLLM.Live.Transport.stream(request, nil, [], &[&1 | &2], receive_timeout: timeout)
  end

  defp chunk(delta, finish) do
    body = %{
      id: "chatcmpl-1",
      object: "chat.completion.chunk",
      created: 1,
      model: "Qwen3-8B-q4f16_1-MLC",
      choices: [%{index: 0, delta: delta, finish_reason: finish}]
    }

    "data: " <> Jason.encode!(body) <> "\n\n"
  end
end
