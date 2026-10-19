defmodule OhMyJido.Tools do
  @moduledoc "The native Jido Actions available to a coding session, subject to host capabilities."

  alias OhMyJido.Tools

  @type selection_error ::
          {:unknown_bundle, atom()}
          | {:invalid_bundle, term()}
          | {:invalid_bundle_selection, :expected_atom_or_list}

  @doc """
  Returns named tool availability bundles, never permission grants.

  Optional services still require explicit host configuration. In particular,
  `:live_inspection` exposes Observer, not live execution or isolated Eval.
  """
  @spec bundles() :: %{atom() => [module()]}
  def bundles do
    %{
      read_only: [Tools.Read, Tools.Search, Tools.List],
      editing: [Tools.Write, Tools.Edit],
      elixir: [Tools.AST, Tools.LSP, Tools.Debug],
      process: [Tools.Shell, Tools.Git],
      live_inspection: [Tools.Observer]
    }
  end

  @doc """
  Selects a bundle or list of bundles in caller order.

  The first occurrence of each Action wins; an empty list selects no tools.
  Names must be atoms already known to the host. Strings are never converted.
  """
  @spec select(atom() | [atom()]) :: {:ok, [module()]} | {:error, selection_error()}
  def select(bundle) when is_atom(bundle), do: select([bundle])

  def select(selection) when is_list(selection) do
    with {:ok, selected} <- select_bundles(selection, bundles(), []) do
      {:ok, selected |> Enum.reverse() |> Enum.uniq()}
    end
  end

  def select(_selection), do: {:error, {:invalid_bundle_selection, :expected_atom_or_list}}

  @doc "Selects bundles or raises an ArgumentError describing the configuration error."
  @spec select!(atom() | [atom()]) :: [module()]
  def select!(selection) do
    case select(selection) do
      {:ok, selected} ->
        selected

      {:error, reason} ->
        available = bundles() |> Map.keys() |> Enum.sort()

        raise ArgumentError,
              "invalid tool bundles: #{inspect(reason)}; available bundles: #{inspect(available)}"
    end
  end

  @doc "Returns the complete registry; unavailable host services fail explicitly at invocation."
  @spec default() :: [module()]
  def default do
    [
      Tools.Read,
      Tools.Write,
      Tools.Edit,
      Tools.Search,
      Tools.List,
      Tools.Shell,
      Tools.Git,
      Tools.AST,
      Tools.LSP,
      Tools.Debug,
      Tools.Observer,
      Tools.MCP,
      Tools.Browser,
      Tools.Research,
      Tools.Artifact,
      Tools.Review,
      Tools.Eval,
      Tools.Skill,
      Tools.ClaudeCode,
      Tools.Goal,
      Tools.Memory,
      Tools.Question,
      Tools.Experiment,
      Tools.Subagent
    ]
  end

  defp select_bundles([], _bundles, selected), do: {:ok, selected}

  defp select_bundles([bundle | rest], bundles, selected) when is_atom(bundle) do
    case Map.fetch(bundles, bundle) do
      {:ok, actions} -> select_bundles(rest, bundles, Enum.reverse(actions, selected))
      :error -> {:error, {:unknown_bundle, bundle}}
    end
  end

  defp select_bundles([bundle | _rest], _bundles, _selected),
    do: {:error, {:invalid_bundle, bundle}}

  defp select_bundles(_selection, _bundles, _selected),
    do: {:error, {:invalid_bundle_selection, :expected_atom_or_list}}
end
