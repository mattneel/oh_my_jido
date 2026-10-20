# Modified by Oh-My-Jido contributors, 2026-10-19: contain opt-in native
# lifecycle task failures. Apache-2.0; see LICENSE and UPSTREAM.json.
defmodule Jido.AgentServer.TaskSupport do
  @moduledoc false

  alias Jido.Tracing.Context, as: TraceContext
  alias Jido.AgentServer.PrivateDiagnostics

  def task_ref?(%{task: %Task{ref: ref}}, ref), do: true
  def task_ref?(_pending, _ref), do: false

  def task_timer?(%{task: %Task{ref: ref}, timer: timer}, ref, timer), do: true
  def task_timer?(_pending, _ref, _timer), do: false

  def start_traced(jido, fun, timeout, tag) do
    trace = TraceContext.capture()
    private? = PrivateDiagnostics.active?()

    task =
      Task.Supervisor.async(Jido.task_supervisor_name(jido), fn ->
        PrivateDiagnostics.run(private?, fn -> TraceContext.with_context(trace, fun) end)
      end)

    %{task: task, timer: start_task_timer(timeout, tag, task.ref)}
  end

  def settle(pending, {:result, _result}), do: release_task_result(pending)
  def settle(pending, {:down, _reason}), do: cancel_task_timer(pending.timer)
  def settle(pending, :timeout), do: shutdown_task(pending.task)

  def release_task_result(%{task: %Task{ref: ref}, timer: timer}) do
    Process.demonitor(ref, [:flush])
    cancel_task_timer(timer)
  end

  def stop_task(%{task: %Task{} = task} = pending) do
    cancel_task_timer(Map.get(pending, :timer))
    shutdown_task(task)
  end

  def stop_task(nil), do: :ok

  def shutdown_task(%Task{} = task) do
    _result = Task.shutdown(task, :brutal_kill)
    :ok
  end

  def finite_timeout(:infinity), do: 5_000
  def finite_timeout(timeout), do: timeout

  def start_task_timer(:infinity, _tag, _task_ref), do: nil

  def start_task_timer(timeout, tag, task_ref) do
    :erlang.start_timer(timeout, self(), {tag, task_ref})
  end

  def cancel_task_timer(nil), do: :ok

  def cancel_task_timer(timer) do
    _result = :erlang.cancel_timer(timer)
    :ok
  end
end
