defmodule PhoenixWebGPUWeb.AgentLive do
  @moduledoc "Server-side chat with page-scoped delegation to the connected browser GPU."
  use Phoenix.LiveView, layout: false

  alias PhoenixWebGPU.{Agent, SessionOwner}

  @impl true
  def mount(_params, _session, socket) do
    [{model, role} | _models] = Agent.models()

    socket =
      socket
      |> assign(
        client: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        models: Agent.models(),
        model: model,
        role: role,
        owner: nil,
        session: nil,
        busy: false,
        status: "Connecting…",
        scripted: Application.get_env(:phoenix_webgpu, :scripted, false),
        form: to_form(%{"prompt" => ""}, as: :chat)
      )
      |> stream(:messages, [])

    {:ok, if(connected?(socket), do: open_session(socket), else: socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="agent-demo" data-state={if(@busy, do: "running", else: "ready")}>
      <header>
        <p class="eyebrow">Oh-My-Jido / WebLLM</p>
        <h1>Server reasoning. Your browser's GPU.</h1>
        <p>Ask the server assistant to inspect or change the demo page. It delegates to this tab.</p>
      </header>
      <div class="columns">
        <section aria-labelledby="chat-title" class="panel">
          <h2 id="chat-title">Server assistant</h2>
          <p id="agent-status" role="status">{@status}</p>
          <p :if={@scripted} class="notice">
            Scripted parent · real delegation and browser transport
          </p>
          <div id="transcript" phx-update="stream" aria-live="polite">
            <article
              :for={{id, message} <- @streams.messages}
              id={id}
              class={"message #{message.role}"}
            >
              <strong>{message.role}</strong>
              <pre>{message.text}</pre>
            </article>
          </div>
          <.form for={@form} id="chat-form" phx-submit="send">
            <label for="chat-prompt">Message</label>
            <textarea
              id="chat-prompt"
              name={@form[:prompt].name}
              rows="3"
              required
              disabled={@busy or is_nil(@session)}
              placeholder="Change #demo-heading to a title you like and tell me what changed"
            >{@form[:prompt].value}</textarea>
            <button id="chat-send" type="submit" disabled={@busy or is_nil(@session)}>
              {if(@busy, do: "Working…", else: "Send to server")}
            </button>
          </.form>
        </section>
        <section aria-labelledby="gpu-title" class="panel">
          <h2 id="gpu-title">Browser subagent</h2>
          <form phx-change="model">
            <label for="browser-model">GPU model (changing it resets the conversation)</label>
            <select id="browser-model" name="model" disabled={@busy}>
              <option :for={{id, _role} <- @models} value={id} selected={id == @model}>{id}</option>
            </select>
          </form>
          <.live_component
            module={WebLLM.Live.Component}
            id="web-llm"
            client={@client}
            model={@model}
            preload={false}
            allow_eval={true}
          />
          <p class="notice">
            Page evaluation is enabled for this demo. The server can execute JavaScript in this tab.
            First use downloads model weights; keep this tab open while the child works.
          </p>
          <section id="demo-page" phx-update="ignore" aria-labelledby="demo-heading">
            <h2 id="demo-heading">A page the browser agent can change</h2>
            <ul id="demo-list">
              <li>Inspect the heading and list.</li>
              <li>Change the DOM without reloading.</li>
              <li>Report the result back to the server agent.</li>
            </ul>
          </section>
        </section>
      </div>
    </main>
    """
  end

  @impl true
  def handle_event("send", %{"chat" => %{"prompt" => text}}, %{assigns: %{busy: false}} = socket) do
    text = String.trim(text)

    if text == "" or is_nil(socket.assigns.session) do
      {:noreply, socket}
    else
      session = socket.assigns.session

      socket =
        socket
        |> message("user", text)
        |> assign(busy: true, status: "Server agent is working…")
        |> start_async(:chat, fn -> ask(session, text) end)

      {:noreply, socket}
    end
  end

  def handle_event("model", %{"model" => id}, %{assigns: %{busy: false}} = socket) do
    case List.keyfind(Agent.models(), id, 0) do
      {model, role} when model != socket.assigns.model ->
        if socket.assigns.owner, do: GenServer.stop(socket.assigns.owner)

        socket =
          socket
          |> assign(model: model, role: role, owner: nil, session: nil)
          |> stream(:messages, [], reset: true)
          |> open_session()

        {:noreply, socket}

      _unchanged ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp ask(session, text) do
    with {:ok, run} <- OhMyJido.prompt(session, text, Agent.prompt_options(text)) do
      OhMyJido.await(session, run, timeout: 660_000)
    end
  end

  @impl true
  def handle_async(:chat, {:ok, {:ok, %{status: :completed, answer: answer}}}, socket) do
    {:noreply, socket |> message("assistant", answer) |> assign(busy: false, status: "Ready")}
  end

  def handle_async(:chat, {:ok, result}, socket), do: failed(socket, result)
  def handle_async(:chat, {:exit, reason}, socket), do: failed(socket, reason)

  @impl true
  def handle_info({:browser_result, result}, socket) do
    {:noreply, message(socket, "browser", Jason.encode!(result, pretty: true))}
  end

  def handle_info({:browser_eval, source, result}, socket) do
    outcome =
      case result do
        {:ok, value} -> "→ " <> Jason.encode!(value)
        {:error, reason} -> "✗ " <> inspect(reason)
      end

    {:noreply, message(socket, "gpu-tool", "browser_eval\n" <> source <> "\n" <> outcome)}
  end

  defp open_session(socket) do
    opts = [live_view: self(), client: socket.assigns.client, role: socket.assigns.role]

    case DynamicSupervisor.start_child(PhoenixWebGPU.Sessions, {SessionOwner, opts}) do
      {:ok, owner} ->
        assign(socket, owner: owner, session: SessionOwner.session(owner), status: "Ready")

      {:error, reason} ->
        assign(socket, status: "Session could not start: #{inspect(reason)}")
    end
  end

  defp message(socket, role, text) do
    stream_insert(socket, :messages, %{id: Jido.Util.generate_id(), role: role, text: text})
  end

  defp failed(socket, reason) do
    {:noreply,
     socket
     |> message("error", inspect(reason))
     |> assign(busy: false, status: "Request failed; see transcript")}
  end
end
