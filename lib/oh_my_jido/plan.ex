defmodule OhMyJido.Plan do
  @moduledoc "Validated task plans; completed work cannot disappear or reopen silently."

  @statuses [:pending, :in_progress, :blocked, :done]

  @doc "Validates unique tasks, status values and a single active task."
  @spec validate(term()) :: {:ok, [map()]} | {:error, term()}
  def validate(items) when is_list(items) do
    if Enum.count_until(items, 101) <= 100 do
      with {:ok, items} <- normalize(items),
           true <- Enum.uniq_by(items, & &1.id) == items,
           true <- Enum.count(items, &(&1.status == :in_progress)) <= 1 do
        {:ok, items}
      else
        false -> {:error, :ambiguous_plan}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_plan}
    end
  end

  def validate(_items), do: {:error, :invalid_plan}

  @doc "Checks replacement against previous tasks and terminal transitions."
  @spec update([map()], term()) :: {:ok, [map()]} | {:error, term()}
  def update(previous, proposed) do
    with {:ok, items} <- validate(proposed),
         by_id <- Map.new(items, &{&1.id, &1}),
         true <- Enum.all?(previous, &compatible?(&1, Map.get(by_id, &1.id))) do
      {:ok, items}
    else
      false -> {:error, :plan_would_discard_completed_or_required_work}
      {:error, _reason} = error -> error
    end
  end

  @doc "Requires complete work and actual verified checks resolved by the session."
  @spec complete([map()], map()) :: :ok | {:error, term()}
  def complete([], _evidence), do: {:error, :plan_required}

  def complete(items, %{checks: checks}) when is_list(checks) and checks != [] do
    cond do
      Enum.any?(items, &(&1.status != :done)) -> {:error, :unfinished_plan}
      Enum.any?(checks, &(Map.get(&1, :status) != :verified)) -> {:error, :verification_failed}
      true -> :ok
    end
  end

  def complete(_items, _evidence), do: {:error, :verification_required}

  defp normalize(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_item(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp normalize_item(item) when is_map(item) do
    id = Map.get(item, :id, Map.get(item, "id"))
    title = Map.get(item, :title, Map.get(item, "title"))
    status = normalize_status(Map.get(item, :status, Map.get(item, "status", :pending)))
    reason = Map.get(item, :reason, Map.get(item, "reason"))

    if is_binary(id) and byte_size(id) in 1..128 and is_binary(title) and
         byte_size(title) in 1..2_048 and status in @statuses do
      if status == :blocked and (not is_binary(reason) or reason == "") do
        {:error, :blocked_task_requires_reason}
      else
        {:ok, %{id: id, title: title, status: status, reason: reason}}
      end
    else
      {:error, :invalid_task}
    end
  end

  defp normalize_item(_item), do: {:error, :invalid_task}

  defp normalize_status("pending"), do: :pending
  defp normalize_status("in_progress"), do: :in_progress
  defp normalize_status("blocked"), do: :blocked
  defp normalize_status("done"), do: :done
  defp normalize_status(value), do: value

  defp compatible?(_old, nil), do: false
  defp compatible?(%{title: title, status: :done}, %{title: title, status: :done}), do: true
  defp compatible?(%{status: :done}, _new), do: false
  defp compatible?(%{title: title}, %{title: title}), do: true
  defp compatible?(_old, _new), do: false
end
