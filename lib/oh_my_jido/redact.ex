defmodule OhMyJido.Redact do
  @moduledoc "Secret removal and bounded summaries at persistence and event boundaries."

  @secret_keys ~w(api_key access_token refresh_token id_token authorization password client_secret token_secret cookie set-cookie)

  @doc "Removes credential-bearing fields and known secret values recursively."
  @spec sanitize(term(), [String.t()], pos_integer()) :: term()
  def sanitize(value, secrets \\ [], max_bytes \\ 8_192)

  def sanitize(value, secrets, max_bytes) when is_binary(value) do
    value = Enum.reduce(secrets, value, &replace_secret/2)
    if byte_size(value) > max_bytes, do: truncate(value, max_bytes), else: value
  end

  def sanitize(%_{} = value, secrets, max_bytes) do
    value |> Map.from_struct() |> sanitize(secrets, max_bytes)
  end

  def sanitize(value, secrets, max_bytes) when is_map(value) do
    Map.new(value, fn {key, item} ->
      result = if secret_key?(key), do: "[REDACTED]", else: sanitize(item, secrets, max_bytes)
      {key, result}
    end)
  end

  def sanitize(value, secrets, max_bytes) when is_list(value) do
    value |> Enum.take(100) |> Enum.map(&sanitize(&1, secrets, max_bytes))
  end

  def sanitize(value, secrets, max_bytes) when is_tuple(value) do
    value |> Tuple.to_list() |> sanitize(secrets, max_bytes) |> List.to_tuple()
  end

  def sanitize(value, _secrets, _max_bytes)
      when is_pid(value) or is_reference(value) or is_function(value),
      do: nil

  def sanitize(value, _secrets, _max_bytes), do: value

  @doc "Collects only credential values, for transient per-session redaction."
  @spec secrets(term()) :: [String.t()]
  def secrets(value) when is_map(value) or is_list(value) do
    Enum.flat_map(value, fn
      {key, item} when is_binary(item) -> if secret_key?(key), do: [item], else: []
      {_key, item} -> secrets(item)
      _item -> []
    end)
  end

  def secrets(_value), do: []

  @doc false
  @spec credential_field?(term()) :: boolean()
  def credential_field?(key), do: secret_key?(key)

  defp secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))
  defp secret_key?(key) when is_binary(key), do: String.downcase(key) in @secret_keys
  defp secret_key?(_key), do: false

  defp replace_secret(secret, value) when is_binary(secret) and byte_size(secret) > 0,
    do: String.replace(value, secret, "[REDACTED]")

  defp replace_secret(_secret, value), do: value

  defp truncate(value, max_bytes) do
    prefix = binary_part(value, 0, max_bytes)
    prefix = if String.valid?(prefix), do: prefix, else: valid_prefix(prefix)
    prefix <> "…[truncated]"
  end

  defp valid_prefix(<<>>), do: ""

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: valid_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
