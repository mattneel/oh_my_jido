defmodule OhMyJido.Tools.AST do
  @moduledoc "Snapshot-bound structural search and guarded targeted replacement."

  use Jido.Action,
    name: "ast",
    description:
      "Search one explicit workspace file by structural pattern, or replace matches against its SHA256 snapshot. Elixir uses ExAST; other languages require an approved AST adapter. Replacement requires expected_count and optionally exact returned ranges. Ranges use one-based lines/columns and exclusive ends.",
    schema:
      Zoi.object(
        %{
          operation: Zoi.enum(["search", "replace"]),
          path: Zoi.string() |> Zoi.min(1) |> Zoi.max(4096),
          language: Zoi.string() |> Zoi.min(1) |> Zoi.max(64) |> Zoi.optional(),
          pattern: Zoi.string() |> Zoi.min(1) |> Zoi.max(8192),
          replacement: Zoi.string() |> Zoi.max(16_384) |> Zoi.optional(),
          snapshot:
            Zoi.string()
            |> Zoi.regex(~r/\A[0-9a-f]{64}\z/)
            |> Zoi.optional(),
          expected_count: Zoi.integer() |> Zoi.min(0) |> Zoi.max(1000) |> Zoi.optional(),
          max_results: Zoi.integer() |> Zoi.min(1) |> Zoi.max(1000) |> Zoi.default(100),
          ranges:
            Zoi.list(
              Zoi.object(
                %{
                  start:
                    Zoi.object(
                      %{
                        line: Zoi.integer() |> Zoi.min(1),
                        column: Zoi.integer() |> Zoi.min(1)
                      },
                      coerce: true,
                      unrecognized_keys: :error
                    ),
                  end:
                    Zoi.object(
                      %{
                        line: Zoi.integer() |> Zoi.min(1),
                        column: Zoi.integer() |> Zoi.min(1)
                      },
                      coerce: true,
                      unrecognized_keys: :error
                    )
                },
                coerce: true,
                unrecognized_keys: :error
              )
            )
            |> Zoi.min(1)
            |> Zoi.max(1000)
            |> Zoi.optional()
        },
        coerce: true,
        unrecognized_keys: :error
      )

  @doc "Returns the Action category."
  def category, do: "intelligence"

  @spec capability() :: :ast
  def capability, do: :ast

  @impl true
  def run(params, execution_context) do
    case OhMyJido.Intelligence.AST.execute(execution_context, params) do
      {:error, %{message: message} = details}
      when is_binary(message) and not is_struct(details) ->
        {:error, Jido.Action.Error.execution_error(message, details)}

      result ->
        result
    end
  end
end
