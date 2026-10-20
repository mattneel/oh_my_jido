defmodule OhMyJidoDocs.Editor.Observer do
  @moduledoc false

  use GenServer
  require Logger

  alias OhMyJido.{Event, Runtime}
  alias OhMyJidoDocs.Editor.{Host, Run, Settings, Snapshot, Store, WriterLease, Writers}
  alias OhMyJidoDocs.Repo
  alias OhMyJidoDocs.Workspaces

  @runtime OhMyJidoDocs.Coding
  @tasks OhMyJidoDocs.Editor.Tasks
  @interval 1_000
  @terminal ~w(completed failed cancelled suspended interrupted timed_out)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def call(request) do
    if Application.get_env(:oh_my_jido_docs, :editor_enabled, false) do
      GenServer.call(__MODULE__, request, 30_000)
    else
      {:error, :editor_disabled}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :editor_unavailable}
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # A restarted observer must not let discard overtake a surviving creator
    # that has not yet acquired Workspaces' source lock.
    orphans = Map.new(Task.Supervisor.children(@tasks), &{Process.monitor(&1), &1})

    writers =
      Map.new(WriterLease.entries(), fn {id, pid, metadata} ->
        {id, %{pid: pid, token: metadata.token, monitor: Process.monitor(pid)}}
      end)

    {:ok,
     %{
       tasks: %{},
       orphans: orphans,
       sessions: %{},
       writers: writers,
       writer_pending?: map_size(writers) > 0,
       recovery: MapSet.new(),
       cleanup_pending?: false,
       database_unavailable?: false,
       boot?: true
     }, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    state = reconcile(state)
    Process.send_after(self(), :reconcile, @interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(_request, _from, %{database_unavailable?: true} = state),
    do: {:reply, {:error, :writer_state_unavailable}, state}

  def handle_call({:start_run, attrs, opts}, _from, state) do
    with {:ok, attrs} <- Settings.prepare(attrs, opts),
         :ok <- capacity(),
         {:ok, run} <- Store.create(attrs) do
      case start_workspace(run, opts, state) do
        {:ok, state} ->
          {:reply, {:ok, run}, state}

        {:error, reason, state} ->
          state = workspace_failed(run, :workspace_task_failed, reason, state)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:answer, id, question_id, answer}, _from, state) do
    with {:ok, run} <- Store.get(id),
         true <- is_binary(question_id) and Map.has_key?(run.pending_questions, question_id),
         true <- valid_answer?(answer),
         {:ok, session, state} <- ensure_session(run, state) do
      result = OhMyJido.answer(session, question_id, answer)
      state = if result == :ok, do: sync(run, session, state), else: state
      {:reply, result, state}
    else
      false -> {:reply, {:error, :unknown_question}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, id, text, opts}, _from, state) do
    with {:ok, run} <- Store.get(id),
         true <-
           is_binary(text) and String.valid?(text) and byte_size(text) in 1..16_384 and
             String.trim(text) != "" do
      steer(run, Snapshot.text(text, 16_384), opts, state)
    else
      false -> {:reply, {:error, :invalid_steering}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({operation, id}, _from, state) when operation in [:cancel, :suspend] do
    case Store.get(id) do
      {:ok, run} -> control(run, operation, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume, id}, _from, state) do
    with {:ok, run} <- Store.get(id),
         true <- run.status in ["suspended", "interrupted"] do
      resume_run(run, state)
    else
      false -> {:reply, {:error, :not_suspended}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reconcile_writer, id, expected_claim}, _from, state) do
    with {:ok, run} <- Store.get(id),
         true <- is_binary(expected_claim) and run.source_writer_token == expected_claim,
         true <- run.source_writer_pending do
      case Writers.acknowledge_absence(run) do
        {:ok, _run} ->
          state = state |> detach(run.session_id) |> forget_writer(run.id)
          {:reply, :ok, %{state | recovery: MapSet.delete(state.recovery, run.id)}}

        {:error, reason, _run} ->
          {:reply, {:error, reason}, state}
      end
    else
      false -> {:reply, {:error, :writer_claim_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(message, %{database_unavailable?: true} = state)
      when message not in [:reconcile, :reconcile_now],
      do: {:noreply, state}

  def handle_info({:oh_my_jido, %Event{} = event}, state) do
    state =
      if Map.has_key?(state.sessions, event.session_id),
        do: ingest_live_event(event, state),
        else: state

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _tasks} ->
        {:noreply, state}

      {task, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | tasks: tasks}

        state =
          case task.kind do
            :workspace -> workspace_result(task, result, state)
            :discard -> cleanup_result(task, result, state)
          end

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{orphans: orphans} = state)
      when is_map_key(orphans, ref) do
    send(self(), :reconcile_now)
    {:noreply, %{state | orphans: Map.delete(orphans, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {task, tasks} when not is_nil(task) ->
        {:noreply, task_down(task, reason, %{state | tasks: tasks})}

      {nil, _tasks} ->
        {:noreply, monitored_down(ref, reason, state)}
    end
  end

  def handle_info(:reconcile, state) do
    state = reconcile(state)
    Process.send_after(self(), :reconcile, @interval)
    {:noreply, state}
  end

  def handle_info({:writer_native_down, id, token, _pid}, state) do
    case Store.get(id) do
      {:ok, %{source_writer_token: ^token} = run} ->
        state = interrupted(run.id, state)
        {:noreply, recover_writer(run, state)}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info(:reconcile_now, state), do: {:noreply, reconcile(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.writers, &terminate_writer/1)
    :ok
  rescue
    _unavailable -> :ok
  end

  defp terminate_writer({id, _entry}) do
    with {:ok, run} <- Store.get(id),
         {:ok, lease} <- WriterLease.lookup(run) do
      run = Writers.uncertain(run, :observer_shutdown)

      case live_pid(Writers.ref(run)) do
        pid when is_pid(pid) -> Writers.stop(run, lease, pid)
        nil -> Writers.settle_down(run, lease)
      end
    end
  end

  defp ingest_live_event(event, state) do
    case Store.by_session(event.session_id) do
      %Run{last_native_seq: previous} = run when event.seq > previous ->
        run = ingest(run, event)
        if event.kind == :run_completed, do: sync_live(run, state), else: state

      _old_or_unowned ->
        state
    end
  end

  defp task_down(task, reason, state) do
    case Store.get(task.run_id) do
      {:ok, run} when task.kind == :discard ->
        cleanup_failed(run, {:task_down, reason}, state)

      {:ok, %{status: "queued"} = run} ->
        workspace_failed(run, :workspace_task_failed, reason, state)

      {:ok, %{workspace_cleanup_pending: true} = run} ->
        start_discard(run, state)

      _gone ->
        state
    end
  end

  defp monitored_down(ref, reason, state) do
    case Enum.find(state.writers, fn {_id, entry} -> entry.monitor == ref end) do
      {id, _entry} -> writer_down(id, reason, state)
      nil -> session_down(ref, state)
    end
  end

  defp session_down(ref, state) do
    case Enum.find(state.sessions, fn {_id, entry} -> entry.monitor == ref end) do
      nil ->
        state

      {id, entry} ->
        state = %{state | sessions: Map.delete(state.sessions, id)}
        state = interrupted(entry.run_id, state)
        send(self(), :reconcile_now)
        state
    end
  end

  defp start_workspace(run, opts, state) do
    task = Task.Supervisor.async_nolink(@tasks, fn -> Workspaces.create(run.id) end)
    entry = %{kind: :workspace, run_id: run.id, opts: opts, pid: task.pid}
    {:ok, %{state | tasks: Map.put(state.tasks, task.ref, entry)}}
  rescue
    RuntimeError -> {:error, :workspace_capacity, state}
  catch
    :exit, _reason -> {:error, :workspace_capacity, state}
  end

  defp workspace_result(task, result, state) do
    case Store.get(task.run_id) do
      {:ok, %{status: "queued"} = run} ->
        case result do
          {:ok, %{workspace: workspace, base_revision: revision}}
          when is_binary(workspace) and is_binary(revision) ->
            run =
              Store.append(run.id, "workspace_prepared", %{base_revision: revision}, %{
                workspace: workspace,
                base_revision: revision
              })

            begin_session(run, task.opts, state)

          {:error, reason} ->
            workspace_failed(run, :workspace_failed, reason, state)

          _invalid ->
            workspace_failed(run, :invalid_workspace_result, :invalid_workspace_result, state)
        end

      {:ok, %{workspace_cleanup_pending: true} = run} ->
        start_discard(run, state)

      _gone ->
        state
    end
  end

  defp start_discard(run, state) do
    state = %{state | cleanup_pending?: true}
    busy? = Enum.any?(state.tasks, fn {_ref, task} -> task.run_id == run.id end)

    if map_size(state.orphans) > 0 or busy? do
      state
    else
      task = Task.Supervisor.async_nolink(@tasks, fn -> Workspaces.discard(run.id) end)
      entry = %{kind: :discard, run_id: run.id, pid: task.pid}
      %{state | tasks: Map.put(state.tasks, task.ref, entry)}
    end
  rescue
    RuntimeError -> %{state | cleanup_pending?: true}
  catch
    :exit, _reason -> %{state | cleanup_pending?: true}
  end

  defp cleanup_result(task, result, state) do
    case Store.get(task.run_id) do
      {:ok, run} when result == :ok ->
        Store.append(run.id, "workspace_discarded", %{replay: false}, %{
          workspace_cleanup_pending: false,
          workspace: nil,
          base_revision: nil
        })

        %{state | cleanup_pending?: Store.cleanup_runs() != []}

      {:ok, run} ->
        cleanup_failed(run, result, state)

      {:error, :not_found} ->
        state
    end
  end

  defp cleanup_failed(run, reason, state) do
    Store.append(run.id, "workspace_cleanup_failed", %{reason: reason, replay: false}, %{
      workspace_cleanup_pending: true
    })

    %{state | cleanup_pending?: true}
  end

  defp workspace_failed(run, kind, reason, state) do
    run =
      Store.append(run.id, Atom.to_string(kind), %{reason: reason, replay: false}, %{
        status: "failed",
        workspace_cleanup_pending: true,
        summary: "Source workspace preparation failed; its allocation is being discarded."
      })

    start_discard(run, state)
  end

  defp begin_session(run, opts, state) do
    case acquire_writer(run, state) do
      {:ok, run, state} ->
        begin_leased_session(run, opts, state)

      {:error, reason, state} ->
        fail(run, :source_writer_unavailable, reason)
        state
    end
  end

  defp begin_leased_session(run, opts, state) do
    case start_native(run, :new) do
      {:ok, session} ->
        attach_new_session(run, session, opts, state)

      {:error, reason} ->
        run = fail(run, :native_session_failed, reason)
        release_unstarted(run, reason, state)
    end
  end

  defp attach_new_session(run, session, opts, state) do
    case attach(run, session, state) do
      {:ok, state} ->
        begin_attached_session(run, session, opts, state)

      {:error, reason, state} ->
        run = fail(run, :native_subscription_failed, reason)
        recover_writer(run, state)
    end
  end

  defp begin_attached_session(run, session, opts, state) do
    case OhMyJido.checkpoint(session) do
      :ok ->
        run = ingest_buffer(run, session)

        run =
          Store.append(run.id, "native_turn_requested", %{replay: false}, %{
            status: "running"
          })

        {_result, state} = begin_turn(run, session, run.task, opts, state)
        state

      {:error, reason} ->
        fail(run, :initial_checkpoint_failed, reason)
        checkpoint_and_stop(run, session, state)
    end
  end

  defp begin_turn(run, session, task, opts, state) do
    case OhMyJido.prompt(session, task, opts) do
      {:ok, native_id} ->
        run = Store.refresh(run, %{native_run_id: native_id})
        {{:ok, native_id}, sync(run, session, state)}

      {:error, reason} ->
        run = ingest_buffer(run, session)
        fail(run, :native_prompt_failed, reason)
        {{:error, reason}, checkpoint_and_stop(run, session, state)}
    end
  end

  defp steer(%{status: "ready"} = run, text, opts, state) do
    with :ok <- Settings.request_options(opts),
         :ok <- capacity(),
         {:ok, session, state} <- ensure_session(run, state) do
      run =
        Store.append(run.id, "native_turn_requested", %{task: text, replay: false}, %{
          status: "running",
          summary: nil,
          pending_questions: %{}
        })

      {result, state} = begin_turn(run, session, text, opts, state)
      {:reply, result, state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp steer(_run, _text, opts, state) when opts != [],
    do: {:reply, {:error, :invalid_run_options}, state}

  defp steer(%{status: status} = run, text, [], state) when status in ["running", "waiting"] do
    case ensure_session(run, state) do
      {:ok, session, state} ->
        {:reply, OhMyJido.steer(session, run.native_run_id, text), state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp steer(_run, _text, [], state), do: {:reply, {:error, :run_not_active}, state}

  defp control(%{status: "queued"} = run, :cancel, state) do
    Store.append(
      run.id,
      "run_cancelled",
      %{phase: :workspace, replay: false, cleanup_pending: true},
      %{status: "cancelled", pending_questions: %{}, workspace_cleanup_pending: true}
    )

    {:reply, :ok, %{state | cleanup_pending?: true}}
  end

  defp control(%{status: status} = run, operation, state) when status in ["running", "waiting"] do
    with {:ok, session, state} <- ensure_session(run, state),
         {:ok, info} <- OhMyJido.inspect_session(session),
         native_id when is_binary(native_id) <- info.active_run do
      result = control_native(session, native_id, operation)
      record_control(run, operation, result)
      {:reply, result, state}
    else
      nil -> {:reply, {:error, :run_not_active}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp control(_run, _operation, state), do: {:reply, {:error, :run_not_active}, state}

  defp control_native(session, native_id, :cancel), do: OhMyJido.cancel(session, native_id)
  defp control_native(session, native_id, :suspend), do: OhMyJido.suspend(session, native_id)

  defp record_control(run, operation, :ok) do
    status = if operation == :cancel, do: "cancelling", else: "suspending"
    Store.append(run.id, "control_requested", %{operation: operation}, %{status: status})
  end

  defp record_control(_run, _operation, _result), do: :ok

  defp ensure_session(%{workspace: nil}, state), do: {:error, :workspace_unavailable, state}

  defp ensure_session(run, state) do
    with {:ok, run, state} <- acquire_writer(run, state) do
      session = Writers.ref(run)

      result =
        if is_pid(live_pid(session)),
          do: {:ok, session},
          else: start_native(run, :restore)

      ensure_attached(result, run, state)
    end
  end

  defp ensure_attached({:ok, session}, run, state) do
    case attach(run, session, state) do
      {:ok, state} -> {:ok, session, state}
      {:error, reason, state} -> {:error, reason, recover_writer(run, state)}
    end
  end

  defp ensure_attached({:error, reason}, run, state),
    do: {:error, reason, release_unstarted(run, reason, state)}

  defp ensure_attached(_missing, run, state),
    do: {:error, :checkpoint_unavailable, release_unstarted(run, :checkpoint_unavailable, state)}

  defp start_native(run, mode) do
    with {:ok, lease} <- WriterLease.lookup(run),
         :ok <- WriterLease.begin_native(lease) do
      case mode do
        :new -> OhMyJido.start_session(@runtime, Settings.session_options(run))
        :restore -> OhMyJido.resume_session(@runtime, run.session_id)
      end
    end
  end

  defp attach(run, session, state) do
    with :ok <- OhMyJido.subscribe(session, self(), max_pending: 512),
         pid when is_pid(pid) <- live_pid(session),
         {:ok, lease} <- WriterLease.lookup(run),
         :ok <- Writers.bind(run, lease, pid),
         :ok <- register_secret(session, pid, state) do
      state = track_session(run, session, pid, state)

      {:ok, %{state | recovery: MapSet.delete(state.recovery, run.id)}}
    else
      nil -> {:error, :session_unavailable, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp track_session(run, session, pid, state) do
    case Map.get(state.sessions, session.id) do
      %{pid: ^pid} ->
        state

      old ->
        if old, do: Process.demonitor(old.monitor, [:flush])
        entry = %{run_id: run.id, ref: session, pid: pid, monitor: Process.monitor(pid)}
        %{state | sessions: Map.put(state.sessions, session.id, entry)}
    end
  end

  defp ingest_buffer(run, session) do
    case OhMyJido.events(session, after: run.last_native_seq) do
      events when is_list(events) -> Enum.reduce(events, run, &ingest(&2, &1))
      {:error, _reason} -> run
    end
  end

  defp ingest(run, event) do
    run =
      if event.seq > run.last_native_seq + 1 do
        Store.append(run.id, "native_event_gap", %{
          after: run.last_native_seq,
          before: event.seq,
          replay: false
        })
      else
        run
      end

    updates = native_updates(run, event)
    Store.append(run.id, Atom.to_string(event.kind), event.payload, updates, event.seq)
  end

  defp native_updates(run, %{kind: :run_started, run_id: native_id}) do
    status =
      if run.status in ["cancelling", "suspending", "cancelled"], do: run.status, else: "running"

    %{native_run_id: native_id, status: status}
  end

  defp native_updates(run, %{kind: :approval_requested, payload: %{id: id, question: question}}) do
    pending = Map.put(run.pending_questions, id, Snapshot.payload(question))
    status = if run.status in ["cancelling", "suspending"], do: run.status, else: "waiting"
    %{pending_questions: pending, status: status}
  end

  defp native_updates(run, %{kind: :approval_answered, payload: %{id: id}}) do
    pending = Map.delete(run.pending_questions, id)

    status =
      if run.status == "waiting" and map_size(pending) == 0, do: "running", else: run.status

    %{pending_questions: pending, status: status}
  end

  defp native_updates(_run, %{kind: :run_completed, payload: %{status: status}}),
    do: %{status: terminal_status(status), pending_questions: %{}}

  defp native_updates(_run, %{kind: :cancellation_requested, payload: %{reason: reason}}),
    do: %{status: if(reason == :suspended, do: "suspending", else: "cancelling")}

  defp native_updates(_run, _event), do: %{}

  defp sync_live(run, state) do
    case Map.get(state.sessions, run.session_id) do
      nil -> state
      %{ref: session} -> sync(run, session, state)
    end
  end

  defp sync(run, session, state) do
    run = ingest_buffer(run, session)

    case OhMyJido.inspect_session(session) do
      {:ok, info} ->
        pending = Map.take(run.pending_questions, info.pending_questions)
        record = Map.get(info.runs, run.native_run_id)
        status = projected_status(run, info, record)
        summary = summary(run, record)

        run =
          Store.refresh(run, %{
            status: status,
            summary: summary,
            pending_questions: pending,
            session_snapshot: Snapshot.session(info)
          })

        if is_nil(info.active_run),
          do: checkpoint_and_stop(run, session, state),
          else: state

      {:error, _reason} ->
        interrupted(run.id, state)
    end
  end

  defp projected_status(%{status: "ready"}, %{active_run: nil}, _record), do: "ready"

  defp projected_status(%{status: status}, %{active_run: active}, _record)
       when is_binary(active) and status in ["cancelling", "suspending"], do: status

  defp projected_status(_run, %{active_run: active, pending_questions: [_ | _]}, _record)
       when is_binary(active), do: "waiting"

  defp projected_status(_run, %{active_run: active}, _record) when is_binary(active),
    do: "running"

  defp projected_status(_run, _info, %{status: status}) when status != :running,
    do: terminal_status(status)

  defp projected_status(%{status: status}, _info, _record) when status in @terminal, do: status
  defp projected_status(_run, _info, _record), do: "interrupted"

  defp summary(_run, %{answer: answer}) when is_binary(answer), do: Snapshot.text(answer)
  defp summary(run, _record), do: run.summary

  defp checkpoint_and_stop(run, session, state) do
    case checkpoint_and_stop_result(run, session, state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp checkpoint_and_stop_result(run, session, state) do
    with {:ok, run} <- Store.get(run.id),
         :ok <- OhMyJido.checkpoint(session),
         run = ingest_buffer(run, session),
         {:ok, lease} <- WriterLease.lookup(run),
         pid when is_pid(pid) <- live_pid(session),
         {:ok, _settled} <- Writers.stop(run, lease, pid) do
      {:ok, state |> detach(session.id) |> forget_writer(run.id)}
    else
      {:error, reason, _current} -> checkpoint_stop_failed(run, reason, state)
      {:error, reason} -> checkpoint_stop_failed(run, reason, state)
      _unconfirmed -> checkpoint_stop_failed(run, :native_stop_unconfirmed, state)
    end
  end

  defp checkpoint_stop_failed(run, reason, state) do
    state = %{state | writer_pending?: true, recovery: MapSet.put(state.recovery, run.id)}
    {:error, reason, state}
  end

  defp detach(state, id) do
    case Map.pop(state.sessions, id) do
      {nil, _sessions} ->
        state

      {entry, sessions} ->
        Process.demonitor(entry.monitor, [:flush])
        %{state | sessions: sessions}
    end
  end

  defp acquire_writer(run, state) do
    case Writers.acquire(run) do
      {:ok, run, lease} ->
        {:ok, run, track_writer(run.id, lease, state)}

      {:error, reason, run} ->
        state =
          if run.source_writer_pending or not is_nil(run.source_writer_token),
            do: %{state | writer_pending?: true, recovery: MapSet.put(state.recovery, run.id)},
            else: state

        {:error, reason, state}
    end
  end

  defp release_unstarted(run, reason, state) do
    with {:ok, lease} <- WriterLease.lookup(run),
         {:ok, _settled} <- Writers.abandon_unbound(run, lease, reason) do
      forget_writer(state, run.id)
    else
      _unconfirmed ->
        %{state | writer_pending?: true, recovery: MapSet.put(state.recovery, run.id)}
    end
  end

  defp track_writer(id, lease, state) do
    case Map.get(state.writers, id) do
      %{pid: pid, token: token} when pid == lease.pid and token == lease.token ->
        state

      previous ->
        if previous, do: Process.demonitor(previous.monitor, [:flush])
        entry = %{pid: lease.pid, token: lease.token, monitor: Process.monitor(lease.pid)}
        %{state | writers: Map.put(state.writers, id, entry), writer_pending?: true}
    end
  end

  defp forget_writer(state, id) do
    {entry, writers} = Map.pop(state.writers, id)
    if entry, do: Process.demonitor(entry.monitor, [:flush])
    %{state | writers: writers, writer_pending?: Store.writer_runs() != []}
  end

  defp writer_down(id, reason, state) do
    state = %{state | writers: Map.delete(state.writers, id), writer_pending?: true}

    case Store.get(id) do
      {:ok, run} ->
        Writers.uncertain(run, {:writer_holder_down, reason})
        send(self(), :reconcile_now)
        %{state | recovery: MapSet.put(state.recovery, id)}

      {:error, :not_found} ->
        state
    end
  end

  defp recover_writer(run, state) do
    case Writers.recover(run) do
      {:ok, _settled} ->
        state = state |> detach(run.session_id) |> forget_writer(run.id)
        %{state | recovery: MapSet.delete(state.recovery, run.id)}

      {:error, _reason, current} ->
        state =
          case WriterLease.lookup(current) do
            {:ok, lease} -> track_writer(current.id, lease, state)
            {:error, _reason} -> state
          end

        %{state | writer_pending?: true, recovery: MapSet.put(state.recovery, run.id)}
    end
  end

  defp interrupted(id, state) do
    case Store.get(id) do
      {:ok, run} -> interrupted_run(run, state)
      {:error, :not_found} -> state
    end
  end

  defp interrupted_run(run, state) do
    cleanup? = run.status == "queued" and is_nil(run.workspace)
    record_interruption(run, cleanup?)

    recovery =
      if is_binary(run.workspace),
        do: MapSet.put(state.recovery, run.id),
        else: MapSet.delete(state.recovery, run.id)

    %{state | recovery: recovery, cleanup_pending?: state.cleanup_pending? or cleanup?}
  end

  defp record_interruption(run, cleanup?) do
    if run.status in Store.active_statuses() do
      status = if run.status == "suspending", do: "suspended", else: "interrupted"

      Store.append(run.id, "host_interrupted", %{replay: false}, %{
        status: status,
        pending_questions: %{},
        session_snapshot: nil,
        workspace_cleanup_pending: run.workspace_cleanup_pending or cleanup?,
        summary: "Native execution was interrupted; effects were not replayed."
      })
    end
  end

  defp reconcile(state) do
    state = drop_finished_orphans(state)

    if repository_available?() do
      state =
        if reconcile_idle?(state) and not state.boot?, do: state, else: reconcile_work(state)

      if state.database_unavailable?,
        do: Logger.info("Docs editor database ownership recovered; reconciling without replay")

      %{state | database_unavailable?: false}
    else
      database_unavailable(state, :repository_unavailable)
    end
  rescue
    error in [DBConnection.OwnershipError, DBConnection.ConnectionError, Exqlite.Error] ->
      database_unavailable(state, error.__struct__)
  end

  defp reconcile_idle?(state) do
    map_size(state.tasks) == 0 and map_size(state.orphans) == 0 and
      map_size(state.sessions) == 0 and map_size(state.writers) == 0 and
      MapSet.size(state.recovery) == 0 and not state.writer_pending? and
      not state.cleanup_pending?
  end

  defp repository_available? do
    case Repo.get_dynamic_repo() do
      pid when is_pid(pid) -> Process.alive?(pid)
      name when is_atom(name) -> is_pid(Process.whereis(name))
    end
  end

  defp database_unavailable(state, reason) do
    unless state.database_unavailable?,
      do:
        Logger.error(
          "Docs editor database unavailable; source ownership remains fenced: #{inspect(reason)}"
        )

    orphans =
      Enum.reduce(state.tasks, state.orphans, fn {monitor, task}, orphans ->
        Process.demonitor(monitor, [:flush])

        if Process.alive?(task.pid),
          do: Map.put(orphans, Process.monitor(task.pid), task.pid),
          else: orphans
      end)

    # Completion messages cannot be persisted while ownership is unavailable.
    # Keep only the physical creator cohort; recovery interrupts/cleans queued
    # allocations instead of replaying a lost request or starting another turn.
    %{state | tasks: %{}, orphans: orphans, database_unavailable?: true, boot?: true}
  end

  defp drop_finished_orphans(%{orphans: orphans} = state) when map_size(orphans) == 0,
    do: state

  defp drop_finished_orphans(state) do
    orphans =
      Map.filter(state.orphans, fn {monitor, pid} ->
        if Process.alive?(pid) do
          true
        else
          Process.demonitor(monitor, [:flush])
          false
        end
      end)

    %{state | orphans: orphans}
  end

  defp reconcile_work(state) do
    preparing = MapSet.new(state.tasks, fn {_ref, task} -> task.run_id end)

    {recovering, recovery} =
      Enum.reduce(state.recovery, {[], MapSet.new()}, fn id, {runs, known} ->
        case Store.get(id) do
          {:ok, run} -> {[run | runs], MapSet.put(known, id)}
          {:error, :not_found} -> {runs, known}
        end
      end)

    live =
      Enum.flat_map(live_sessions(), fn session ->
        case Store.by_session(session.id) do
          %Run{} = run -> [run]
          nil -> []
        end
      end)

    runs = Enum.uniq_by(Store.active_runs() ++ Store.writer_runs() ++ recovering ++ live, & &1.id)
    state = %{state | boot?: false, recovery: recovery}

    state =
      Enum.reduce(runs, state, fn run, state ->
        if MapSet.member?(preparing, run.id) or
             (run.status == "queued" and map_size(state.orphans) > 0) do
          state
        else
          reconcile_run(run, state)
        end
      end)

    cleanup = Store.cleanup_runs()
    state = %{state | cleanup_pending?: cleanup != []}
    Enum.reduce(cleanup, state, &start_discard/2)
  end

  defp reconcile_run(run, state) do
    if writer_recovery?(run) do
      recover_writer(run, state)
    else
      case ensure_session(run, state) do
        {:ok, session, state} -> sync(run, session, state)
        {:error, _reason, state} -> interrupted(run.id, state)
      end
    end
  end

  defp writer_recovery?(%{source_writer_origin: origin}) when not is_nil(origin), do: true

  defp writer_recovery?(run) do
    case WriterLease.lookup(run) do
      {:ok, lease} ->
        lease.phase != :held or is_nil(lease.native_pid) or lease.native_down or
          not Process.alive?(lease.native_pid)

      {:error, _reason} ->
        run.source_writer_pending or not is_nil(run.source_writer_token)
    end
  end

  defp live_pid(session) do
    GenServer.whereis(Runtime.via(session))
  rescue
    ArgumentError -> nil
  end

  defp live_sessions do
    OhMyJido.list_sessions(@runtime)
  rescue
    ArgumentError -> []
  end

  defp register_secret(session, pid, state) do
    case Map.get(state.sessions, session.id) do
      %{pid: ^pid} -> :ok
      _new_session -> Host.register_secrets(session)
    end
  end

  defp capacity do
    with {:ok, config} <- Runtime.config(@runtime) do
      if Store.active_count() < min(Keyword.get(config, :max_active, 2), 2),
        do: :ok,
        else: {:error, :editor_capacity}
    end
  end

  defp fail(run, kind, reason) do
    Store.append(run.id, Atom.to_string(kind), %{reason: reason, replay: false}, %{
      status: "failed",
      pending_questions: %{},
      summary: "The native editor could not complete this request; inspect its durable events."
    })
  end

  defp terminal_status(status) do
    status = if is_atom(status), do: Atom.to_string(status), else: status
    if status in @terminal, do: status, else: "failed"
  end

  defp resume_run(run, state) do
    case ensure_session(run, state) do
      {:ok, session, state} -> resume_session(run, session, state)
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp resume_session(run, session, state) do
    with {:ok, info} <- OhMyJido.inspect_session(session),
         true <- is_nil(info.active_run),
         :ok <- resume_native(session, info.status),
         {:ok, state} <- checkpoint_and_stop_result(run, session, state) do
      # Publish readiness only after the exact native owner has strongly stopped.
      Store.append(run.id, "run_resumed", %{replay: false}, %{
        status: "ready",
        pending_questions: %{},
        session_snapshot: Snapshot.session(info)
      })

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :not_suspended}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp resume_native(session, :suspended), do: OhMyJido.resume(session)
  defp resume_native(_session, :idle), do: :ok
  defp resume_native(_session, _status), do: {:error, :not_suspended}

  defp valid_answer?(value) do
    with true <- json_answer?(value, 0),
         {:ok, encoded} <- Jason.encode(value) do
      byte_size(encoded) <= 16_384
    else
      _invalid -> false
    end
  end

  defp json_answer?(_value, depth) when depth > 6, do: false

  defp json_answer?(value, _depth) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= 16_384

  defp json_answer?(value, _depth) when is_boolean(value) or is_number(value) or is_nil(value),
    do: true

  defp json_answer?(value, depth) when is_list(value),
    do: Enum.count_until(value, 33) <= 32 and Enum.all?(value, &json_answer?(&1, depth + 1))

  defp json_answer?(value, depth) when is_map(value) and not is_struct(value) do
    map_size(value) <= 32 and
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and json_answer?(key, depth + 1) and json_answer?(item, depth + 1)
      end)
  end

  defp json_answer?(_value, _depth), do: false
end
