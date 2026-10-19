defmodule OhMyJido.Plugin.RejectRequest do
  @moduledoc false
  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  @impl true
  def transform_request(_request, _state, _config, context) do
    reason = get_in(context, [:tool_context, :oh_my_jido_rejection])
    {:error, reason || {:rejected, :coding_tool_policy, "OhMyJido.Plugin rejected request"}}
  end
end
