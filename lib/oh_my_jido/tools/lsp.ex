defmodule OhMyJido.Tools.LSP do
  @moduledoc """
  Permission-checked language intelligence with guarded rename application.

  Completed rename receipts retain every written path and snapshot when optional
  server identity and planning metadata exceed the result budget. Typed adapter
  failures retain their cause and effect certainty, even if that failure itself
  cannot fit the budget.
  """

  use Jido.Action,
    name: "lsp",
    description:
      "Use a host-bound language server for diagnostics, definitions, references, symbols, and snapshot-guarded rename.",
    schema:
      Zoi.object(
        %{
          operation:
            Zoi.enum([
              "initialize",
              "open",
              "change",
              "close_document",
              "diagnostics",
              "definition",
              "references",
              "symbols",
              "rename",
              "shutdown"
            ]),
          path: Zoi.string() |> Zoi.optional(),
          line: Zoi.integer() |> Zoi.min(0) |> Zoi.optional(),
          character: Zoi.integer() |> Zoi.min(0) |> Zoi.optional(),
          version: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
          new_name: Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          snapshot: Zoi.string() |> Zoi.optional(),
          snapshots: Zoi.map() |> Zoi.default(%{}),
          apply: Zoi.boolean() |> Zoi.default(false),
          include_declaration: Zoi.boolean() |> Zoi.default(true)
        },
        unrecognized_keys: :error
      )

  alias OhMyJido.{Context, Host, Tool, Workspace}

  @operations Map.new(
                ~w(initialize open change close_document diagnostics definition references symbols rename shutdown)a,
                &{Atom.to_string(&1), &1}
              )
  @doc false
  def capability, do: :lsp

  @impl true
  def run(params, execution_context) do
    with {:ok, params} <- validate_params(params),
         {:ok, context} <- Context.fetch(execution_context),
         :ok <-
           Tool.authorize(context, :lsp, %{
             operation: Map.get(params, :operation),
             path: Map.get(params, :path)
           }),
         {:ok, operation} <- operation(Map.get(params, :operation)),
         {:ok, request} <- request(context, operation, params),
         :ok <- authorize_edit(context, request) do
      response(context, request, Host.call(context, :invoke, [:lsp, request]))
    end
  end

  defp operation(value) do
    case Map.fetch(@operations, value) do
      :error -> {:error, :unsupported_lsp_operation}
      {:ok, operation} -> {:ok, operation}
    end
  end

  defp request(_context, operation, _params) when operation in [:initialize, :shutdown],
    do: {:ok, %{operation: operation}}

  defp request(context, operation, params) do
    with path when is_binary(path) <- Map.get(params, :path),
         {:ok, absolute} <- Workspace.resolve(context, path),
         :ok <- position_required(operation, params),
         :ok <- rename_required(operation, params) do
      request =
        Map.take(params, [
          :line,
          :character,
          :version,
          :new_name,
          :snapshot,
          :snapshots,
          :apply,
          :include_declaration
        ])

      {:ok,
       Map.merge(request, %{operation: operation, path: Workspace.relative(context, absolute)})}
    else
      nil -> {:error, :lsp_path_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_lsp_request}
    end
  end

  defp position_required(operation, params)
       when operation in [:definition, :references, :rename] do
    if Enum.all?(
         [:line, :character],
         &(is_integer(Map.get(params, &1)) and Map.get(params, &1) >= 0)
       ), do: :ok, else: {:error, :lsp_position_required}
  end

  defp position_required(_operation, _params), do: :ok

  defp rename_required(:rename, params) do
    name = Map.get(params, :new_name)
    snapshot = Map.get(params, :snapshot)

    cond do
      not valid_rename_name?(name) ->
        {:error, :invalid_rename_name}

      Map.get(params, :apply, false) and
          not (is_binary(snapshot) and Regex.match?(~r/\A[0-9a-f]{64}\z/, snapshot)) ->
        {:error, :lsp_snapshot_required}

      not is_map(Map.get(params, :snapshots, %{})) ->
        {:error, :invalid_lsp_snapshots}

      true ->
        :ok
    end
  end

  defp rename_required(_operation, _params), do: :ok

  defp valid_rename_name?(name) when is_binary(name) and byte_size(name) in 1..256,
    do: not String.contains?(name, ["\n", "\r", <<0>>])

  defp valid_rename_name?(_name), do: false

  defp authorize_edit(context, %{operation: :rename, apply: true} = request) do
    Tool.authorize(context, :edit, %{
      operation: :lsp_rename,
      path: request.path,
      snapshot: Map.get(request, :snapshot),
      sensitive: true
    })
  end

  defp authorize_edit(_context, _request), do: :ok

  defp response(context, %{operation: :rename, apply: true}, {:ok, %{applied: true} = result}) do
    result = Map.put_new(result, :effect, :completed)

    case bounded(context, result) do
      {:ok, _result} = bounded ->
        bounded

      {:error, _reason} ->
        case bounded(context, Map.drop(result, [:identity, :rename_metadata])) do
          {:ok, _receipt} = bounded ->
            bounded

          {:error, reason} ->
            {:error,
             %{
               reason: reason,
               applied: true,
               effect: result.effect,
               result: :unavailable,
               retry: false
             }}
        end
    end
  end

  defp response(context, %{operation: :rename, apply: true}, {:error, reason} = error)
       when is_map(reason) and not is_struct(reason) do
    case bounded(context, reason) do
      {:ok, _reason} ->
        error

      {:error, _limit} ->
        case bounded(context, Map.drop(reason, [:identity, :rename_metadata])) do
          {:ok, receipt} -> {:error, receipt}
          {:error, _limit} -> error
        end
    end
  end

  defp response(context, _request, {:ok, result}), do: bounded(context, result)
  defp response(_context, _request, error), do: error

  defp bounded(context, result) do
    maximum = Map.get(context.limits, :extension_result_bytes, 65_536)

    case Jason.encode_to_iodata(result) do
      {:ok, encoded} ->
        if is_integer(maximum) and IO.iodata_length(encoded) <= maximum,
          do: {:ok, result},
          else: {:error, {:extension_result_limit, :lsp, maximum}}

      {:error, _} ->
        {:error, :invalid_lsp_result}
    end
  end
end
