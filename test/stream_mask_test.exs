defmodule OhMyJido.StreamMaskTest do
  use ExUnit.Case, async: true
  alias OhMyJido.StreamMask

  test "every credential split is masked while unrelated bytes retain exact order" do
    secret = "opaque-credential-value"
    {pattern, length} = StreamMask.compile([secret])

    for split <- 1..(byte_size(secret) - 1) do
      chunks = [
        "Unicode λ before " <> binary_part(secret, 0, split),
        binary_part(secret, split, byte_size(secret) - split) <> " after\r\n"
      ]

      {emitted, pending} =
        Enum.map_reduce(chunks, "", fn chunk, pending ->
          {value, pending} = StreamMask.push(pending, chunk, pattern, length)
          {value, pending}
        end)

      assert Enum.all?(emitted, &String.valid?/1)
      result = IO.iodata_to_binary(emitted) <> StreamMask.finish(pending, pattern, [secret])
      assert result == "Unicode λ before [REDACTED] after\r\n"
      refute String.contains?(result, secret)
    end
  end

  test "overlapping credentials use the longest match and EOF hides an ambiguous prefix" do
    secrets = ["abc", "abcdef"]
    {pattern, length} = StreamMask.compile(secrets)
    {value, pending} = StreamMask.push("", "abcdef abc end", pattern, length)
    assert value <> StreamMask.finish(pending, pattern, secrets) == "[REDACTED] [REDACTED] end"
    assert StreamMask.finish("prefix ab", pattern, secrets) == "prefix [REDACTED]"
  end
end
