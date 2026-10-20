defmodule OhMyJido.NativeScopes do
  @moduledoc false

  # Only unpinned, closed nodes enter the ordered history. Removing a history
  # entry when it becomes pinned avoids a second, ever-growing queue of tombstones.
  defstruct nodes: %{},
            history: :gb_sets.empty(),
            depths: :gb_sets.empty(),
            active: 0,
            serial: 0,
            total_limit: 0,
            history_limit: 0

  @opaque t :: %__MODULE__{}
  @type scope_node :: %{
          effect: term(),
          origin: term(),
          parent: reference() | nil,
          depth: pos_integer(),
          live?: boolean(),
          pins: non_neg_integer(),
          closed_at: non_neg_integer() | nil
        }

  @spec new(pos_integer(), non_neg_integer()) :: t()
  def new(total_limit, history_limit)
      when is_integer(total_limit) and total_limit > 0 and is_integer(history_limit) and
             history_limit >= 0 and history_limit <= total_limit do
    %__MODULE__{total_limit: total_limit, history_limit: history_limit}
  end

  @spec admit(t(), reference(), term(), term(), reference() | nil) ::
          {:ok, t()} | {:error, term()}
  def admit(%__MODULE__{} = registry, token, effect, origin, parent) when is_reference(token) do
    with false <- Map.has_key?(registry.nodes, token),
         {:ok, ancestors, depth} <- ancestry(registry, parent, effect, origin),
         :ok <- depth_capacity(registry, depth),
         registry = pin(registry, ancestors),
         {:ok, registry} <- make_room(registry) do
      node = %{
        effect: effect,
        origin: origin,
        parent: parent,
        depth: depth,
        live?: true,
        pins: 0,
        closed_at: nil
      }

      {:ok,
       %{
         registry
         | nodes: Map.put(registry.nodes, token, node),
           depths: :gb_sets.add({depth, token}, registry.depths),
           active: registry.active + 1
       }}
    else
      true -> {:error, :native_execution_unconfirmed}
      {:error, _reason} = error -> error
    end
  end

  def admit(%__MODULE__{}, _token, _effect, _origin, _parent),
    do: {:error, :native_execution_unconfirmed}

  @spec fetch(t(), reference()) :: {:ok, scope_node()} | :error
  def fetch(%__MODULE__{} = registry, token), do: Map.fetch(registry.nodes, token)

  @spec close(t(), reference()) :: t()
  def close(%__MODULE__{} = registry, token) do
    case Map.fetch(registry.nodes, token) do
      {:ok, %{live?: true} = node} ->
        serial = registry.serial + 1
        node = %{node | live?: false, closed_at: serial}

        registry = %{
          registry
          | nodes: Map.put(registry.nodes, token, node),
            active: registry.active - 1,
            serial: serial
        }

        registry
        |> cache_closed(token, node)
        |> unpin(node.parent)
        |> trim_history()

      _closed_or_expired ->
        registry
    end
  end

  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = registry) do
    total = map_size(registry.nodes)
    history = :gb_sets.size(registry.history)

    %{
      total: total,
      active: registry.active,
      pinned: total - registry.active - history,
      history: history,
      history_entries: history,
      max_depth: max_depth(registry.depths),
      total_limit: registry.total_limit,
      active_limit: registry.total_limit,
      depth_limit: registry.total_limit,
      history_limit: registry.history_limit
    }
  end

  defp ancestry(_registry, nil, _effect, _origin), do: {:ok, [], 1}

  defp ancestry(registry, parent, effect, origin) do
    case Map.fetch(registry.nodes, parent) do
      {:ok, %{effect: ^effect, origin: ^origin, depth: depth}} ->
        collect_ancestors(registry, parent, effect, origin, depth, [], depth + 1)

      _expired_or_unrelated ->
        {:error, :native_execution_parent_unconfirmed}
    end
  end

  # A cached closed node may outlive an evicted, closed ancestor. Such a token
  # remains inspectable but cannot start work with incomplete ancestry. Depth
  # strictly decreases, so traversal is bounded and cannot follow a cycle.
  defp collect_ancestors(_registry, nil, _effect, _origin, 0, ancestors, depth),
    do: {:ok, ancestors, depth}

  defp collect_ancestors(registry, token, effect, origin, expected, ancestors, depth)
       when expected > 0 do
    case Map.fetch(registry.nodes, token) do
      {:ok, %{effect: ^effect, origin: ^origin, depth: ^expected, parent: parent}} ->
        collect_ancestors(
          registry,
          parent,
          effect,
          origin,
          expected - 1,
          [token | ancestors],
          depth
        )

      _expired_or_unrelated ->
        {:error, :native_execution_parent_unconfirmed}
    end
  end

  defp collect_ancestors(_registry, _token, _effect, _origin, _expected, _ancestors, _depth),
    do: {:error, :native_execution_parent_unconfirmed}

  defp depth_capacity(registry, depth) do
    if depth <= registry.total_limit,
      do: :ok,
      else: {:error, {:capacity, :native_scope_depth}}
  end

  defp pin(registry, ancestors) do
    Enum.reduce(ancestors, registry, fn token, registry ->
      node = Map.fetch!(registry.nodes, token)

      history =
        if not node.live? and node.pins == 0,
          do: :gb_sets.delete({node.closed_at, token}, registry.history),
          else: registry.history

      %{
        registry
        | nodes: Map.put(registry.nodes, token, %{node | pins: node.pins + 1}),
          history: history
      }
    end)
  end

  defp unpin(registry, nil), do: registry

  defp unpin(registry, token) do
    node = Map.fetch!(registry.nodes, token)
    node = %{node | pins: node.pins - 1}

    %{registry | nodes: Map.put(registry.nodes, token, node)}
    |> cache_closed(token, node)
    |> unpin(node.parent)
  end

  defp cache_closed(registry, token, %{live?: false, pins: 0, closed_at: serial}) do
    %{registry | history: :gb_sets.add({serial, token}, registry.history)}
  end

  defp cache_closed(registry, _token, _node), do: registry

  defp make_room(registry) do
    cond do
      map_size(registry.nodes) < registry.total_limit -> {:ok, registry}
      :gb_sets.is_empty(registry.history) -> {:error, {:capacity, :native_scopes}}
      true -> registry |> evict_oldest() |> make_room()
    end
  end

  defp trim_history(registry) do
    if :gb_sets.size(registry.history) > registry.history_limit,
      do: registry |> evict_oldest() |> trim_history(),
      else: registry
  end

  defp evict_oldest(registry) do
    {{_serial, token}, history} = :gb_sets.take_smallest(registry.history)
    {node, nodes} = Map.pop!(registry.nodes, token)

    %{
      registry
      | nodes: nodes,
        history: history,
        depths: :gb_sets.delete({node.depth, token}, registry.depths)
    }
  end

  defp max_depth(depths) do
    if :gb_sets.is_empty(depths), do: 0, else: elem(:gb_sets.largest(depths), 0)
  end
end
