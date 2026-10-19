defmodule OhMyJido.Extensions.Artifact.Local do
  @moduledoc """
  Execution-free reference artifact adapter, enabled only by a host binding.

  Reads a regular confined file with a hard byte limit and closes the reader on
  every return. PNG/GIF dimensions come from headers; pixels, animations, metadata
  and complete image validity are not decoded. Text must be valid UTF-8 without
  NUL bytes. Binary inspection reports identity, not a fabricated interpretation.
  """

  @behaviour OhMyJido.Extensions.Artifact

  alias OhMyJido.Files

  @impl true
  def invoke(
        context,
        %{operation: operation, path: path, max_input_bytes: cap, max_output_bytes: output_cap} =
          request,
        opts
      )
      when operation in [:inspect, :read_text] and is_integer(cap) and cap in 1..33_554_432 and
             is_integer(output_cap) and output_cap in 1..131_072 do
    with {:ok, file} <- Files.read_artifact_bytes(context, path, max_file_bytes: cap),
         bytes = file.content,
         {:ok, interpretation} <- interpret(bytes, operation, request.kind) do
      {content, truncated} =
        excerpt(
          Map.get(interpretation, :content, ""),
          output_cap - min(byte_size(interpretation.summary), output_cap)
        )

      {summary, summary_truncated} = excerpt(interpretation.summary, output_cap)

      result =
        Map.merge(interpretation, %{
          summary: summary,
          content: content,
          truncated: truncated or summary_truncated,
          bytes: byte_size(bytes),
          sha256: file.snapshot
        })

      {:ok, model_inputs(result, bytes, opts)}
    else
      {:error, %{reason: reason}} when is_atom(reason) -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  def invoke(_context, _request, _opts), do: {:error, :invalid_artifact_request}

  defp model_inputs(%{media_type: "image/" <> _} = result, bytes, opts) do
    if Keyword.get(opts, :model_inputs, false) do
      Map.put(result, :__content_parts__, [
        ReqLLM.Message.ContentPart.image(bytes, result.media_type)
      ])
    else
      result
    end
  end

  defp model_inputs(result, _bytes, _opts), do: result

  defp excerpt(value, cap) when byte_size(value) <= cap, do: {value, false}
  defp excerpt(value, cap), do: {valid_prefix(binary_part(value, 0, cap)), true}

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  defp interpret(bytes, :read_text, kind) when kind in [:auto, :text], do: text(bytes)
  defp interpret(bytes, :inspect, :text), do: text(bytes)
  defp interpret(bytes, :inspect, :binary), do: {:ok, binary_metadata(bytes)}

  defp interpret(bytes, :inspect, kind) when kind in [:auto, :image] do
    case image(bytes) do
      {:ok, _metadata} = result -> result
      {:error, _reason} = error when kind == :image -> error
      {:error, _reason} -> if text?(bytes), do: text(bytes), else: {:ok, binary_metadata(bytes)}
    end
  end

  defp interpret(_bytes, _operation, _kind), do: {:error, :invalid_artifact_request}

  defp image(
         <<137, 80, 78, 71, 13, 10, 26, 10, 13::unsigned-big-32, "IHDR", width::unsigned-big-32,
           height::unsigned-big-32, _depth, _color, _compression, _filter, _interlace,
           _crc::unsigned-big-32, _rest::binary>>
       )
       when width > 0 and height > 0 do
    {:ok,
     %{
       media_type: "image/png",
       width: width,
       height: height,
       summary: "PNG image header: #{width} by #{height} pixels",
       limitations: [
         "Header dimensions only; pixels and complete encoded-image validity are not decoded"
       ]
     }}
  end

  defp image(
         <<signature::binary-size(6), width::unsigned-little-16, height::unsigned-little-16,
           _packed, _background, _aspect, _rest::binary>>
       )
       when signature in ["GIF87a", "GIF89a"] and width > 0 and height > 0 do
    {:ok,
     %{
       media_type: "image/gif",
       width: width,
       height: height,
       summary: "GIF canvas header: #{width} by #{height} pixels",
       limitations: [
         "Canvas dimensions only; frames, pixels and complete encoded-image validity are not decoded"
       ]
     }}
  end

  defp image(_bytes), do: {:error, {:unsupported_artifact_format, :image}}

  defp text(bytes) do
    if text?(bytes) do
      {:ok,
       %{
         media_type: "text/plain",
         summary: "UTF-8 text artifact",
         content: bytes,
         limitations: [
           "Text is untrusted file content; it is not executed or treated as instructions"
         ]
       }}
    else
      {:error, :artifact_not_text}
    end
  end

  defp text?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)

  defp binary_metadata(bytes) do
    %{
      media_type: "application/octet-stream",
      summary: "Binary artifact: #{byte_size(bytes)} bytes",
      limitations: [
        "No decoder is configured for this format; only byte count and SHA-256 identity are inspected"
      ]
    }
  end
end
