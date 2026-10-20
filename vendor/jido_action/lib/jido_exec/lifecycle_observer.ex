# Copyright 2026 Oh-My-Jido contributors
# SPDX-License-Identifier: Apache-2.0
# Local boundary addition: sticky admission and worker-group shutdown receipts.
defmodule Jido.Exec.LifecycleObserver do
  @moduledoc false

  alias Jido.Action.Error, as: ActionError
  alias Jido.Exec.Error, as: ExecError

  @observer_key {__MODULE__, :observer}
  @receipt_key {__MODULE__, :receipt}

  def current, do: Process.get(@observer_key)

  def from_options(opts) do
    case current() do
      nil -> validate_options(opts)
      observer -> {:ok, observer}
    end
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :lifecycle_observer) do
        [] ->
          {:ok, nil}

        [off] when off in [nil, :off, false] ->
          {:ok, nil}

        [%{started: started, stopped: stopped, parent: _parent} = observer]
        when is_function(started, 1) and is_function(stopped, 2) ->
          {:ok, observer}

        _invalid ->
          {:error,
           ActionError.validation_error("Invalid lifecycle observer", %{
             option: :lifecycle_observer
           })}
      end
    else
      {:ok, nil}
    end
  end

  defp validate_options(_opts), do: {:ok, nil}

  def options(nil), do: []
  def options(observer), do: [lifecycle_observer: observer]

  def wrap(nil, work), do: work

  def wrap(observer, work) do
    fn ->
      previous = Process.put(@observer_key, observer)

      try do
        work.()
      after
        if is_nil(previous),
          do: Process.delete(@observer_key),
          else: Process.put(@observer_key, previous)
      end
    end
  end

  # Only the actual control installs a receipt, after its private supervisor
  # exists. Workers inherit admission policy and parent token, not this receipt.
  def started(nil, _call, _owner), do: :ok

  def started(observer, call, owner) do
    proof = %{
      controller: self(),
      supervisor: call.supervisor,
      execution_id: call.execution_id,
      owner: owner,
      parent: observer.parent
    }

    case invoke_started(observer.started, proof) do
      {:ok, token} ->
        register(observer, token, proof)
        :ok

      {:halt, token} ->
        register(observer, token, proof)

        {:error,
         ExecError.cancelled_error("Execution rejected by lifecycle observer", %{
           operation: :lifecycle_admission,
           retry: false
         })}

      :error ->
        {:error,
         ExecError.execution_error("Execution lifecycle observer failed", %{
           operation: :lifecycle_admission,
           retry: false
         })}
    end
  end

  defp register(observer, token, proof) do
    Process.put(@observer_key, %{observer | parent: token})
    Process.put(@receipt_key, {observer, token, proof, :pending})
  end

  # Error completion can shut the group down before the final cleanup. A later
  # :noproc is only idempotent success when this control already crossed the
  # synchronous barrier. An initially missing/failed supervisor is not proof.
  def shutdown_completed(outcome) do
    case Process.get(@receipt_key) do
      {observer, token, proof, :pending} ->
        status = if outcome == :ok, do: :stopped, else: :failed
        Process.put(@receipt_key, {observer, token, proof, status})

      {observer, token, proof, :stopped} when outcome not in [:ok, :already_stopped] ->
        Process.put(@receipt_key, {observer, token, proof, :failed})

      _unobserved_or_unchanged ->
        :ok
    end

    :ok
  end

  def stopped do
    case Process.delete(@receipt_key) do
      {observer, token, proof, :stopped} ->
        invoke_stopped(observer.stopped, token, Map.put(proof, :workers_stopped, true))

      _no_completed_receipt ->
        :ok
    end
  end

  defp invoke_started(callback, proof) do
    sensitive = Process.flag(:sensitive, true)

    try do
      case callback.(proof) do
        {:ok, token} -> {:ok, token}
        {:halt, token, _reason} -> {:halt, token}
        _failure -> :error
      end
    catch
      _kind, _reason -> :error
    after
      Process.flag(:sensitive, sensitive)
    end
  end

  defp invoke_stopped(callback, token, proof) do
    sensitive = Process.flag(:sensitive, true)

    try do
      callback.(token, proof)
      :ok
    catch
      _kind, _reason -> :ok
    after
      Process.flag(:sensitive, sensitive)
    end
  end
end
