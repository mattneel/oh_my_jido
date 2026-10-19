defmodule OhMyJido.Extensions.URL do
  @moduledoc false

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) and byte_size(value) in 1..4096 do
    String.valid?(value) and not Regex.match?(~r/[\s\x00-\x1f\x7f]/u, value) and
      case URI.parse(value) do
        %URI{scheme: scheme, host: host, userinfo: nil} when scheme in ["http", "https"] ->
          is_binary(host) and host != ""

        _invalid ->
          false
      end
  end

  def valid?(_value), do: false
end
