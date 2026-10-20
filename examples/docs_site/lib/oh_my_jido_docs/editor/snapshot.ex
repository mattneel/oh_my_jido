defmodule OhMyJidoDocs.Editor.Snapshot do
  @moduledoc false

  alias OhMyJido.Redact

  @hidden ~w(
    agent_pid context oh_my_jido runtime_config host adapters credentials metadata coordinator
    source_writer_origin
  )
  @max_bytes 12_000

  def payload(value) when is_map(value) do
    {safe, _remaining} = clean(value, @max_bytes, 0)
    safe
  end

  def payload(value), do: payload(%{detail: value})

  def text(value, limit \\ 4_096)
  def text(nil, _limit), do: nil

  def text(value, limit) when is_binary(value) do
    if String.valid?(value),
      do: Redact.sanitize(value, secrets(), limit),
      else: "[binary data omitted]"
  end

  def text(value, limit), do: value |> safe_label() |> text(limit)

  def session(info) do
    fields = Map.take(info, [:id, :status, :active_run, :permissions, :role, :seq])

    effects =
      info
      |> Map.get(:effects, %{})
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :started_at, 0), :desc)
      |> Enum.take(24)
      |> Enum.map(&Map.take(&1, [:id, :name, :status, :run, :started_at, :completed_at]))

    fields
    |> Map.put(:effects, effects)
    |> payload()
  end

  defp clean(_value, budget, depth) when budget <= 0 or depth > 7,
    do: {"[truncated]", budget}

  defp clean(value, budget, _depth) when is_binary(value) do
    safe = text(value, min(2_048, max(budget - 32, 1)))
    {safe, budget - byte_size(safe) - 8}
  end

  defp clean(%_{} = value, budget, depth), do: clean(Map.from_struct(value), budget, depth)

  defp clean(value, budget, depth) when is_map(value) do
    value
    |> Enum.take(32)
    |> Enum.reduce_while({%{}, budget}, fn {key, item}, {result, remaining} ->
      key = safe_label(key)

      cond do
        remaining <= 64 ->
          {:halt, {Map.put(result, "truncated", true), remaining}}

        key in @hidden ->
          {:cont, {result, remaining}}

        Redact.credential_field?(key) ->
          {:cont, {Map.put(result, key, "[REDACTED]"), remaining - byte_size(key) - 16}}

        true ->
          key = text(key, 128)
          {safe, left} = clean(item, remaining - byte_size(key) - 8, depth + 1)
          {:cont, {Map.put(result, key, safe), left}}
      end
    end)
  end

  defp clean(value, budget, depth) when is_list(value) do
    {items, remaining} =
      value
      |> Enum.take(32)
      |> Enum.reduce_while({[], budget}, fn item, {result, remaining} ->
        if remaining <= 32 do
          {:halt, {["[truncated]" | result], remaining}}
        else
          {safe, left} = clean(item, remaining - 4, depth + 1)
          {:cont, {[safe | result], left}}
        end
      end)

    {Enum.reverse(items), remaining}
  end

  defp clean(value, budget, depth) when is_tuple(value),
    do: clean(Tuple.to_list(value), budget, depth)

  defp clean(value, budget, _depth)
       when is_pid(value) or is_reference(value) or is_function(value),
       do: {nil, budget - 4}

  defp clean(value, budget, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {value, budget - 16}

  defp clean(value, budget, depth) when is_atom(value),
    do: clean(Atom.to_string(value), budget, depth)

  defp clean(_value, budget, _depth), do: {nil, budget - 4}

  defp safe_label(value) when is_binary(value), do: value
  defp safe_label(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_label(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_label(_value), do: "unsupported"

  defp secrets do
    case Application.get_env(:oh_my_jido_docs, :model_api_key) do
      key when is_binary(key) and byte_size(key) > 0 -> [key]
      _other -> []
    end
  end
end
