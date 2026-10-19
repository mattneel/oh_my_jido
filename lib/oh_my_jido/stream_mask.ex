defmodule OhMyJido.StreamMask do
  @moduledoc false

  @marker "[REDACTED]"

  @doc false
  def compile([]), do: {nil, 0}

  def compile(secrets) do
    {:binary.compile_pattern(secrets), Enum.max(Enum.map(secrets, &byte_size/1))}
  end

  @doc false
  def push(pending, chunk, nil, _max_length), do: {pending <> chunk, ""}

  def push(pending, chunk, pattern, max_length) do
    bytes = pending <> chunk
    cut = max(byte_size(bytes) - max_length + 1, 0)

    cut =
      Enum.reduce(:binary.matches(bytes, pattern), cut, fn {offset, length}, boundary ->
        max(boundary, offset + length)
      end)

    cut = utf8_boundary(bytes, cut)
    prefix = binary_part(bytes, 0, cut)
    suffix = binary_part(bytes, cut, byte_size(bytes) - cut)
    {:binary.replace(prefix, pattern, @marker, [:global]), suffix}
  end

  @doc false
  def finish(pending, nil, _secrets), do: pending

  def finish(pending, pattern, secrets) do
    safe = :binary.replace(pending, pattern, @marker, [:global])

    ambiguous =
      Enum.reduce(secrets, 0, fn secret, maximum ->
        limit = min(byte_size(secret) - 1, byte_size(safe))
        max(maximum, suffix_prefix_length(safe, secret, limit))
      end)

    if ambiguous == 0 do
      safe
    else
      binary_part(safe, 0, byte_size(safe) - ambiguous) <> @marker
    end
  end

  defp utf8_boundary(bytes, cut) when cut > 0 and cut < byte_size(bytes) do
    if :binary.at(bytes, cut) in 128..191, do: utf8_boundary(bytes, cut - 1), else: cut
  end

  defp utf8_boundary(_bytes, cut), do: cut

  defp suffix_prefix_length(_data, _secret, 0), do: 0

  defp suffix_prefix_length(data, secret, length) do
    if binary_part(data, byte_size(data) - length, length) == binary_part(secret, 0, length) do
      length
    else
      suffix_prefix_length(data, secret, length - 1)
    end
  end
end
