defmodule OhMyJido.Actions.StopChild do
  @moduledoc false
  use Jido.Action,
    name: "oh_my_jido_stop_child",
    schema: Zoi.object(%{tag: Zoi.string()})

  @impl true
  def run(%{tag: tag}, %{agent_state: state}) do
    {:ok, state, [Jido.Agent.Directive.stop_child(tag)]}
  end
end
