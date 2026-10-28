defmodule PhoenixWebGPU.BrowserEval do
  @moduledoc "Host-authorized JavaScript evaluation in the delegating user's tab."
  use Jido.Action,
    name: "browser_eval",
    description:
      "Run a JavaScript function body in the user's page. Use return for a JSON result; await is supported.",
    schema: Zoi.object(%{source: Zoi.string()})

  alias OhMyJido.{Context, Tool}

  @doc "DOM evaluation is a custom mutating capability, not a filesystem read grant."
  @spec capability() :: :custom
  def capability, do: :custom

  @impl true
  def run(%{source: source}, execution_context) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- Tool.authorize(context, :custom),
         :ok <- browser_child(context) do
      result = WebLLM.Live.eval(context.metadata.browser_client, source)
      send(context.metadata.browser_observer, {:browser_eval, source, result})
      tool_result(result)
    end
  end

  # Small models read a bare null as "nothing there"; say what happened instead.
  defp tool_result({:ok, nil}),
    do: {:ok, %{value: nil, note: "The function body returned nothing. Use return <value>."}}

  defp tool_result({:ok, value}), do: {:ok, %{value: value}}
  defp tool_result({:error, _reason} = error), do: error

  defp browser_child(%{metadata: %{delegation_depth: depth, browser_client: client}})
       when depth > 0 and is_binary(client),
       do: :ok

  defp browser_child(_context), do: {:error, :delegate_browser_work_first}
end
