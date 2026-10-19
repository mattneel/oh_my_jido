defmodule OhMyJido.Experiment do
  @moduledoc "Bounded registered-tool experiments with durable measured results and artifact references."

  alias OhMyJido.{Context, Session, Tool}

  @doc """
  Runs each explicit trial once; uncertain effects are never automatically retried.

  Every result includes its exact session receipt and effect certainty. If
  retention fails after execution, the structured error returns the complete
  experiment record under `:experiment` instead of discarding trial evidence.
  """
  @spec run(OhMyJido.SessionRef.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(session, trials, opts \\ []) do
    with {:ok, context} <- Session.call(session, :context) do
      execute(context, trials, opts)
    end
  end

  @doc false
  @spec execute(Context.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(context, trials, opts) do
    limit = Map.get(context.limits, :max_experiment_trials, 8)

    with true <- is_list(trials) and trials != [],
         trial_count = length(trials),
         true <- trial_count <= limit,
         true <- Enum.all?(trials, &valid_trial?/1),
         :ok <- Tool.authorize(context, :experiments, %{trials: trial_count}) do
      id = Jido.Util.generate_id()
      results = Enum.map(trials, &run_trial(context, &1, opts))

      record = %{
        id: id,
        results: results,
        effect: experiment_effect(results),
        completed_at: System.system_time(:millisecond),
        status: if(Enum.all?(results, &(&1.status == :completed)), do: :completed, else: :failed)
      }

      retain_record(context, record)
    else
      false -> {:error, :invalid_or_excessive_trials}
      {:error, _reason} = error -> error
    end
  end

  defp valid_trial?(%{tool: tool, params: params}) when is_binary(tool) and is_map(params),
    do: true

  defp valid_trial?(_trial), do: false

  defp run_trial(context, trial, opts) do
    id = Jido.Util.generate_id()
    started = System.monotonic_time(:microsecond)

    result =
      Tool.execute(context, trial.tool, trial.params,
        timeout: Keyword.get(opts, :timeout, 30_000),
        effect_id: id
      )

    duration = System.monotonic_time(:microsecond) - started

    {receipt, effect, receipt_error} =
      trial_receipt(Session.effect_receipt(context.coordinator, id))

    %{
      tool: trial.tool,
      duration_us: duration,
      status: trial_status(result, effect),
      effect: effect,
      result: json_value(result),
      receipt: receipt,
      receipt_error: receipt_error
    }
  end

  defp trial_receipt({:ok, %{status: :completed} = receipt}), do: {receipt, :completed, nil}
  defp trial_receipt({:ok, receipt}), do: {receipt, :uncertain, nil}

  defp trial_receipt({:error, :effect_not_recorded}),
    do: {nil, :not_started, :effect_not_recorded}

  defp trial_receipt({:error, reason}), do: {nil, :uncertain, reason}

  defp trial_status({:ok, _value}, :completed), do: :completed
  defp trial_status({:ok, _value, _effects}, :completed), do: :completed
  defp trial_status(_result, _effect), do: :failed

  defp experiment_effect(results) do
    cond do
      Enum.any?(results, &(&1.effect == :uncertain)) -> :uncertain
      Enum.any?(results, &(&1.effect == :completed)) -> :completed
      true -> :not_started
    end
  end

  defp retain_record(context, record) do
    case Session.call(
           context.coordinator,
           {:retain, %{memory: %{("experiment:" <> record.id) => record}}}
         ) do
      :ok ->
        emit_record(context, record)

      {:error, reason} ->
        recording_error(:experiment_retention_failed, reason, record)
    end
  end

  defp emit_record(context, record) do
    case Session.call(
           context.coordinator,
           {:emit, :experiment_completed,
            %{id: record.id, status: record.status, results: record.results}}
         ) do
      :ok -> {:ok, record}
      {:error, reason} -> recording_error(:experiment_notification_failed, reason, record)
    end
  end

  defp recording_error(reason, cause, record) do
    {:error, %{reason: reason, cause: cause, effect: record.effect, experiment: record}}
  end

  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, json_value(item)} end)

  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_pid(value) or is_reference(value) or is_function(value), do: nil
  defp json_value(value), do: value
end
