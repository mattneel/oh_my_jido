defmodule OhMyJido.Event do
  @moduledoc """
  Carries session updates to subscribers as `{:oh_my_jido, event}` messages.

  Subscribe with `OhMyJido.subscribe/3`, then match the events you need:

      receive do
        {:oh_my_jido, %OhMyJido.Event{kind: :tool_output, payload: payload}} ->
          IO.write(payload.text)
      end

  `:seq` increases across the durable session, including worker restarts.
  `:run_id` can be nil for session-level updates; `:at_ms` is a millisecond
  timestamp. Payload fields depend on `:kind`. Process and Eval output both
  use `:tool_output`; Eval output also identifies its execution.

  Events are redacted, bounded summaries, not full tool results. A subscription
  receives future events only; `OhMyJido.events/2` reads the bounded history.
  Slow or dead subscribers are detached, so this is not a lossless event log.
  Treat model and repository output as data, not trusted instructions.
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
