defmodule OhMyJido.Config do
  @moduledoc false

  @spec fetch(map(), atom()) :: {:ok, term()} | :error
  def fetch(map, key) do
    case Map.fetch(map, key) do
      :error -> Map.fetch(map, Atom.to_string(key))
      found -> found
    end
  end

  @spec get(map(), atom(), term()) :: term()
  def get(map, key, default) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
end
