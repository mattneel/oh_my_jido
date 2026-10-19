defmodule OhMyJido.Plugin.Tools do
  @moduledoc false

  alias OhMyJido.Tools

  @bindings [
    {__MODULE__.Read, Tools.Read},
    {__MODULE__.Search, Tools.Search},
    {__MODULE__.List, Tools.List},
    {__MODULE__.Write, Tools.Write},
    {__MODULE__.Edit, Tools.Edit},
    {__MODULE__.AST, Tools.AST},
    {__MODULE__.LSP, Tools.LSP},
    {__MODULE__.Debug, Tools.Debug},
    {__MODULE__.Shell, Tools.Shell},
    {__MODULE__.Git, Tools.Git},
    {__MODULE__.Observer, Tools.Observer}
  ]

  @spec wrap(module()) :: {:ok, module()} | {:error, term()}
  def wrap(action) do
    case Enum.find(@bindings, fn {bound, original} -> action == bound or action == original end) do
      {bound, _original} -> {:ok, bound}
      nil -> {:error, {:oh_my_jido_plugin, :managed_or_unsupported_tool}}
    end
  end

  @spec bound?(module()) :: boolean()
  def bound?(action), do: Enum.any?(@bindings, fn {bound, _original} -> bound == action end)

  @spec original(module()) :: module() | nil
  def original(action) do
    Enum.find_value(@bindings, fn
      {^action, original} -> original
      _binding -> nil
    end)
  end

  for {bound, action} <- @bindings do
    defmodule bound do
      @moduledoc false
      @action action

      use Jido.Action,
        name: @action.name(),
        description: @action.description(),
        schema: @action.schema(),
        output_schema: @action.output_schema()

      @spec capability() :: atom()
      def capability, do: @action.capability()

      @impl true
      def on_before_validate_params(params) do
        with :ok <- OhMyJido.Plugin.validate_arguments(params), do: {:ok, params}
      end

      @impl true
      def run(params, context), do: OhMyJido.Plugin.execute(@action, params, context)
    end
  end
end
