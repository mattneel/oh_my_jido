defmodule OhMyJido.Plugin.Result do
  @moduledoc false
  use Jido.Agent.Directive

  @enforce_keys [:value]
  defstruct [:value]

  @impl true
  def validate(%__MODULE__{value: value} = result) when is_map(value) and not is_struct(value) do
    with :ok <- Jido.PortableTerm.validate(value, [:oh_my_jido_tools]), do: {:ok, result}
  end

  def validate(_result), do: {:error, {:oh_my_jido_plugin, :invalid_tool_result}}
end
