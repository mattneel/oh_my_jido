defmodule OhMyJido.Eval.Backend do
  @moduledoc "Lifecycle contract for persistent, crash-separated language kernels."

  @type handle :: map()
  @type request :: %{
          required(:id) => String.t(),
          required(:source) => String.t(),
          required(:timeout) => pos_integer(),
          required(:output_limit) => pos_integer(),
          required(:generation) => pos_integer()
        }

  @callback open(OhMyJido.Context.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  @callback execute(handle(), request()) :: {:ok, map()} | {:error, term()}
  @callback interrupt(handle(), String.t() | nil) :: :ok | {:error, term()}
  @callback reset(handle()) :: {:ok, handle()} | {:error, term()}
  @callback close(handle()) :: :ok | {:error, term()}
end
