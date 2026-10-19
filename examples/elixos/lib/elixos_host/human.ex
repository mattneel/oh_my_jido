defmodule ElixosHost.Human do
  @moduledoc "Finite, fail-closed questions on Elixos' own Ask queue."

  def confirm(context, capability, effect, options) do
    details =
      effect
      |> Map.take([
        :operation,
        :path,
        :url,
        :executable,
        :args,
        :candidate_id,
        :name,
        :read_only,
        :script_sha256,
        :script
      ])
      |> OhMyJido.Redact.sanitize([], 4096)

    prompt = "Authorize #{capability} for session #{context.session_id}? #{inspect(details)}"

    case ask(context, :confirm, [prompt: prompt, default: false], options) do
      {:ok, true} -> :ok
      {:ok, _answer} -> {:error, :approval_denied}
      {:error, _reason} = error -> error
    end
  end

  def ask(context, kind, question_options, host_options) do
    timeout = Keyword.get(host_options, :approval_timeout_ms, 60_000)

    if is_integer(timeout) and timeout > 0 do
      with :ok <- watch_run(context) do
        question_options = Keyword.put(question_options, :timeout, timeout)
        supervisor = Keyword.get(host_options, :approval_tasks, ElixosHost.ApprovalTasks)

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Elixos.Ask.ask(kind, question_options)
          end)

        monitor = if is_pid(context.coordinator), do: Process.monitor(context.coordinator)
        deadline = System.monotonic_time(:millisecond) + timeout + 100

        try do
          await_answer(task, monitor, context.run_id, deadline)
        after
          if monitor, do: Process.demonitor(monitor, [:flush])
          Task.shutdown(task, :brutal_kill)
        end
      end
    else
      {:error, :invalid_approval_deadline}
    end
  catch
    :exit, _reason -> {:error, :ask_service_unavailable}
  end

  defp watch_run(%{run_id: nil}), do: :ok

  defp watch_run(context) do
    session = %OhMyJido.SessionRef{runtime: context.runtime, id: context.session_id}

    with :ok <- OhMyJido.subscribe(session, self()),
         {:ok, %{active_run: run, status: :running}} when run == context.run_id <-
           OhMyJido.inspect_session(session),
         events when is_list(events) <- OhMyJido.events(session),
         false <-
           Enum.any?(
             events,
             &(&1.run_id == context.run_id and &1.kind == :cancellation_requested)
           ) do
      :ok
    else
      _closed -> {:error, :run_closed}
    end
  end

  defp await_answer(task, monitor, run_id, deadline) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ref, :process, _pid, _reason} when ref == task.ref ->
        {:error, :ask_service_failed}

      {:DOWN, ref, :process, _pid, _reason} when ref == monitor ->
        {:error, :session_closed}

      {:oh_my_jido, %OhMyJido.Event{run_id: id, kind: kind}}
      when not is_nil(run_id) and id == run_id and
             kind in [:cancellation_requested, :run_completed] ->
        {:error, :run_closed}

      {:oh_my_jido, _event} ->
        await_answer(task, monitor, run_id, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end
end
