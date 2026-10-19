defmodule OhMyJido.Extensions do
  @moduledoc """
  Closes host-bound extension resources at session teardown.

  Adapters that own resources may implement `close_session(context, opts)`;
  callback-only browser/research/artifact integrations remain host-owned and
  must release their own resources on cancellation or the explicit close call.
  Cleanup never executes a model-selected module or widens capability grants.
  """

  alias OhMyJido.Context

  @capabilities [:ast, :lsp, :debug, :observer, :mcp, :browser, :research, :artifact, :review]

  @spec close_session(Context.t() | map()) :: :ok | {:error, [map()]}
  def close_session(execution_context) do
    with {:ok, context} <- Context.fetch(execution_context) do
      failures =
        Enum.flat_map(@capabilities, &close_capability(context, &1))

      if failures == [], do: :ok, else: {:error, failures}
    end
  end

  defp close_capability(context, capability) do
    case Map.get(context.adapters, capability) do
      {module, opts} when is_atom(module) and is_list(opts) ->
        close_adapter(module, context, opts, capability)

      _ ->
        []
    end
  end

  defp close_adapter(module, context, opts, capability) do
    if Code.ensure_loaded?(module) and function_exported?(module, :close_session, 2) do
      case module.close_session(context, opts) do
        :ok -> []
        {:ok, _} -> []
        {:error, reason} -> [%{capability: capability, reason: reason}]
        _ -> [%{capability: capability, reason: :invalid_cleanup_result}]
      end
    else
      []
    end
  catch
    kind, reason -> [%{capability: capability, reason: {:cleanup_failed, kind, reason}}]
  end
end
