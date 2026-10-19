defmodule OhMyJido.Event do
  @moduledoc """
  Stable host-facing event, delivered as `{:oh_my_jido, event}`.

  Sequence numbers increase across the durable session, including worker restart.
  Events expose redacted, bounded summaries; full repository data is returned to
  the authorized caller through tool results, not broadcast to subscribers.
  """

  @enforce_keys [:session_id, :seq, :kind, :at_ms]
  defstruct [:session_id, :run_id, :seq, :kind, :at_ms, payload: %{}]

  @type t :: %__MODULE__{
          session_id: String.t(),
          run_id: String.t() | nil,
          seq: non_neg_integer(),
          kind: atom(),
          at_ms: integer(),
          payload: map()
        }
end
