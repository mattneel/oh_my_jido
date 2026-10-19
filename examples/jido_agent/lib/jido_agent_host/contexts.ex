defmodule JidoAgentHost.Contexts do
  @moduledoc """
  An explicit host-owned binding store, supervised by the embedding application.

  Native agents contain only public domain/model state. The host binds each
  concrete module and ID to a Context before asking it to use coding tools.
  """

  use Agent
  @behaviour OhMyJido.Plugin.ContextProvider

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def bind(agent_module, agent_id, context_options) do
    with {:ok, context} <- OhMyJido.Context.new(context_options) do
      Agent.update(__MODULE__, &Map.put(&1, {agent_module, agent_id}, context))
    end
  end

  @impl true
  def fetch_context(%{agent_module: module, agent_id: id}) do
    Agent.get(__MODULE__, &Map.fetch(&1, {module, id}))
    |> case do
      {:ok, context} -> {:ok, context}
      :error -> {:error, :not_bound}
    end
  end
end
