defmodule OhMyJido.Eval.Output do
  @moduledoc false

  alias OhMyJido.Redact

  def new(limit, secrets \\ []) do
    retain =
      Enum.reduce(secrets, 0, fn secret, size ->
        if is_binary(secret), do: max(size, byte_size(secret) - 1), else: size
      end)

    %{
      remaining: limit,
      stdout: [],
      stderr: [],
      display: "",
      displays: [],
      artifacts: [],
      error: nil,
      diagnostics: [],
      truncated: false,
      secrets: secrets,
      pending: %{stdout: "", stderr: ""},
      retain: retain
    }
  end

  def text(output, stream, text) when stream in [:stdout, :stderr] do
    previous = Map.fetch!(output.pending, stream)
    available = output.remaining + byte_size(previous)
    combined = redact(previous <> text, output.secrets)
    {bounded, clipped?} = clip(combined, available)
    {piece, _split?} = clip(bounded, max(byte_size(bounded) - output.retain, 0))
    pending = binary_part(bounded, byte_size(piece), byte_size(bounded) - byte_size(piece))

    next = %{
      output
      | remaining: available - byte_size(bounded),
        pending: Map.put(output.pending, stream, pending),
        truncated: output.truncated or clipped?
    }

    {append_stream(next, stream, piece), piece}
  end

  def text(output, field, text) when field in [:display, :displays, :error] do
    text = redact(text, output.secrets)
    {piece, clipped?} = clip(text, output.remaining)

    next = %{
      output
      | remaining: output.remaining - byte_size(piece),
        truncated: output.truncated or clipped?
    }

    case {field, piece} do
      {:display, _piece} -> {%{next | display: piece}, piece}
      {:error, _piece} -> {%{next | error: piece}, piece}
      {_field, ""} -> {next, ""}
      {:displays, _piece} -> {%{next | displays: [piece | next.displays]}, piece}
    end
  end

  def flush(output) do
    Enum.reduce([:stdout, :stderr], {output, []}, fn stream, {acc, events} ->
      text = Map.fetch!(acc.pending, stream)
      acc = %{acc | pending: Map.put(acc.pending, stream, "")}
      {append_stream(acc, stream, text), [{stream, text} | events]}
    end)
  end

  defp append_stream(output, _stream, ""), do: output
  defp append_stream(output, stream, text), do: Map.update!(output, stream, &[text | &1])

  defp redact(text, secrets), do: Redact.sanitize(text, secrets, max(byte_size(text) * 10, 16))

  def artifact(output, name, media_type, data)
      when is_binary(name) and is_binary(media_type) and is_binary(data) do
    if valid_name?(name) and byte_size(media_type) <= 128 do
      name = Redact.sanitize(name, output.secrets, 128)
      media_type = Redact.sanitize(media_type, output.secrets, 128)
      clean = Redact.sanitize(data, output.secrets, max(byte_size(data), 1))

      {encoding, payload} =
        if String.valid?(clean), do: {"utf-8", clean}, else: {"base64", Base.encode64(clean)}

      cost = byte_size(name) + byte_size(media_type) + byte_size(encoding) + byte_size(payload)

      if cost <= output.remaining do
        item = %{
          name: name,
          media_type: media_type,
          data: payload,
          encoding: encoding,
          bytes: byte_size(clean)
        }

        {:ok,
         %{output | artifacts: [item | output.artifacts], remaining: output.remaining - cost}}
      else
        {:error, :output_limit, %{output | truncated: true}}
      end
    else
      {:error, :invalid_artifact, output}
    end
  end

  def artifact(output, _name, _media_type, _data), do: {:error, :invalid_artifact, output}

  def diagnostics(output, entries) do
    Enum.reduce(Enum.take(entries, 100), output, fn entry, acc ->
      clean = Redact.sanitize(entry, acc.secrets, acc.remaining)
      encoded = inspect(clean, limit: 50, printable_limit: acc.remaining)

      if byte_size(encoded) <= acc.remaining do
        %{
          acc
          | diagnostics: [clean | acc.diagnostics],
            remaining: acc.remaining - byte_size(encoded)
        }
      else
        %{acc | truncated: true}
      end
    end)
  end

  def finish(output) do
    output
    |> Map.take([
      :stdout,
      :stderr,
      :display,
      :displays,
      :artifacts,
      :diagnostics,
      :truncated,
      :error
    ])
    |> Map.update!(:stdout, &(&1 |> Enum.reverse() |> IO.iodata_to_binary()))
    |> Map.update!(:stderr, &(&1 |> Enum.reverse() |> IO.iodata_to_binary()))
    |> Map.update!(:displays, &Enum.reverse/1)
    |> Map.update!(:artifacts, &Enum.reverse/1)
    |> Map.update!(:diagnostics, &Enum.reverse/1)
  end

  def clip(text, size) when byte_size(text) <= size, do: {text, false}
  def clip(text, size), do: {valid_prefix(binary_part(text, 0, max(size, 0))), true}

  def inspect_value(value, limit), do: value |> render_value(limit) |> elem(0)

  def render_value(value, limit) do
    value |> inspect(limit: 100, printable_limit: limit, width: 100) |> clip(limit)
  end

  def structured(value, max_bytes) do
    with {:ok, bytes, _nodes} <- budget(value, max_bytes, 1_024, 0),
         true <- bytes >= 0,
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= max_bytes,
         {:ok, decoded} <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      false -> {:error, :bridge_output_limit}
      _ -> {:error, :non_structured_value}
    end
  end

  defp budget(_value, bytes, nodes, depth) when bytes < 0 or nodes <= 0 or depth > 16,
    do: {:error, :bridge_output_limit}

  defp budget(%_{} = _value, _bytes, _nodes, _depth), do: {:error, :non_structured_value}

  defp budget(value, bytes, nodes, _depth) when is_binary(value),
    do: {:ok, bytes - byte_size(value) - 2, nodes - 1}

  defp budget(value, bytes, nodes, depth) when is_map(value) and map_size(value) <= 128 do
    Enum.reduce_while(value, {:ok, bytes - 2, nodes - 1}, fn {key, item}, {:ok, left, count} ->
      with {:ok, left, count} <- budget(key, left, count, depth + 1),
           {:ok, left, count} <- budget(item, left - 2, count, depth + 1) do
        {:cont, {:ok, left, count}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp budget(value, bytes, nodes, depth) when is_list(value) do
    Enum.reduce_while(value, {:ok, bytes - 2, nodes - 1}, fn item, {:ok, left, count} ->
      case budget(item, left - 1, count, depth + 1) do
        {:ok, left, count} -> {:cont, {:ok, left, count}}
        error -> {:halt, error}
      end
    end)
  end

  defp budget(value, bytes, nodes, _depth) when is_atom(value),
    do: {:ok, bytes - byte_size(Atom.to_string(value)) - 2, nodes - 1}

  defp budget(value, bytes, nodes, _depth) when is_number(value),
    do: {:ok, bytes - 24, nodes - 1}

  defp budget(_value, _bytes, _nodes, _depth), do: {:error, :non_structured_value}

  defp valid_name?(name) do
    byte_size(name) in 1..255 and Path.basename(name) == name and name not in [".", ".."] and
      not String.contains?(name, ["\\", <<0>>])
  end

  defp valid_prefix(<<>>), do: ""

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
