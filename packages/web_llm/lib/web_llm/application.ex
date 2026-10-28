defmodule WebLLM.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    ReqLLM.Providers.register!(WebLLM.Provider)

    children = [{Registry, keys: :unique, name: WebLLM.Live.Registry}]
    Supervisor.start_link(children, strategy: :one_for_one, name: WebLLM.Supervisor)
  end
end
