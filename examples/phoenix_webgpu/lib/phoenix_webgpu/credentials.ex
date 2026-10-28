defmodule PhoenixWebGPU.Credentials do
  @moduledoc "Resolves server credentials at request time; browser requests receive no credentials."

  @doc "Oh-My-Jido credential callback; keyless providers bypass resolution in the runtime."
  @spec resolve(OhMyJido.Context.t(), term(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  def resolve(_context, "openrouter", _opts) do
    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, [api_key: key]}
      _missing -> {:error, :openrouter_api_key_required}
    end
  end

  def resolve(_context, _account, _opts), do: {:error, :unknown_account}
end
