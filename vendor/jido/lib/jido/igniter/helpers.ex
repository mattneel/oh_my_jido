defmodule Jido.Igniter.Helpers do
  @moduledoc false
  # Internal helpers for Jido Igniter generators

  @doc """
  Derives a snake_case name from a module.
  E.g. MyApp.Agents.Coordinator -> "coordinator"
  """
  @spec module_to_name(module() | String.t()) :: String.t()
  def module_to_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  def module_to_name(module) when is_binary(module) do
    module
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  @doc """
  Parses a comma-separated list of items.
  """
  @spec parse_list(String.t() | nil) :: [String.t()]
  def parse_list(nil), do: []

  def parse_list(str) when is_binary(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
