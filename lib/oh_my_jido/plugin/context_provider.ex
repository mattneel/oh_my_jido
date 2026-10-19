defmodule OhMyJido.Plugin.ContextProvider do
  @moduledoc """
  Host-owned authority for a native agent with `OhMyJido.Plugin` attached.

  The provider is selected in the agent's trusted plugin declaration. It receives
  only the native agent module and ID, never signal data or tool arguments. Keep
  bindings in host-owned resources, not the agent's state or checkpoints. Lookups
  run inside each coding action, not during the pure `Agent.new/1` mount.

  Return a validated `OhMyJido.Context` with explicit workspace, grants, and tool
  availability. A missing binding must return `{:error, :not_bound}`. No services,
  credentials, models, or default permission grants are supplied by the plugin.
  """

  @type identity :: %{required(:agent_module) => module(), required(:agent_id) => String.t()}

  @callback fetch_context(identity()) :: {:ok, OhMyJido.Context.t()} | {:error, term()}
end
