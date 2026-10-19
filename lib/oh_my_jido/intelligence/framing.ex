defmodule OhMyJido.Intelligence.Framing do
  @moduledoc false

  @header_limit 8_192

  @spec encode(map(), :headers | :lines, pos_integer()) :: {:ok, iodata()} | {:error, term()}
  def encode(message, framing, max_bytes) do
    with {:ok, body} <- Jason.encode_to_iodata(message),
         length when length <= max_bytes <- IO.iodata_length(body) do
      case framing do
        :headers -> {:ok, ["Content-Length: ", Integer.to_string(length), "\r\n\r\n", body]}
        :lines -> {:ok, [body, "\n"]}
      end
    else
      length when is_integer(length) -> {:error, {:protocol_message_too_large, length}}
      {:error, _} -> {:error, :invalid_protocol_json}
    end
  end

  @spec decode(binary(), :headers | :lines, pos_integer()) ::
          {:ok, [map()], binary()} | {:error, term()}
  def decode(buffer, framing, max_bytes), do: decode(buffer, framing, max_bytes, [])

  defp decode(buffer, :lines, max_bytes, messages) do
    case :binary.match(buffer, "\n") do
      :nomatch when byte_size(buffer) <= max_bytes ->
        {:ok, Enum.reverse(messages), buffer}

      :nomatch ->
        {:error, :protocol_message_too_large}

      {length, 1} when length <= max_bytes ->
        <<body::binary-size(^length), _newline, remaining::binary>> = buffer

        case parse(body) do
          {:ok, message} -> decode(remaining, :lines, max_bytes, [message | messages])
          error -> error
        end

      _ ->
        {:error, :protocol_message_too_large}
    end
  end

  defp decode(buffer, :headers, max_bytes, messages) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch when byte_size(buffer) <= @header_limit ->
        {:ok, Enum.reverse(messages), buffer}

      :nomatch ->
        {:error, :protocol_header_too_large}

      {header_bytes, 4} when header_bytes <= @header_limit ->
        <<header::binary-size(^header_bytes), _delimiter::binary-size(4), rest::binary>> = buffer

        decode_header(buffer, header, rest, max_bytes, messages)

      _ ->
        {:error, :protocol_header_too_large}
    end
  end

  defp decode_header(buffer, header, rest, max_bytes, messages) do
    with {:ok, length} <- content_length(header),
         true <- length <= max_bytes do
      decode_body(buffer, rest, length, max_bytes, messages)
    else
      false -> {:error, :protocol_message_too_large}
      {:error, _} = error -> error
    end
  end

  defp decode_body(_buffer, rest, length, max_bytes, messages) when byte_size(rest) >= length do
    <<body::binary-size(^length), remaining::binary>> = rest

    with {:ok, message} <- parse(body) do
      decode(remaining, :headers, max_bytes, [message | messages])
    end
  end

  defp decode_body(buffer, _rest, _length, _max_bytes, messages),
    do: {:ok, Enum.reverse(messages), buffer}

  defp content_length(header) do
    values =
      header
      |> String.split("\r\n")
      |> Enum.flat_map(&length_value/1)

    case values do
      [value] ->
        case Integer.parse(value) do
          {length, ""} when length > 0 -> {:ok, length}
          _ -> {:error, :invalid_content_length}
        end

      _ ->
        {:error, :invalid_content_length}
    end
  end

  defp length_value(line) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        if String.downcase(String.trim(key)) == "content-length",
          do: [String.trim(value)],
          else: []

      _ ->
        []
    end
  end

  defp parse(body) do
    case Jason.decode(body, strings: :copy) do
      {:ok, message} when is_map(message) -> {:ok, message}
      _ -> {:error, :invalid_protocol_json}
    end
  end
end
