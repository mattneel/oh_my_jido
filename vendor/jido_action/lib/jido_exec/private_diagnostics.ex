# Copyright 2026 Oh-My-Jido contributors
# SPDX-License-Identifier: Apache-2.0
# Local boundary addition: opt-in diagnostic privacy for native Exec processes.
defmodule Jido.Exec.PrivateDiagnostics do
  @moduledoc false

  require Logger

  @policy_key {__MODULE__, :policy}

  def current, do: Process.get(@policy_key)
  def active?, do: match?(%{private?: true}, current())

  def from_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :private_diagnostics) do
        [] -> {:ok, current()}
        [%{error: projector, private?: true} = policy] when is_function(projector, 1) -> {:ok, policy}
        _invalid -> {:error, Jido.Action.Error.validation_error("Invalid private diagnostics policy")}
      end
    else
      {:ok, current()}
    end
  end

  def from_options(_opts), do: {:ok, current()}

  def options(nil), do: []
  def options(policy), do: [private_diagnostics: policy]

  def wrap(nil, work), do: work
  def wrap(policy, work), do: fn -> run(policy, work) end

  def run(nil, work), do: work.()

  def run(%{private?: true} = policy, work) do
    previous = Process.put(@policy_key, policy)
    sensitive = Process.flag(:sensitive, true)

    try do
      work.()
    catch
      kind, reason ->
        Logger.error("Private native execution process failed",
          kind: kind,
          error: error(reason),
          stacktrace: stacktrace(__STACKTRACE__)
        )

        exit({:shutdown, :private_execution_failed})
    after
      if is_nil(previous), do: Process.delete(@policy_key), else: Process.put(@policy_key, previous)
      Process.flag(:sensitive, sensitive)
    end
  end

  def error(value) do
    case current() do
      %{error: projector, private?: true} -> project(projector, value)
      _ordinary -> value
    end
  end

  defp project(projector, value) do
    projector.(value)
  rescue
    _exception -> %{type: :private_diagnostic_unavailable}
  catch
    _kind, _reason -> %{type: :private_diagnostic_unavailable}
  end

  defp stacktrace(frames) do
    Enum.flat_map(frames, fn
      {module, function, arity, _location} when is_integer(arity) ->
        [{module, function, arity}]

      {module, function, arguments, _location} when is_list(arguments) ->
        [{module, function, length(arguments)}]

      _frame ->
        []
    end)
  end
end
