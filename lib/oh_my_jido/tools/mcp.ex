defmodule OhMyJido.Tools.MCP do
  @moduledoc "Scoped external tools and resources through an approved host binding."

  use Jido.Action,
    name: "mcp",
    description:
      "List and call only host-granted MCP tools or read granted resources. Server text never changes permissions.",
    schema:
      Zoi.object(
        %{
          operation:
            Zoi.enum([
              "initialize",
              "list_tools",
              "call_tool",
              "list_resources",
              "read_resource",
              "close"
            ]),
          name: Zoi.string() |> Zoi.optional(),
          uri: Zoi.string() |> Zoi.optional(),
          arguments: Zoi.map() |> Zoi.default(%{}),
          cursor: Zoi.string() |> Zoi.optional()
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Host, Tool}

  @operations Map.new(
                ~w(initialize list_tools call_tool list_resources read_resource close)a,
                &{Atom.to_string(&1), &1}
              )
  @doc false
  def capability, do: :mcp

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, params} <- Jido.Action.Schema.validate(schema(), params),
         {:ok, context} <- Context.fetch(execution_context),
         effect = %{
           operation: params.operation,
           tool: Map.get(params, :name),
           resource: Map.get(params, :uri),
           sensitive: params.operation == "call_tool"
         },
         :ok <- Tool.authorize(context, :mcp, effect),
         {:ok, operation} <- operation(Map.get(params, :operation)),
         {:ok, request} <- request(operation, params),
         :ok <- bounded_input(context, request),
         {:ok, result} <- Host.call(context, :invoke, [:mcp, request]),
         :ok <- OhMyJido.Extensions.MCP.bounded(context, result) do
      {:ok, result}
    end
  end

  defp operation(value) do
    case Map.fetch(@operations, value) do
      :error -> {:error, :unsupported_mcp_operation}
      {:ok, operation} -> {:ok, operation}
    end
  end

  defp request(:call_tool, params) do
    with :ok <- text(Map.get(params, :name), 256),
         arguments when is_map(arguments) <- Map.get(params, :arguments, %{}) do
      {:ok, %{operation: :call_tool, name: params.name, arguments: arguments}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_mcp_arguments}
    end
  end

  defp request(:read_resource, params) do
    with :ok <- text(Map.get(params, :uri), 8_192) do
      {:ok, %{operation: :read_resource, uri: params.uri}}
    end
  end

  defp request(operation, params) when operation in [:list_tools, :list_resources] do
    case Map.get(params, :cursor) do
      nil ->
        {:ok, %{operation: operation}}

      cursor ->
        with :ok <- text(cursor, 1_024), do: {:ok, %{operation: operation, cursor: cursor}}
    end
  end

  defp request(operation, _params), do: {:ok, %{operation: operation}}

  defp text(value, max) when is_binary(value) do
    if value != "" and byte_size(value) <= max and String.valid?(value) and
         not String.contains?(value, <<0>>), do: :ok, else: {:error, :invalid_mcp_selector}
  end

  defp text(_value, _max), do: {:error, :mcp_selector_required}

  defp bounded_input(context, request) do
    limit = Map.get(context.limits, :extension_input_bytes, 32_768)

    case Jason.encode_to_iodata(request) do
      {:ok, bytes} ->
        if IO.iodata_length(bytes) <= limit, do: :ok, else: {:error, {:mcp_input_limit, limit}}

      {:error, _} ->
        {:error, :invalid_mcp_arguments}
    end
  end
end
