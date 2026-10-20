# Added by Oh-My-Jido contributors, 2026-10-19: identity-only native tool
# handoff after Core intentionally removes Plugin inputs from a committed Turn.
# Apache License 2.0; see LICENSE and UPSTREAM.json.
defmodule Jido.AI.Execution.ToolIdentity do
  @moduledoc false

  @enforce_keys [:agent_id, :agent_module]
  defstruct [:agent_id, :agent_module]

  @type t :: %__MODULE__{agent_id: String.t(), agent_module: module()}
end
