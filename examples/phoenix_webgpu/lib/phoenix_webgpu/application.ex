defmodule PhoenixWebGPU.Application do
  @moduledoc "Supervision tree for the server agent and its LiveView transport."
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: PhoenixWebGPU.PubSub},
      {DynamicSupervisor, name: PhoenixWebGPU.Sessions, strategy: :one_for_one},
      {OhMyJido, PhoenixWebGPU.Agent.runtime_options()},
      PhoenixWebGPUWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PhoenixWebGPU.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PhoenixWebGPUWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
