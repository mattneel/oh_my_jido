defmodule OhMyJido.SessionRef do
  @moduledoc "A durable session identity, independent of a local worker PID."
  @enforce_keys [:runtime, :id]
  defstruct [:runtime, :id]
  @type t :: %__MODULE__{runtime: atom(), id: String.t()}
end
