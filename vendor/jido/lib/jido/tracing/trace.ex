defmodule Jido.Tracing.Trace do
  @moduledoc """
  Trace data helpers for signal correlation.

  Provides functions to create and attach trace data to signals using
  the Jido.Signal.Ext.Trace extension (namespace: "correlation").
  """

  alias Jido.Signal

  @trace_namespace "correlation"

  @doc """
  Creates a new root trace with fresh trace_id and span_id.
  """
  @spec new_root() :: map()
  def new_root do
    %{
      trace_id: generate_id(),
      span_id: generate_id(),
      parent_span_id: nil,
      causation_id: nil
    }
  end

  @doc """
  Creates a child trace from a parent trace context.

  The child trace:
  - Inherits the same trace_id
  - Gets a new span_id
  - Has parent_span_id set to the parent's span_id
  - Has causation_id set to the provided value (typically the parent signal's id)
  """
  @spec child_of(map(), String.t()) :: map()
  def child_of(%{trace_id: trace_id, span_id: parent_span_id}, causation_id)
      when is_binary(causation_id) do
    %{
      trace_id: trace_id,
      span_id: generate_id(),
      parent_span_id: parent_span_id,
      causation_id: causation_id
    }
  end

  @doc """
  Attaches trace data to a signal using the correlation extension.
  """
  @spec put(Signal.t(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def put(%Signal{} = signal, trace_data) when is_map(trace_data) do
    filtered_data =
      trace_data
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Signal.put_extension(signal, @trace_namespace, filtered_data)
  end

  def put(_signal, _trace_data) do
    {:error, :invalid_args}
  end

  @doc """
  Gets trace data from a signal.
  """
  @spec get(Signal.t()) :: map() | nil
  def get(%Signal{} = signal) do
    Signal.get_extension(signal, @trace_namespace)
  end

  defp generate_id do
    Signal.ID.generate!()
  end
end
