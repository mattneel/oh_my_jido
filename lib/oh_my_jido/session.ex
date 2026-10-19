defmodule OhMyJido.Session do
  @moduledoc false

  use GenServer

  require Logger

  alias OhMyJido.{
    CodingAgent,
    Context,
    ContextPolicy,
    Event,
    Host,
    Models,
    Persistence,
    Redact,
    Runtime,
    StreamMask
  }

  @terminal_events [:request_completed, :request_failed, :request_cancelled]
  @durable_keys [
    :version,
    :ref,
    :options,
    :selection,
    :status,
    :seq,
    :runs,
    :effects,
    :conversation,
    :agent_checkpoint,
    :goal,
    :plan,
    :children
  ]

  @doc false
  def start_link(opts) do
    ref = Keyword.fetch!(opts, :ref)
    GenServer.start_link(__MODULE__, opts, name: Runtime.via(ref))
  end

  @doc false
  def call(session, request, timeout \\ 30_000) do
    server = if is_pid(session), do: session, else: Runtime.via(session)
    GenServer.call(server, request, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :session_unavailable}
  end

  @doc false
  def effect_started(coordinator, run_id, call),
    do: call(coordinator, {:effect_started, run_id, call})

  @doc false
  def effect_finished(coordinator, run_id, id, result),
    do: call(coordinator, {:effect_finished, run_id, id, result})

  @doc false
  @spec effect_receipt(pid() | OhMyJido.SessionRef.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def effect_receipt(coordinator, id), do: call(coordinator, {:effect_receipt, id})

  @doc false
  def register_secrets(coordinator, secrets), do: call(coordinator, {:register_secrets, secrets})
  @doc false
  def redaction_secrets(coordinator), do: call(coordinator, :redaction_secrets)
  @doc false
  def redact_result(coordinator, result), do: call(coordinator, {:redact_result, result})
  @doc false
  def compact_context(coordinator, messages), do: call(coordinator, {:compact_context, messages})
  @doc false
  def question(coordinator, question), do: call(coordinator, {:question, question}, :infinity)

  @doc false
  def register_resource(coordinator, run_id, kind, handle),
    do: call(coordinator, {:register_resource, run_id, kind, handle})

  @doc false
  def unregister_resource(coordinator, key) do
    GenServer.cast(coordinator, {:unregister_resource, key})
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ref = Keyword.fetch!(opts, :ref)
    config = Keyword.fetch!(opts, :config)
    options = Keyword.fetch!(opts, :options)
    {adapter, storage_opts} = Jido.Storage.normalize_storage(config[:storage])

    with {:ok, state} <- initial_state(ref, config, options, adapter, storage_opts),
         {:ok, state} <- start_agent(state) do
      state = state |> recover_interrupted() |> persist!()
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:prompt, query, opts}, _from, state) do
    with :ok <- prompt_allowed(state, query),
         :ok <- request_options_allowed(state, opts),
         {:ok, selected} <- select_model(state, opts),
         {:ok, tools} <- request_tools(state, opts),
         goal = state.goal || query,
         {:ok, policy} <- ContextPolicy.retain(state.context_policy, %{goal: goal}),
         {:ok, lease} <- Runtime.reserve(state.ref.runtime, :model, self()) do
      run_id = Jido.Util.generate_id()

      context = %{
        state.context
        | run_id: run_id,
          model: selected.model,
          role: selected.role,
          account: selected.account,
          tools: tools
      }

      task = %{goal: goal, plan: state.plan, run_id: run_id}
      context = %{context | metadata: Map.put(context.metadata, :task_metadata, task)}

      record = %{
        id: run_id,
        status: :running,
        query: query,
        started_at: now(),
        usage: %{},
        tools: []
      }

      state = %{
        state
        | selection: selected,
          context: context,
          goal: goal,
          context_policy: policy,
          runs: Map.put(state.runs, run_id, record),
          status: :running
      }

      state =
        emit(
          state,
          :run_started,
          %{role: selected.role, model: Jido.AI.model_label(selected.model)},
          run_id
        )

      ask_opts =
        opts |> Keyword.take([:llm_opts, :req_http_options, :output, :file_references, :file_ids])

      ask_opts =
        Keyword.merge(ask_opts,
          request_id: run_id,
          stream_to: {:pid, self()},
          tools: tools,
          request_transformer:
            Keyword.get(state.config, :request_transformer, OhMyJido.Models.Transformer),
          tool_context: %{oh_my_jido: context},
          max_iterations:
            min(
              Keyword.get(opts, :max_iterations, state.config[:max_iterations]),
              state.config[:max_iterations]
            )
        )

      case CodingAgent.ask(state.agent_pid, query, ask_opts) do
        {:ok, handle} ->
          timer =
            Process.send_after(self(), {:run_deadline, run_id}, state.config[:run_timeout_ms])

          active = %{id: run_id, handle: handle, lease: lease, timer: timer, cancel_reason: nil}
          {:reply, {:ok, run_id}, %{state | active: active}}

        {:error, reason} ->
          Runtime.release(lease)

          state =
            finish_run(
              %{state | active: %{id: run_id, lease: nil, timer: nil}},
              :failed,
              nil,
              reason
            )

          {:reply, {:error, Redact.sanitize(reason, state.secrets)}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await, run_id, timeout}, from, state) do
    case Map.get(state.runs, run_id) do
      nil ->
        {:reply, {:error, :unknown_run}, state}

      %{status: :running} ->
        key = make_ref()
        timer = Process.send_after(self(), {:await_deadline, key}, timeout)
        monitor = Process.monitor(elem(from, 0))
        waiter = %{from: from, run: run_id, timer: timer, monitor: monitor}
        {:noreply, %{state | waiters: Map.put(state.waiters, key, waiter)}}

      record ->
        {:reply, run_reply(record), state}
    end
  end

  def handle_call({:subscribe, pid, opts}, _from, state) when is_pid(pid) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      subscriber = %{
        monitor: Process.monitor(pid),
        limit: Keyword.get(opts, :max_pending, state.config[:subscriber_limit])
      }

      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, subscriber)}}
    end
  end

  def handle_call({:events, after_seq}, _from, state) do
    events = state.events |> :queue.to_list() |> Enum.filter(&(&1.seq > after_seq))
    {:reply, events, state}
  end

  def handle_call({:flush_process_output, ref}, _from, state) do
    state =
      flush_streams(state, fn
        {{:process, ^ref, _stream}, _buffer} -> true
        _buffer -> false
      end)

    {:reply, :ok, state}
  end

  def handle_call(:redaction_secrets, _from, state), do: {:reply, {:ok, state.secrets}, state}

  def handle_call({:redact_result, result}, _from, state),
    do: {:reply, {:ok, clean_result(result, state.secrets)}, state}

  def handle_call({:effect_receipt, id}, _from, state) do
    case Map.fetch(state.effects, id) do
      {:ok, record} ->
        receipt =
          record
          |> Map.take([:id, :run, :name, :status, :arguments_hash, :started_at, :completed_at])
          |> Persistence.clean(state.secrets)

        {:reply, {:ok, receipt}, state}

      :error ->
        {:reply, {:error, :effect_not_recorded}, state}
    end
  end

  def handle_call(:inspect, _from, state) do
    snapshot = %{
      id: state.ref.id,
      status: state.status,
      active_run: if(state.active, do: state.active.id),
      agent_pid: state.agent_pid,
      workspace: state.context.workspace,
      permissions: state.context.permissions |> MapSet.to_list() |> Enum.sort(),
      role: state.selection.role,
      account: state.selection.account,
      model: state.selection.model,
      conversation: state.conversation,
      goal: state.goal,
      plan: state.plan,
      retained: ContextPolicy.checkpoint(state.context_policy),
      effects: state.effects,
      runs: state.runs,
      children: state.children,
      pending_questions: Map.keys(state.questions),
      seq: state.seq
    }

    snapshot =
      snapshot |> Persistence.clean_session(state.secrets) |> Map.put(:agent_pid, state.agent_pid)

    {:reply, {:ok, snapshot}, state}
  end

  def handle_call(:context, _from, state), do: {:reply, {:ok, state.context}, state}

  def handle_call({:steer, run_id, text}, _from, %{active: %{id: run_id}} = state) do
    constraints = Enum.uniq(state.context_policy.retained.constraints ++ [text])

    with {:ok, policy} <- ContextPolicy.retain(state.context_policy, %{constraints: constraints}),
         {:ok, _agent} <- CodingAgent.steer(state.agent_pid, text, expected_request_id: run_id) do
      state = %{state | context_policy: policy}
      {:reply, :ok, emit(state, :steering_queued, %{text: text}, run_id)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:steer, _run_id, _text}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call({:cancel, run_id, reason}, _from, %{active: %{id: run_id}} = state) do
    :ok = CodingAgent.cancel(state.agent_pid, request_id: run_id, reason: reason)
    Process.send_after(self(), {:force_cancel, run_id}, state.config[:tool_timeout_ms] + 1_000)
    active = Map.put(state.active, :cancel_reason, reason)

    state =
      %{state | active: active}
      |> deny_questions(:cancelled)
      |> emit(:cancellation_requested, %{reason: reason}, run_id)

    cancel_resources(state, run_id)
    {:reply, :ok, state}
  end

  def handle_call({:cancel, _run_id, _reason}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call(:resume, _from, %{status: :suspended} = state) do
    {:reply, :ok, emit(%{state | status: :idle}, :session_resumed, %{replay: false})}
  end

  def handle_call(:resume, _from, state), do: {:reply, {:error, :not_suspended}, state}

  def handle_call(:checkpoint, _from, %{active: nil} = state) do
    case Persistence.agent_checkpoint(state.agent_pid, state.secrets) do
      {:ok, checkpoint} ->
        {:reply, :ok,
         emit(%{state | agent_checkpoint: checkpoint}, :checkpoint_saved, %{safe: true})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:checkpoint, _from, state), do: {:reply, {:error, :run_active}, state}

  def handle_call(:prepare_stop, _from, state) do
    if state.active,
      do:
        CodingAgent.cancel(state.agent_pid, request_id: state.active.id, reason: :session_stopped)

    cancel_resources(state, :all)

    state =
      if state.active, do: finish_run(state, :interrupted, nil, :session_stopped), else: state

    eval =
      Map.get_lazy(state.context.metadata, :eval, fn -> Runtime.eval(state.ref.runtime) end)

    if is_pid(eval), do: OhMyJido.Eval.close_session(eval, state.ref.id)

    {:reply, :ok, %{state | status: :stopped} |> deny_questions(:session_stopped) |> persist!()}
  end

  def handle_call({:register_secrets, secrets}, _from, state) when is_list(secrets) do
    values =
      Enum.filter(secrets, &(is_binary(&1) and byte_size(&1) > 0))
      |> Enum.concat(state.secrets)
      |> Enum.uniq()

    if length(values) <= state.config[:max_secrets] and
         Enum.all?(values, &(byte_size(&1) <= 16_384)) do
      {pattern, width} = StreamMask.compile(values)
      {:reply, :ok, %{state | secrets: values, secret_pattern: pattern, secret_width: width}}
    else
      {:reply, {:error, :redaction_capacity}, state}
    end
  end

  def handle_call({:compact_context, messages}, _from, state) do
    messages = Persistence.clean(messages, state.secrets)

    case ContextPolicy.compact(state.context_policy, messages) do
      {:ok, projection} ->
        boundary = Enum.count(messages, &(Map.get(&1, :role) not in [:system, "system"]))

        state = %{
          state
          | context_policy: projection.state,
            conversation: projection.messages,
            context_boundary: boundary
        }

        state =
          if projection.compacted,
            do: emit(state, :context_compacted, %{removed_messages: projection.removed_messages}),
            else: persist!(state)

        {:reply, {:ok, projection}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:retain, facts}, _from, state) do
    case ContextPolicy.retain(state.context_policy, facts) do
      {:ok, policy} ->
        goal = OhMyJido.Config.get(facts, :goal, state.goal)
        {:reply, :ok, %{state | context_policy: policy, goal: goal} |> persist!()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:plan, plan}, _from, state) do
    case OhMyJido.Plan.update(state.plan, plan) do
      {:ok, plan} -> {:reply, :ok, emit(%{state | plan: plan}, :plan_updated, %{plan: plan})}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:goal_complete, evidence}, _from, state) do
    with {:ok, verified} <- verification_evidence(state, evidence),
         :ok <- OhMyJido.Plan.complete(state.plan, verified) do
      {:reply, :ok, emit(state, :goal_completed, %{goal: state.goal, evidence: verified})}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_tool, action}, _from, %{active: nil} = state) do
    case Jido.AI.register_tool(state.agent_pid, action) do
      {:ok, _agent} ->
        tools = Enum.uniq([action | state.context.tools])

        state = %{
          state
          | context: %{state.context | tools: tools},
            options: Keyword.put(state.options, :tools, tools)
        }

        {:reply, :ok, emit(state, :tool_registered, %{name: action.name()})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_tool, name}, _from, %{active: nil} = state) do
    case Jido.AI.unregister_tool(state.agent_pid, name) do
      {:ok, _agent} ->
        tools = Enum.reject(state.context.tools, &(&1.name() == name))

        state = %{
          state
          | context: %{state.context | tools: tools},
            options: Keyword.put(state.options, :tools, tools)
        }

        {:reply, :ok, emit(state, :tool_unregistered, %{name: name})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_tool, _action}, _from, state),
    do: {:reply, {:error, :run_active}, state}

  def handle_call({:unregister_tool, _name}, _from, state),
    do: {:reply, {:error, :run_active}, state}

  def handle_call({:emit, kind, payload}, _from, state),
    do: {:reply, :ok, emit(state, kind, payload)}

  def handle_call({:register_resource, run_id, kind, handle}, _from, state) do
    with :ok <- effect_allowed(state, run_id),
         true <- map_size(state.resources) < state.config[:max_resources],
         {:ok, pid} <- resource_pid(kind, handle) do
      key = make_ref()

      resource = %{
        id: key,
        run: run_id,
        kind: kind,
        handle: handle,
        monitor: Process.monitor(pid)
      }

      {:reply, {:ok, key}, %{state | resources: Map.put(state.resources, key, resource)}}
    else
      false -> {:reply, {:error, :resource_capacity}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:effect_started, run_id, tool_call}, _from, state) do
    with :ok <- effect_allowed(state, run_id),
         :ok <- effect_capacity(state),
         false <- Map.has_key?(state.effects, tool_call.id) do
      record = %{
        id: tool_call.id,
        run: run_id,
        name: tool_call.name,
        status: :running,
        arguments_hash:
          :crypto.hash(:sha256, :erlang.term_to_binary(tool_call.arguments))
          |> Base.encode16(case: :lower),
        started_at: now()
      }

      state = %{state | effects: Map.put(state.effects, tool_call.id, record)} |> persist!()
      {:reply, :ok, state}
    else
      true -> {:reply, {:error, :effect_already_recorded}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:effect_finished, run_id, id, result}, _from, state) do
    case Map.get(state.effects, id) do
      %{run: ^run_id, status: :running} = record ->
        record =
          Map.merge(record, %{
            status: effect_status(result),
            result: Redact.sanitize(result, state.secrets, 16_384),
            completed_at: now()
          })

        state = %{state | effects: Map.put(state.effects, id, record)} |> persist!()
        {:reply, :ok, state}

      _record ->
        {:reply, {:error, :effect_not_active}, state}
    end
  end

  def handle_call({:question, question}, from, state) do
    if map_size(state.questions) >= state.config[:max_pending_questions] do
      {:reply, {:error, :question_capacity}, state}
    else
      id = Jido.Util.generate_id()

      timer =
        Process.send_after(self(), {:question_deadline, id}, state.config[:question_timeout_ms])

      waiter = %{from: from, timer: timer, question: question}
      state = %{state | questions: Map.put(state.questions, id, waiter)}
      state = emit(state, :approval_requested, %{id: id, question: question}, active_id(state))
      invoke_question_host(state.context, question, id)
      {:noreply, state}
    end
  end

  def handle_call({:answer, id, answer}, _from, state) do
    case resolve_question(state, id, {:ok, answer}) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:child_started, tag, ref, run_id}, _from, state) do
    case Map.get(state.children, tag) do
      %{session: ^ref, status: :starting} = child ->
        children = Map.put(state.children, tag, %{child | run: run_id, status: :running})

        {:reply, :ok,
         emit(%{state | children: children}, :subagent_started, %{
           tag: tag,
           child_session: ref.id,
           child_run: run_id
         })}

      _child ->
        {:reply, {:error, :child_identity_mismatch}, state}
    end
  end

  def handle_call({:adopt, agent, tag, ref, lease}, _from, state) do
    if Map.has_key?(state.child_leases, tag) do
      {:reply, {:error, {:tag_in_use, tag}}, state}
    else
      case Jido.AgentServer.adopt_child(state.agent_pid, agent, tag) do
        {:ok, _pid} ->
          child = %{session: ref, run: nil, status: :starting}

          {:reply, :ok,
           %{
             state
             | children: Map.put(state.children, tag, child),
               child_leases: Map.put(state.child_leases, tag, lease)
           }}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:child_start_failed, tag, ref}, _from, state) do
    state =
      case Map.get(state.children, tag) do
        %{session: ^ref} ->
          %{
            state
            | children: Map.delete(state.children, tag),
              child_leases: Map.delete(state.child_leases, tag)
          }

        _child ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:child_result, tag, ref, run_id, result}, _from, state) do
    case Map.get(state.children, tag) do
      %{session: ^ref, run: ^run_id, status: :running} = child ->
        Runtime.release(Map.get(state.child_leases, tag))

        child =
          Map.merge(child, %{
            status: :completed,
            result: Redact.sanitize(result, state.secrets, 32_768)
          })

        state = %{
          state
          | children: Map.put(state.children, tag, child),
            child_leases: Map.delete(state.child_leases, tag)
        }

        {:reply, :ok, emit(state, :subagent_completed, %{tag: tag, result: child.result})}

      _child ->
        {:reply, {:error, :stale_child_result}, state}
    end
  end

  @impl true
  def handle_info({:jido_ai_request_event, event}, state) do
    if state.active && event.request_id == state.active.id do
      state = project_runtime_event(state, event)
      state = if event.kind in @terminal_events, do: collect_terminal(state, event), else: state
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:run_deadline, id}, %{active: %{id: id}} = state) do
    CodingAgent.cancel(state.agent_pid, request_id: id, reason: :deadline)
    Process.send_after(self(), {:force_cancel, id}, 1_000)
    cancel_resources(state, id)
    {:noreply, %{state | active: Map.put(state.active, :cancel_reason, :deadline)}}
  end

  def handle_info({:force_cancel, id}, %{active: %{id: id}} = state) do
    Jido.stop_agent(Runtime.engine(state.ref.runtime), state.agent_pid)
    {:noreply, state}
  end

  def handle_info({:settle_cancel, id, event, result, deadline}, %{active: %{id: id}} = state) do
    ready =
      case Jido.AgentServer.status(state.agent_pid) do
        {:ok, %{snapshot: %{done?: true}}} -> true
        _status -> false
      end

    cond do
      ready ->
        {:noreply, finalize_terminal(state, event, result)}

      System.monotonic_time(:millisecond) >= deadline ->
        Jido.stop_agent(Runtime.engine(state.ref.runtime), state.agent_pid)
        {:noreply, state}

      true ->
        Process.send_after(self(), {:settle_cancel, id, event, result, deadline}, 20)
        {:noreply, state}
    end
  end

  def handle_info({:await_deadline, key}, state) do
    case Map.pop(state.waiters, key) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:question_deadline, id}, state) do
    {:noreply, question_result(state, id, {:error, :approval_timeout})}
  end

  def handle_info({:host_answer, _id, :pending}, state), do: {:noreply, state}

  def handle_info({:host_answer, id, result}, state),
    do: {:noreply, question_result(state, id, result)}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{agent_monitor: monitor} = state) do
    if state.active, do: cancel_resources(state, state.active.id)
    state = if state.active, do: finish_interrupted(state, reason), else: state

    state =
      %{state | agent_pid: nil, agent_monitor: nil}
      |> emit(:worker_failed, %{reason: safe_reason(reason), replay: false})

    case start_agent(state) do
      {:ok, state} -> {:noreply, emit(state, :worker_recovered, %{replay: false})}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        %{monitor: ^monitor} -> Map.delete(state.subscribers, pid)
        _subscriber -> state.subscribers
      end

    waiters =
      Enum.reduce(state.waiters, state.waiters, fn {key, waiter}, acc ->
        if waiter.monitor == monitor do
          Process.cancel_timer(waiter.timer)
          Map.delete(acc, key)
        else
          acc
        end
      end)

    {finished, retained} =
      Enum.split_with(state.resources, fn {_key, resource} -> resource.monitor == monitor end)

    state =
      Enum.reduce(finished, state, fn {_key, resource}, acc ->
        flush_resource_streams(acc, resource)
      end)

    {:noreply,
     %{state | subscribers: subscribers, waiters: waiters, resources: Map.new(retained)}}
  end

  def handle_info({:eval_output, session_id, execution_id, stream, text}, state)
      when is_binary(text) do
    active_resource =
      Enum.any?(state.resources, fn {_key, resource} ->
        resource.kind == :eval and resource.run == active_id(state) and
          resource.handle.session_id == session_id and
          resource.handle.execution_id == execution_id
      end)

    if session_id == state.ref.id and active_resource do
      key = {:eval, execution_id, stream}
      payload = %{execution_id: execution_id, stream: stream}
      {:noreply, stream_output(state, key, :tool_output, payload, text, :text, active_id(state))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:process_output, session_id, run_id, ref, stream, text}, state)
      when is_binary(text) do
    registered =
      Enum.any?(state.resources, fn {_key, resource} ->
        resource.kind == :process and resource.run == run_id and resource.handle.ref == ref
      end)

    permitted =
      session_id == state.ref.id and registered and (is_nil(run_id) or run_id == active_id(state))

    if permitted do
      key = {:process, ref, stream}
      {:noreply, stream_output(state, key, :tool_output, %{stream: stream}, text, :text, run_id)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:resource_cleanup, resource, result}, state) do
    payload = %{
      kind: resource.kind,
      outcome: Redact.sanitize(result, state.secrets),
      confirmed: cleanup_confirmed?(result)
    }

    {:noreply, emit(state, :resource_cleanup, payload, resource.run)}
  end

  def handle_info(_message, state), do: {:noreply, state}
  @impl true
  def handle_cast({:unregister_resource, key}, state) do
    case Map.pop(state.resources, key) do
      {nil, _resources} ->
        {:noreply, state}

      {resource, resources} ->
        Process.demonitor(resource.monitor, [:flush])
        state = flush_resource_streams(state, resource)
        {:noreply, %{state | resources: resources}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.resources, fn {_key, resource} -> cancel_resource(resource) end)

    if state.agent_pid && Process.alive?(state.agent_pid),
      do: Jido.stop_agent(Runtime.engine(state.ref.runtime), state.agent_pid)

    if state.active, do: Runtime.release(state.active.lease)
    Enum.each(state.child_leases, fn {_tag, lease} -> Runtime.release(lease) end)

    Enum.each(state.children, fn {_tag, child} ->
      case GenServer.whereis(Runtime.via(child.session)) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Runtime.sessions(child.session.runtime), pid)

        nil ->
          :ok
      end
    end)

    if eval = Map.get(state.context.metadata, :eval),
      do: OhMyJido.Eval.close_session(eval, state.ref.id)

    OhMyJido.Extensions.close_session(state.context)
    OhMyJido.Tools.Skill.clear(state.context)
    :ok
  end

  @impl true
  def format_status(status) do
    state = Map.get(status, :state, %{})
    ref = Map.get(state, :ref, %{})
    summary = %{session_id: Map.get(ref, :id), status: state[:status], seq: state[:seq]}

    status
    |> Map.put(:state, summary)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defoverridable handle_call: 3, handle_cast: 2, handle_info: 2, terminate: 2

  @impl GenServer
  def handle_call(message, from, state) do
    super(message, from, state)
  catch
    kind, _reason -> callback_failed(:call, kind, state)
  end

  @impl GenServer
  def handle_cast(message, state) do
    super(message, state)
  catch
    kind, _reason -> callback_failed(:async, kind, state)
  end

  @impl GenServer
  def handle_info(message, state) do
    super(message, state)
  catch
    kind, _reason -> callback_failed(:async, kind, state)
  end

  @impl GenServer
  def terminate(reason, state) do
    super(reason, state)
  catch
    kind, _reason -> callback_failed(:terminate, kind, state)
  end

  defp callback_failed(type, kind, state) do
    Logger.error("Coding coordinator callback failed",
      session_id: state.ref.id,
      callback: type,
      failure_kind: kind
    )

    case type do
      :call -> {:stop, {:shutdown, :coordinator_failed}, {:error, :coordinator_failed}, state}
      :async -> {:stop, {:shutdown, :coordinator_failed}, state}
      :terminate -> :ok
    end
  end

  defp initial_state(ref, config, options, adapter, storage_opts) do
    saved = Keyword.get(options, :restore)

    saved =
      if saved,
        do: {:ok, saved},
        else: adapter.get_checkpoint({ref.runtime, ref.id}, storage_opts)

    case saved do
      {:ok, %{version: 1} = saved} -> restore_state(saved, ref, config, adapter, storage_opts)
      :not_found -> new_state(ref, config, options, adapter, storage_opts)
      {:ok, _saved} -> {:error, :unsupported_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp new_state(ref, config, options, adapter, storage_opts) do
    options =
      Keyword.put_new(options, :tools, Keyword.get(config, :tools, OhMyJido.Tools.default()))

    with {:ok, selection} <- Models.select(options, config),
         {:ok, policy} <- ContextPolicy.new(config[:context_policy]) do
      state = %{
        version: 1,
        ref: ref,
        config: config,
        options: durable_options(options),
        selection: selection,
        status: :idle,
        seq: 0,
        events: :queue.new(),
        runs: %{},
        effects: %{},
        conversation: [],
        agent_checkpoint: nil,
        goal: Keyword.get(options, :goal),
        plan: [],
        children: %{},
        context_policy: policy,
        adapter: adapter,
        storage_opts: storage_opts
      }

      transient_state(state, options)
    end
  end

  defp restore_state(saved, ref, config, adapter, storage_opts) do
    with {:ok, root} <- OhMyJido.Workspace.new(Keyword.get(saved.options, :workspace)),
         {:ok, policy} <- ContextPolicy.restore(saved.context_policy) do
      options = Keyword.put(saved.options, :workspace, root)

      state =
        saved
        |> Map.put(:events, :queue.from_list(saved.events))
        |> Map.merge(%{
          ref: ref,
          config: config,
          options: options,
          context_policy: policy,
          adapter: adapter,
          storage_opts: storage_opts
        })

      transient_state(state, options)
    end
  end

  defp transient_state(state, options) do
    metadata =
      Keyword.get(state.config, :metadata, %{}) |> Map.merge(Keyword.get(options, :metadata, %{}))

    metadata = Map.put(metadata, :runtime_config, state.config)

    options = [
      session_id: state.ref.id,
      runtime: state.ref.runtime,
      coordinator: self(),
      workspace: Keyword.fetch!(options, :workspace),
      permissions: Keyword.get(options, :permissions, []),
      role: state.selection.role,
      model: state.selection.model,
      account: state.selection.account,
      host: normalize_host(Keyword.get(options, :host, state.config[:host])),
      tools:
        Keyword.get(options, :tools, Keyword.get(state.config, :tools, OhMyJido.Tools.default())),
      adapters:
        Map.merge(Keyword.get(state.config, :adapters, %{}), Keyword.get(options, :adapters, %{})),
      limits: numeric_limits(state.config),
      metadata: metadata
    ]

    with {:ok, context} <- Context.new(options) do
      {:ok,
       Map.merge(state, %{
         context: context,
         agent_pid: nil,
         agent_monitor: nil,
         active: nil,
         context_boundary: nil,
         secrets: [],
         secret_pattern: nil,
         secret_width: 0,
         stream_buffers: %{},
         subscribers: %{},
         waiters: %{},
         questions: %{},
         child_leases: %{},
         resources: %{}
       })}
    end
  end

  defp start_agent(state) do
    agent_state = %{
      context: Jido.AI.Context.new() |> Jido.AI.Context.append_messages(state.conversation)
    }

    agent =
      case state.agent_checkpoint do
        nil ->
          CodingAgent.new(id: state.ref.id, state: agent_state)

        checkpoint ->
          {:ok, restored} = CodingAgent.restore(checkpoint, %{})
          %{restored | state: Map.merge(restored.state, agent_state)}
      end

    opts = [
      agent: agent,
      agent_module: CodingAgent,
      id: state.ref.id,
      jido: Runtime.engine(state.ref.runtime)
    ]

    spec = Supervisor.child_spec({Jido.AgentServer, opts}, restart: :temporary)

    case DynamicSupervisor.start_child(
           Jido.agent_supervisor_name(Runtime.engine(state.ref.runtime)),
           spec
         ) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, %{state | agent_pid: pid, agent_monitor: Process.monitor(pid)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_model(state, opts) do
    opts = Keyword.put_new(opts, :session_selection, state.selection)
    Models.select(opts, state.config)
  end

  defp request_tools(state, opts) do
    tools = Keyword.get(opts, :tools, state.context.tools)

    if is_list(tools) and Enum.all?(tools, &(&1 in state.context.tools)) do
      {:ok, tools}
    else
      {:error, :tool_escalation}
    end
  end

  defp prompt_allowed(%{active: active}, _query) when not is_nil(active), do: {:error, :busy}
  defp prompt_allowed(%{status: :suspended}, _query), do: {:error, :suspended}

  defp prompt_allowed(_state, query) when is_binary(query) and byte_size(query) in 1..65_536,
    do: :ok

  defp prompt_allowed(_state, _query), do: {:error, :invalid_prompt}

  defp effect_allowed(%{status: status}, _run) when status in [:suspended, :stopped],
    do: {:error, :session_stopped}

  defp effect_allowed(_state, nil), do: :ok
  defp effect_allowed(%{active: %{id: id, cancel_reason: nil}}, id), do: :ok
  defp effect_allowed(_state, _run), do: {:error, :run_not_active}

  defp collect_terminal(%{active: %{settling_cancel: true}} = state, _event), do: state

  defp collect_terminal(state, event) do
    result = CodingAgent.await(state.active.handle, timeout: 5_000)

    if event.kind == :request_cancelled or not is_nil(state.active.cancel_reason) do
      deadline = System.monotonic_time(:millisecond) + 1_000
      send(self(), {:settle_cancel, state.active.id, event, result, deadline})
      %{state | active: Map.put(state.active, :settling_cancel, true)}
    else
      finalize_terminal(state, event, result)
    end
  end

  defp finalize_terminal(state, event, result) do
    case commit_terminal_context(state) do
      {:ok, state} ->
        checkpoint =
          case Persistence.agent_checkpoint(state.agent_pid, state.secrets) do
            {:ok, checkpoint} -> checkpoint
            {:error, _reason} -> state.agent_checkpoint
          end

        state = %{state | agent_checkpoint: checkpoint}

        case result do
          {:ok, answer} when event.kind == :request_completed ->
            finish_run(state, :completed, answer, nil)

          {:error, reason} ->
            finish_run(state, terminal_status(state, event.kind), nil, reason)

          _result ->
            finish_run(state, terminal_status(state, event.kind), nil, event.data[:reason])
        end

      {:error, reason} ->
        finish_run(state, :failed, nil, {:context_commit_failed, reason})
    end
  end

  defp terminal_status(%{active: %{cancel_reason: :suspended}}, _kind), do: :suspended
  defp terminal_status(%{active: %{cancel_reason: :deadline}}, _kind), do: :timed_out
  defp terminal_status(_state, :request_cancelled), do: :cancelled
  defp terminal_status(_state, _kind), do: :failed

  defp finish_interrupted(state, reason) do
    status =
      case state.active.cancel_reason do
        :suspended -> :suspended
        :deadline -> :timed_out
        nil -> :interrupted
        _reason -> :cancelled
      end

    finish_run(state, status, nil, safe_reason(reason))
  end

  defp finish_run(state, status, answer, error) do
    id = state.active.id
    Runtime.release(state.active.lease)
    state = flush_streams(state, fn {_key, stream} -> stream.run == id end)
    if state.active.timer, do: Process.cancel_timer(state.active.timer)
    record = Map.fetch!(state.runs, id)

    record =
      Map.merge(record, %{
        status: status,
        answer: Redact.sanitize(answer, state.secrets, 120_000),
        error: Redact.sanitize(error, state.secrets),
        completed_at: now()
      })

    effects =
      Enum.into(state.effects, %{}, fn
        {key, %{run: ^id, status: :running} = effect} ->
          {key, Map.put(effect, :status, :uncertain)}

        pair ->
          pair
      end)

    tools =
      effects
      |> Map.values()
      |> Enum.filter(&(&1.run == id))
      |> Enum.sort_by(&{&1.started_at, &1.id})
      |> Enum.map(&Map.take(&1, [:id, :name, :status, :started_at, :completed_at]))

    record = %{record | tools: tools}

    session_status = if status == :suspended, do: :suspended, else: :idle

    state = %{
      state
      | active: nil,
        status: session_status,
        runs: Map.put(state.runs, id, record),
        effects: effects,
        context_boundary: nil,
        context: %{state.context | run_id: nil}
    }

    state =
      state
      |> deny_questions(:run_finished)
      |> emit(:run_completed, %{status: status, usage: record.usage}, id)

    reply_waiters(state, id, run_reply(record))
  end

  defp recover_interrupted(state) do
    runs =
      Map.new(state.runs, fn
        {id, %{status: :running} = run} ->
          {id,
           Map.merge(run, %{status: :interrupted, error: :worker_restarted, completed_at: now()})}

        pair ->
          pair
      end)

    effects =
      Map.new(state.effects, fn
        {id, %{status: :running} = effect} -> {id, Map.put(effect, :status, :uncertain)}
        pair -> pair
      end)

    status = if state.status == :suspended, do: :suspended, else: :idle
    %{state | runs: runs, effects: effects, status: status}
  end

  defp run_reply(%{status: :completed} = record), do: {:ok, record}
  defp run_reply(record), do: {:error, record}

  defp reply_waiters(state, id, result) do
    waiters =
      Enum.reduce(state.waiters, state.waiters, fn {key, waiter}, acc ->
        if waiter.run == id do
          Process.cancel_timer(waiter.timer)
          Process.demonitor(waiter.monitor, [:flush])
          GenServer.reply(waiter.from, result)
          Map.delete(acc, key)
        else
          acc
        end
      end)

    %{state | waiters: waiters}
  end

  defp emit(state, kind, payload, run_id \\ nil) do
    event = %Event{
      session_id: state.ref.id,
      run_id: run_id || active_id(state),
      seq: state.seq + 1,
      kind: kind,
      at_ms: now(),
      payload: Redact.sanitize(payload, state.secrets)
    }

    events = :queue.in(event, state.events)

    events =
      if :queue.len(events) > state.config[:event_limit],
        do: elem(:queue.out(events), 1),
        else: events

    state =
      %{state | seq: event.seq, events: events}
      |> update_usage(kind, payload, event.run_id)
      |> persist!()

    subscribers =
      Enum.reduce(state.subscribers, state.subscribers, fn {pid, subscriber}, acc ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, length} when length < subscriber.limit ->
            send(pid, {:oh_my_jido, event})
            acc

          _unavailable ->
            Process.demonitor(subscriber.monitor, [:flush])
            Map.delete(acc, pid)
        end
      end)

    :telemetry.execute([:oh_my_jido, :event], %{seq: event.seq, at_ms: event.at_ms}, %{
      session_id: state.ref.id,
      kind: kind
    })

    %{state | subscribers: subscribers}
  end

  defp update_usage(state, :llm_completed, %{usage: usage}, id) when is_map(usage) do
    if Map.has_key?(state.runs, id),
      do: update_in(state, [:runs, id, :usage], &Jido.AI.Usage.merge(&1, usage)),
      else: state
  end

  defp update_usage(state, _kind, _payload, _id), do: state

  defp event_payload(event) do
    event.data
    |> Map.take([
      :usage,
      :reason,
      :status,
      :termination_reason,
      :retry_after,
      :text,
      :delta,
      :chunk_type,
      :error_code,
      :code
    ])
    |> Map.merge(%{
      tool_name: event.tool_name,
      tool_call_id: event.tool_call_id,
      iteration: event.iteration
    })
  end

  defp persist!(state) do
    saved =
      Map.take(state, @durable_keys)
      |> Map.put(:events, :queue.to_list(state.events))
      |> Map.put(:context_policy, ContextPolicy.checkpoint(state.context_policy))
      |> Persistence.clean_session(state.secrets)

    case state.adapter.put_checkpoint(
           {state.ref.runtime, state.ref.id},
           saved,
           state.storage_opts
         ) do
      :ok -> state
      {:error, reason} -> exit({:storage_failed, safe_reason(reason)})
    end
  end

  defp durable_options(options) do
    metadata =
      Keyword.get(options, :metadata, %{})
      |> Map.take([
        :git_repository_root,
        :git_worktree_roots,
        :delegation_roots,
        :delegation_depth,
        :project_instructions,
        :skills,
        :skill_roots
      ])

    options
    |> Keyword.take([:workspace, :permissions, :role, :account, :model, :goal, :tools])
    |> Keyword.put(:metadata, metadata)
  end

  defp normalize_host({module, opts}), do: {module, opts}
  defp normalize_host(module) when is_atom(module), do: {module, []}
  defp active_id(%{active: nil}), do: nil
  defp active_id(%{active: active}), do: active.id
  defp now, do: System.system_time(:millisecond)
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :worker_failure

  defp numeric_limits(config) do
    defaults =
      config
      |> Enum.filter(fn {key, value} ->
        is_integer(value) and not Redact.credential_field?(key)
      end)
      |> Map.new()

    explicit = Keyword.get(config, :limits, %{})

    if is_map(explicit) and Enum.all?(explicit, fn {_key, value} -> is_integer(value) end) do
      Map.merge(defaults, explicit)
    else
      raise ArgumentError, "tool limits must contain only integer resource budgets"
    end
  end

  defp resource_pid(:process, %{pid: pid}) when is_pid(pid), do: {:ok, pid}

  defp resource_pid(:eval, %{controller: pid, execution_id: id})
       when is_pid(pid) and is_binary(id),
       do: {:ok, pid}

  defp resource_pid(_kind, _handle), do: {:error, :invalid_resource}

  defp cancel_resources(state, run) do
    coordinator = self()

    Enum.each(state.resources, fn {_key, resource} ->
      if run == :all or resource.run == run do
        cancel_resource_async(state.ref.runtime, coordinator, resource)
      end
    end)
  end

  defp cancel_resource_async(runtime, coordinator, resource) do
    Task.Supervisor.start_child(Jido.task_supervisor_name(Runtime.engine(runtime)), fn ->
      result = cancel_resource(resource)
      send(coordinator, {:resource_cleanup, resource, result})
    end)
  end

  defp cancel_resource(%{kind: :process, handle: handle}), do: OhMyJido.Process.cancel(handle)

  defp cancel_resource(%{kind: :eval, handle: handle}),
    do:
      OhMyJido.Eval.interrupt(
        handle.runtime,
        handle.session_id,
        handle.language,
        handle.execution_id
      )

  defp cleanup_confirmed?({:ok, %{cleanup: :confirmed}}), do: true
  defp cleanup_confirmed?(_result), do: false

  defp request_options_allowed(state, opts) do
    cond do
      Models.credential_options?(opts) -> {:error, :credentials_must_come_from_host}
      map_size(state.runs) >= state.config[:max_runs] -> {:error, {:capacity, :run_history}}
      true -> :ok
    end
  end

  defp effect_capacity(state) do
    if map_size(state.effects) < state.config[:max_effects],
      do: :ok,
      else: {:error, {:capacity, :effect_history}}
  end

  defp clean_result({status, payload, effects}, secrets) when status in [:ok, :error],
    do: {status, Persistence.clean(payload, secrets), effects}

  defp clean_result({status, payload}, secrets) when status in [:ok, :error],
    do: {status, Persistence.clean(payload, secrets)}

  defp clean_result(result, secrets), do: Persistence.clean(result, secrets)

  defp project_runtime_event(state, %{kind: :llm_delta, data: %{delta: delta}} = event)
       when is_binary(delta) do
    key = {:llm, event.llm_call_id, Map.get(event.data, :chunk_type)}

    stream_output(
      state,
      key,
      :llm_delta,
      Map.delete(event_payload(event), :delta),
      delta,
      :delta,
      event.request_id
    )
  end

  defp project_runtime_event(state, %{kind: :llm_completed} = event) do
    state =
      flush_streams(state, fn
        {{:llm, call_id, _type}, _stream} -> call_id == event.llm_call_id
        _stream -> false
      end)

    emit(state, event.kind, event_payload(event), event.request_id)
  end

  defp project_runtime_event(state, event),
    do: emit(state, event.kind, event_payload(event), event.request_id)

  defp stream_output(state, key, kind, payload, bytes, field, run) do
    pending =
      case Map.get(state.stream_buffers, key) do
        nil -> ""
        stream -> stream.pending
      end

    {safe, pending} = StreamMask.push(pending, bytes, state.secret_pattern, state.secret_width)
    stream = %{pending: pending, kind: kind, payload: payload, field: field, run: run}
    state = %{state | stream_buffers: Map.put(state.stream_buffers, key, stream)}
    if safe == "", do: state, else: emit(state, kind, Map.put(payload, field, safe), run)
  end

  defp flush_streams(state, predicate) do
    {flush, keep} = Enum.split_with(state.stream_buffers, predicate)
    state = %{state | stream_buffers: Map.new(keep)}

    Enum.reduce(flush, state, fn {_key, stream}, acc ->
      safe = StreamMask.finish(stream.pending, state.secret_pattern, state.secrets)

      if safe == "",
        do: acc,
        else: emit(acc, stream.kind, Map.put(stream.payload, stream.field, safe), stream.run)
    end)
  end

  defp flush_resource_streams(state, %{kind: :process, handle: %{ref: ref}}) do
    flush_streams(state, fn
      {{:process, ^ref, _stream}, _buffer} -> true
      _buffer -> false
    end)
  end

  defp flush_resource_streams(state, %{kind: :eval, handle: %{execution_id: id}}) do
    flush_streams(state, fn
      {{:eval, ^id, _stream}, _buffer} -> true
      _buffer -> false
    end)
  end

  defp verification_evidence(state, %{effect_ids: ids}) when is_list(ids) and ids != [] do
    ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, checks} ->
      case verification_check(Map.get(state.effects, id), id) do
        {:ok, check} -> {:cont, {:ok, [check | checks]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, %{checks: Enum.reverse(checks)}}
      {:error, _reason} = error -> error
    end
  end

  defp verification_evidence(_state, _evidence), do: {:error, :verification_required}

  defp verification_check(%{status: :completed, name: "shell", result: result}, id) do
    case successful_process_result(result) do
      {:ok, process} ->
        {:ok,
         %{
           effect_id: id,
           status: :verified,
           exit_status: 0,
           duration_ms: process[:duration_ms]
         }}

      :error ->
        {:error, :verification_failed}
    end
  end

  defp verification_check(_effect, _id), do: {:error, :unverified_effect}

  defp effect_status({:error, %Jido.Action.Error.TimeoutError{}}), do: :uncertain

  defp effect_status({:error, %Jido.Action.Error.TimeoutError{}, _effects}), do: :uncertain

  defp effect_status({:error, %Jido.Action.Error.ExecutionFailureError{details: details}}),
    do: effect_status({:error, details})

  defp effect_status(
         {:error, %Jido.Action.Error.ExecutionFailureError{details: details}, effects}
       ),
       do: effect_status({:error, details, effects})

  defp effect_status({tag, %{effect: :uncertain}, _effects}) when tag in [:ok, :error],
    do: :uncertain

  defp effect_status({tag, %{effect: :uncertain}}) when tag in [:ok, :error], do: :uncertain

  defp effect_status({tag, %{effects: :uncertain}, _effects}) when tag in [:ok, :error],
    do: :uncertain

  defp effect_status({tag, %{effects: :uncertain}}) when tag in [:ok, :error], do: :uncertain
  defp effect_status(_result), do: :completed

  defp successful_process_result({:ok, result, _effects}),
    do: successful_process_result({:ok, result})

  defp successful_process_result(
         {:ok, %{exit_status: 0, status: :exited, effect: :completed} = result}
       ),
       do: {:ok, result}

  defp successful_process_result(_result), do: :error

  defp commit_terminal_context(state) do
    case Jido.AgentServer.status(state.agent_pid) do
      {:ok, %{snapshot: %{done?: true, details: %{conversation: messages}}}} ->
        messages = Persistence.clean(messages, state.secrets)

        messages =
          case state.context_boundary do
            nil ->
              messages

            boundary ->
              appended =
                messages
                |> Enum.reject(&(Map.get(&1, :role) in [:system, "system"]))
                |> Enum.drop(boundary)

              state.conversation ++ appended
          end

        with {:ok, _agent} <- replace_context(state, messages),
             do: {:ok, %{state | conversation: messages}}

      {:error, _reason} = error ->
        error

      _status ->
        {:error, :terminal_context_unavailable}
    end
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp replace_context(state, messages) do
    context = Jido.AI.Context.new() |> Jido.AI.Context.append_messages(messages)

    signal =
      Jido.Signal.new!(
        "ai.react.context.modify",
        %{
          op_id: Jido.Util.generate_id(),
          operation: %{type: :replace, reason: :compaction, result_context: context}
        },
        source: "/oh-my-jido/context"
      )

    Jido.AgentServer.call(state.agent_pid, signal)
  end

  defp invoke_question_host(context, question, id) do
    coordinator = self()

    Task.Supervisor.start_child(Jido.task_supervisor_name(Runtime.engine(context.runtime)), fn ->
      result =
        try do
          Host.call(context, :question, [question])
        rescue
          _error -> {:error, :approval_host_failed}
        catch
          _kind, _reason -> {:error, :approval_host_failed}
        end

      send(coordinator, {:host_answer, id, result})
    end)
  end

  defp resolve_question(state, id, result) do
    case Map.pop(state.questions, id) do
      {nil, _questions} ->
        {:error, :unknown_question}

      {waiter, questions} ->
        Process.cancel_timer(waiter.timer)
        GenServer.reply(waiter.from, result)

        {:ok,
         emit(%{state | questions: questions}, :approval_answered, %{id: id, answer: result})}
    end
  end

  defp question_result(state, id, result) do
    case resolve_question(state, id, result) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp deny_questions(state, reason) do
    Enum.each(state.questions, fn {_id, waiter} ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, reason})
    end)

    %{state | questions: %{}}
  end
end
