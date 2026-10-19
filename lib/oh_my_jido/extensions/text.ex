defmodule OhMyJido.Extensions.Text do
  @moduledoc false

  @spec text(binary(), non_neg_integer()) :: {binary(), boolean()}
  def text(value, cap) when byte_size(value) <= cap, do: {value, false}
  def text(value, cap), do: {valid_prefix(binary_part(value, 0, cap)), true}

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
