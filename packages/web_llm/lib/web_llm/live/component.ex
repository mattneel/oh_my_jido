if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule WebLLM.Live.Component do
    @moduledoc """
    Hosts a WebLLM engine in the user's browser for server-side code.

        <.live_component
          module={WebLLM.Live.Component}
          id="web-llm"
          client={@client}
          model="Qwen3-8B-q4f16_1-MLC"
          preload={true}
        />

    The element runs the `WebLLM` hook from `priv/static/web_llm.js`
    (`import {WebLLMHook} from "web_llm"` and pass it to `LiveSocket`'s
    `hooks`). Once connected, the component registers `client` (see
    `WebLLM.new_client/0`), so models built with `WebLLM.model(id, client:
    client)` run on this browser's GPU.

    Attributes: `id` and `client` (required), `model` (loaded on `preload`),
    `preload` (load as soon as the page connects), `allow_eval` (permit
    `WebLLM.Live.eval/3`), `class`. An inner block receives
    `%{state: state, progress: progress, text: text, webgpu: webgpu}`;
    without one the component shows a status line.
    """

    use Phoenix.LiveComponent

    @registry WebLLM.Live.Registry
    @settings [:id, :client, :model, :preload, :allow_eval, :class, :inner_block]

    @doc false
    @spec deliver(pid(), String.t(), term()) :: :ok
    def deliver(pid, dom_id, message) do
      Phoenix.LiveView.send_update(pid, __MODULE__, id: dom_id, web_llm: message)
      :ok
    end

    @impl true
    def mount(socket) do
      {:ok,
       assign(socket,
         client: nil,
         model: nil,
         preload: false,
         allow_eval: false,
         class: nil,
         inner_block: [],
         pending: %{},
         registered: nil,
         state: "idle",
         progress: 0.0,
         text: "",
         webgpu: nil
       )}
    end

    @impl true
    def update(%{web_llm: message}, socket), do: {:ok, handle_message(message, socket)}

    def update(assigns, socket) do
      socket = assign(socket, Map.take(assigns, @settings))
      {:ok, register(socket)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div
        id={@id}
        phx-hook="WebLLM"
        phx-target={@myself}
        data-client={@client}
        data-model={@model}
        data-preload={to_string(@preload)}
        data-allow-eval={to_string(@allow_eval)}
        data-state={@state}
        class={@class}
      >
        <%= if @inner_block == [] do %>
          <span data-role="status">{@text}</span>
          <progress :if={@state == "loading"} value={@progress} max="1"></progress>
        <% else %>
          {render_slot(@inner_block, %{
            state: @state,
            progress: @progress,
            text: @text,
            webgpu: @webgpu
          })}
        <% end %>
      </div>
      """
    end

    @impl true
    def handle_event("web_llm:event", %{"id" => id} = event, socket) do
      case socket.assigns.pending do
        %{^id => {:request, waiter}} ->
          send(waiter, {:web_llm, id, event})
          finished? = event["type"] in ["done", "error"]
          {:noreply, if(finished?, do: forget(socket, id), else: socket)}

        _pending ->
          {:noreply, socket}
      end
    end

    def handle_event("web_llm:eval_result", %{"id" => id} = result, socket) do
      case socket.assigns.pending do
        %{^id => {:eval, waiter}} ->
          send(waiter, {:web_llm_eval, id, result})
          {:noreply, forget(socket, id)}

        _pending ->
          {:noreply, socket}
      end
    end

    def handle_event("web_llm:status", status, socket) do
      {:noreply,
       assign(socket,
         state: status_value(status, "state", socket.assigns.state),
         progress: status_value(status, "progress", socket.assigns.progress),
         text: status_value(status, "text", socket.assigns.text),
         webgpu: status_value(status, "webgpu", socket.assigns.webgpu)
       )}
    end

    defp status_value(status, key, default) do
      case Map.fetch(status, key) do
        {:ok, value} when is_binary(value) or is_number(value) or is_boolean(value) -> value
        _missing -> default
      end
    end

    defp handle_message({:request, id, waiter, payload}, socket) do
      socket
      |> track(id, {:request, waiter})
      |> push_event("web_llm:request", %{target: socket.assigns.id, request: payload})
    end

    defp handle_message({:cancel, id}, socket) do
      socket
      |> forget(id)
      |> push_event("web_llm:cancel", %{target: socket.assigns.id, id: id})
    end

    defp handle_message({:eval, id, waiter, source}, socket) do
      if socket.assigns.allow_eval do
        socket
        |> track(id, {:eval, waiter})
        |> push_event("web_llm:eval", %{target: socket.assigns.id, id: id, source: source})
      else
        send(waiter, {:web_llm_eval, id, %{"ok" => false, "error" => "eval is not allowed"}})
        socket
      end
    end

    defp handle_message({:forget, id}, socket), do: forget(socket, id)

    defp handle_message({:load, model}, socket),
      do: push_event(socket, "web_llm:load", %{target: socket.assigns.id, model: model})

    defp track(socket, id, entry), do: update(socket, :pending, &Map.put(&1, id, entry))
    defp forget(socket, id), do: update(socket, :pending, &Map.delete(&1, id))

    defp register(%{assigns: %{client: client, registered: client}} = socket), do: socket

    defp register(socket) do
      if connected?(socket) and WebLLM.client?(socket.assigns.client) do
        if socket.assigns.registered,
          do: Registry.unregister(@registry, socket.assigns.registered)

        claim(
          socket,
          Registry.register(@registry, socket.assigns.client, %{dom_id: socket.assigns.id})
        )
      else
        socket
      end
    end

    defp claim(socket, {:ok, _owner}), do: assign(socket, registered: socket.assigns.client)

    defp claim(socket, {:error, {:already_registered, _pid}}) do
      raise ArgumentError,
            "WebLLM client #{inspect(socket.assigns.client)} is already served by another LiveView"
    end
  end
end
