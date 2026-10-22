defmodule OhMyJido.SessionRef do
  @moduledoc """
  Identifies a session across worker restarts without storing a PID.

  Public session functions return and accept this reference:

      %OhMyJido.SessionRef{runtime: MyApp.Coding, id: "review-session"}

  `:runtime` is the configured runtime name and `:id` is the session's string
  identity. A reference does not prove the session is currently running.
  Use `OhMyJido.resume_session/2` to restore a stored session.
  """
  @enforce_keys [:runtime, :id]
  defstruct [:runtime, :id]
  @type t :: %__MODULE__{runtime: atom(), id: String.t()}
end
