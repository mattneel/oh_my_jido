defmodule OhMyJido.Plugin.ContextProvider do
  @moduledoc """
  Looks up a trusted tool context for an agent using `OhMyJido.Plugin`.

  Implement `fetch_context/1` and select your module in the agent's plugin
  configuration. The callback receives only `%{agent_module: module, agent_id: id}`.
  Look up those identities in application-owned resources; do not take authority
  from signal data, tool arguments, agent state, or checkpoints.

  Return `{:ok, context}` with a validated `OhMyJido.Context` containing the
  workspace, permissions, tool selection, and service bindings. Return
  `{:error, :not_bound}` when the application has no binding for that agent.

  Lookups run inside each coding Action, not when the agent struct is built.
  The plugin supplies no credentials, models, services, or default permissions.
  See the Jido agents guide.
  """

  @type identity :: %{required(:agent_module) => module(), required(:agent_id) => String.t()}

  @doc "Resolves an agent identity to its application-approved context or an explicit error."
  @callback fetch_context(identity()) :: {:ok, OhMyJido.Context.t()} | {:error, term()}
end
