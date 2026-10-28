defmodule WebLLMTest.ErrorHTML do
  @moduledoc false
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule WebLLMTest.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :web_llm

  socket("/live", Phoenix.LiveView.Socket)
end

defmodule WebLLMTest.PageLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    {:ok, assign(socket, client: session["client"], allow_eval: session["allow_eval"] == true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={WebLLM.Live.Component}
      id="web-llm"
      client={@client}
      model="Qwen3-8B-q4f16_1-MLC"
      allow_eval={@allow_eval}
    />
    """
  end
end
