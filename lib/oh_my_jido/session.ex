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
    NativeScopes,
    Persistence,
    Redact,
    Runtime,
    StreamMask
  }

  @terminal_events [:request_completed, :request_failed, :request_cancelled]
  @stop_timeout_ms 5_000
  @cleanup_task_timeout_ms 8_000
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
  def effect_started(coordinator, run_id, call, ancestry),
    do: call(coordinator, {:effect_started, run_id, call, ancestry})

  @doc false
  def native_effect_started(coordinator, run_id, call, binding),
    do: call(coordinator, {:native_effect_started, run_id, call, binding})

  @doc false
  def native_execution_started(coordinator, run_id, id, binding, proof),
    do: call(coordinator, {:native_execution_started, run_id, id, binding, proof})

  @doc false
  def native_execution_stopped(coordinator, id, token, proof),
    do: call(coordinator, {:native_execution_stopped, id, token, proof})

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
  def unregister_resource(coordinator, key, result) do
    GenServer.cast(coordinator, {:unregister_resource, key, result})
    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ref = Keyword.fetch!(opts, :ref)
    config = Keyword.fetch!(opts, :config)
    options = Keyword.fetch!(opts, :options)

    with {:ok, {adapter, storage_opts}} <- Jido.Persistence.Store.open(config[:storage]),
         {:ok, state} <- initial_state(ref, config, options, adapter, storage_opts),
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
          %{role: selected.role, model: Jido.AI.Models.label(selected.model)},
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
          context: %{oh_my_jido: context},
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
      native_execution: NativeScopes.stats(state.native_scope_parents),
      seq: state.seq
    }

    snapshot =
      snapshot |> Persistence.clean_session(state.secrets) |> Map.put(:agent_pid, state.agent_pid)

    {:reply, {:ok, snapshot}, state}
  end

  def handle_call(:context, _from, %{status: status} = state)
      when status in [:stopping, :cleanup_uncertain, :stopped],
      do: {:reply, {:error, :session_stopped}, state}

  def handle_call(:context, _from, state), do: {:reply, {:ok, state.context}, state}

  def handle_call({:steer, _run_id, _text}, _from, %{stop: stop} = state)
      when not is_nil(stop),
      do: {:reply, {:error, :session_stopped}, state}

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

  def handle_call({:cancel, _run_id, _reason}, _from, %{stop: stop} = state)
      when not is_nil(stop),
      do: {:reply, {:error, :session_stopped}, state}

  def handle_call({:cancel, run_id, reason}, _from, %{active: %{id: run_id}} = state) do
    :ok = CodingAgent.cancel(state.agent_pid, request_id: run_id, reason: reason)
    Process.send_after(self(), {:force_cancel, run_id}, state.config[:tool_timeout_ms] + 1_000)
    active = Map.put(state.active, :cancel_reason, reason)

    state =
      %{state | active: active}
      |> deny_questions(:cancelled)
      |> emit(:cancellation_requested, %{reason: reason}, run_id)

    {:reply, :ok, cancel_resources(state, run_id)}
  end

  def handle_call({:cancel, _run_id, _reason}, _from, state),
    do: {:reply, {:error, :run_not_active}, state}

  def handle_call(:resume, _from, %{status: status} = state)
      when status in [:stopping, :cleanup_uncertain, :stopped],
      do: {:reply, {:error, :session_stopped}, state}

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

  def handle_call({:reconcile_interrupted, run_id, expected_effect_ids}, _from, state) do
    with true <- reconciliation_idle?(state),
         {:ok, ids} <- reconciliation_effects(state, run_id, expected_effect_ids) do
      settlement = %{
        source: :operator,
        execution: :stopped,
        effect: :uncertain,
        native_stop_confirmed: false,
        at_ms: now()
      }

      effects =
        Enum.reduce(ids, state.effects, fn id, effects ->
          Map.update!(effects, id, &Map.put(&1, :execution_settlement, settlement))
        end)

      state = %{
        state
        | effects: effects,
          restored_effects: Map.delete(state.restored_effects, run_id)
      }

      payload = %{effects: ids, source: :operator, native_stop_confirmed: false}
      {:reply, :ok, emit(state, :interrupted_execution_reconciled, payload, run_id)}
    else
      false -> {:reply, {:error, :execution_not_quiescent}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:prepare_stop, _from, %{stop: %{result: :ok}} = state),
    do: {:reply, :ok, state}

  def handle_call(:prepare_stop, _from, %{stop: %{result: {:error, _reason}}} = state) do
    state = state |> start_native_stop(false) |> stop_children() |> settle_stop()
    {:reply, {:error, stop_uncertainty(state)}, state}
  end

  def handle_call(:prepare_stop, from, %{stop: stop} = state) when not is_nil(stop) do
    {:noreply, put_in(state.stop.waiters, [from | stop.waiters])}
  end

  def handle_call(:prepare_stop, _from, %{status: :cleanup_uncertain} = state) do
    {:reply,
     {:error,
      %{
        reason: :cleanup_uncertain,
        cleanup: :uncertain,
        pending_effects: pending_effects(state),
        pending_resources: [:unreconciled],
        native: :pending
      }}, state}
  end

  def handle_call(:prepare_stop, from, state) do
    id = make_ref()
    timer = Process.send_after(self(), {:stop_deadline, id}, @stop_timeout_ms)

    stop = %{
      id: id,
      timer: timer,
      deadline: System.monotonic_time(:millisecond) + @stop_timeout_ms,
      waiters: [from],
      result: nil,
      native: if(state.active, do: :pending, else: :confirmed),
      native_run: active_id(state),
      actor: if(is_pid(state.agent_pid), do: :pending, else: :confirmed),
      actor_pid: state.agent_pid,
      children: MapSet.new(Map.keys(state.children)),
      services: :waiting
    }

    active =
      if state.active do
        if state.active.timer, do: Process.cancel_timer(state.active.timer)
        Map.put(state.active, :cancel_reason, :session_stopped)
      end

    state =
      %{state | stop: stop, status: :stopping, active: active}
      |> deny_questions(:session_stopped)
      |> persist!()
      |> cancel_resources(:all)
      |> start_native_stop(true)
      |> stop_children()
      |> settle_stop()

    {:noreply, state}
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

    with {:ok, projection} <- ContextPolicy.compact(state.context_policy, messages),
         {:ok, native} <- agent_conversation(state.agent_pid) do
      # The host projection can add retained-effect summaries which are not
      # native Thread entries. Anchor the suffix to the actor's committed
      # transcript, not the composed model input.
      boundary = Enum.count(native, &(Map.get(&1, :role) not in [:system, "system"]))

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
    else
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

  def handle_call({operation, _value}, _from, %{stop: stop} = state)
      when operation in [:register_tool, :unregister_tool, :question] and not is_nil(stop),
      do: {:reply, {:error, :session_stopped}, state}

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
    case record_effect(state, run_id, tool_call) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:effect_started, run_id, tool_call, ancestry}, {caller, _tag}, state) do
    with {:ok, origin} <- inherited_native_origin(state, run_id, ancestry, caller),
         {:ok, state} <- record_effect(state, run_id, tool_call) do
      state = if origin, do: put_in(state.native_effects[tool_call.id], origin), else: state
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:native_effect_started, run_id, tool_call, binding}, _from, state) do
    with {:ok, origin} <- native_effect_origin(state, run_id, binding),
         {:ok, state} <- record_effect(state, run_id, tool_call) do
      {:reply, :ok,
       put_in(state.native_effects[tool_call.id], Map.put(origin, :effect, tool_call.id))}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:native_execution_started, run_id, id, binding, proof}, {caller, _tag}, state) do
    with {:ok, origin} <- registered_native_origin(state, run_id, id, binding),
         :ok <- valid_native_scope_start(caller, proof),
         token = make_ref(),
         {:ok, parents} <-
           NativeScopes.admit(state.native_scope_parents, token, id, origin, proof.parent) do
      scope = %{effect: id, origin: origin, proof: proof, monitor: Process.monitor(caller)}

      state = %{
        state
        | native_scopes: Map.put(state.native_scopes, token, scope),
          native_scope_parents: parents
      }

      result = native_scope_admission(state, id, origin, proof.parent, token)

      {:reply, result, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:native_execution_stopped, id, token, proof}, {caller, _tag}, state) do
    with {:ok, scope} <- Map.fetch(state.native_scopes, token),
         true <- scope.effect == id and scope.proof.controller == caller,
         true <- proof == Map.put(scope.proof, :workers_stopped, true),
         false <- Process.alive?(scope.proof.supervisor) do
      Process.demonitor(scope.monitor, [:flush])

      state = %{
        state
        | native_scopes: Map.delete(state.native_scopes, token),
          native_scope_parents: NativeScopes.close(state.native_scope_parents, token)
      }

      {:reply, :ok, state |> settle_native_effects() |> settle_stop()}
    else
      _unconfirmed -> {:reply, {:error, :native_execution_unconfirmed}, state}
    end
  end

  def handle_call({:effect_finished, run_id, id, result}, _from, state) do
    case Map.get(state.effects, id) do
      %{run: ^run_id, status: status} = record
      when status in [:running, :uncertain] and not is_map_key(record, :completed_at) and
             not is_map_key(record, :execution_settlement) ->
        record =
          Map.merge(record, %{
            status: effect_status(result),
            result: Redact.sanitize(result, state.secrets, 16_384),
            completed_at: now()
          })

        state = %{state | effects: Map.put(state.effects, id, record)} |> persist!()
        {:reply, :ok, settle_stop(state)}

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

  def handle_call({:adopt, _agent, _tag, _ref, _lease}, _from, %{stop: stop} = state)
      when not is_nil(stop),
      do: {:reply, {:error, :session_stopped}, state}

  def handle_call({:adopt, agent, tag, ref, lease}, _from, state) do
    if Map.has_key?(state.child_leases, tag) do
      {:reply, {:error, {:tag_in_use, tag}}, state}
    else
      case Jido.AgentServer.adopt_child(state.agent_pid, agent, tag) do
        :ok ->
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

      state =
        cond do
          not is_nil(state.stop) and event.kind in @terminal_events ->
            start_native_stop(state, false)

          event.kind in @terminal_events ->
            state |> start_native_retirement(event.request_id) |> collect_terminal(event)

          true ->
            state
        end

      {:noreply, settle_stop(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:run_deadline, _id}, %{stop: stop} = state) when not is_nil(stop),
    do: {:noreply, state}

  def handle_info({:force_cancel, _id}, %{stop: stop} = state) when not is_nil(stop),
    do: {:noreply, state}

  def handle_info({:settle_cancel, _id, _event, _result, _deadline}, %{stop: stop} = state)
      when not is_nil(stop),
      do: {:noreply, state}

  def handle_info({:stop_deadline, id}, %{stop: %{id: id, result: nil}} = state) do
    result = {:error, stop_uncertainty(state)}
    state = %{state | status: :cleanup_uncertain}
    state = emit(state, :session_cleanup_uncertain, elem(result, 1))
    {:noreply, reply_stop(state, result)}
  end

  def handle_info({:poll_stop_native, id}, %{stop: %{id: id, result: nil}} = state),
    do: {:noreply, start_native_stop(state, false)}

  def handle_info({ref, result}, %{cleanup_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {cleanup, tasks} = Map.pop(tasks, ref)
    Process.cancel_timer(cleanup.timer)
    Process.demonitor(ref, [:flush])
    state = %{state | cleanup_tasks: tasks}
    {:noreply, state |> complete_cleanup(cleanup.key, result) |> settle_stop()}
  end

  def handle_info({:cleanup_task_deadline, ref}, %{cleanup_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {cleanup, tasks} = Map.pop(tasks, ref)
    Process.exit(cleanup.task.pid, :kill)
    Process.demonitor(ref, [:flush])
    state = %{state | cleanup_tasks: tasks}
    {:noreply, state |> complete_cleanup(cleanup.key, {:error, :timeout}) |> settle_stop()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cleanup_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {cleanup, tasks} = Map.pop(tasks, ref)
    Process.cancel_timer(cleanup.timer)
    state = %{state | cleanup_tasks: tasks}

    {:noreply,
     state |> complete_cleanup(cleanup.key, {:error, :cleanup_worker_down}) |> settle_stop()}
  end

  def handle_info({:run_deadline, id}, %{active: %{id: id}} = state) do
    CodingAgent.cancel(state.agent_pid, request_id: id, reason: :deadline)
    Process.send_after(self(), {:force_cancel, id}, 1_000)
    state = %{state | active: Map.put(state.active, :cancel_reason, :deadline)}
    {:noreply, cancel_resources(state, id)}
  end

  def handle_info({:force_cancel, id}, %{active: %{id: id}} = state) do
    Jido.stop_agent(Runtime.engine(state.ref.runtime), state.agent_pid)
    {:noreply, state}
  end

  def handle_info({:settle_cancel, id, event, result, deadline}, %{active: %{id: id}} = state) do
    ready =
      case Jido.AI.Orchestration.snapshot(state.agent_pid, request_id: id) do
        {:ok, %{request: %{status: status}, live: nil}} when status != :pending -> true
        _snapshot -> false
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

  def handle_info(
        {:DOWN, monitor, :process, _guard, _reason},
        %{agent_guard_monitor: monitor} = state
      ) do
    if is_pid(state.agent_pid) and Process.alive?(state.agent_pid) do
      {:stop, {:shutdown, :native_owner_guard_failed}, state}
    else
      # The native Agent's own DOWN performs ordinary in-place recovery.
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{agent_monitor: monitor} = state) do
    state = if state.active, do: cancel_resources(state, state.active.id), else: state
    state = if state.active, do: finish_interrupted(state, reason), else: state

    state =
      %{state | agent_pid: nil, agent_monitor: nil}
      |> confirm_stopped_actor()
      |> emit(:worker_failed, %{reason: safe_reason(reason), replay: false})

    if state.stop do
      {:noreply, settle_stop(state)}
    else
      case start_agent(state) do
        {:ok, state} -> {:noreply, emit(state, :worker_recovered, %{replay: false})}
        {:error, reason} -> {:stop, reason, state}
      end
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

    resources =
      Map.new(state.resources, fn
        {key, %{monitor: ^monitor} = resource} ->
          {key, %{resource | monitor: nil} |> Map.put(:cleanup, :uncertain)}

        resource ->
          resource
      end)

    {:noreply, %{state | subscribers: subscribers, waiters: waiters, resources: resources}}
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

  def handle_info(_message, state), do: {:noreply, state}
  @impl true
  def handle_cast({:unregister_resource, key, result}, state) do
    case Map.get(state.resources, key) do
      nil ->
        {:noreply, state}

      resource ->
        {:noreply, state |> resource_cleanup(resource, result) |> settle_stop()}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.cleanup_tasks, fn {_ref, cleanup} ->
      Process.exit(cleanup.task.pid, :kill)
    end)

    Enum.each(state.resources, fn {_key, resource} -> cancel_resource(resource) end)

    if state.agent_pid && Process.alive?(state.agent_pid),
      do: Jido.stop_agent(Runtime.engine(state.ref.runtime), state.agent_pid)

    if state.active, do: Runtime.release(state.active.lease)
    Enum.each(state.child_leases, fn {_tag, lease} -> Runtime.release(lease) end)

    unless state.stop && state.stop.result == :ok do
      Enum.each(state.children, &terminate_child_session/1)

      if eval = Map.get(state.context.metadata, :eval),
        do: OhMyJido.Eval.close_session(eval, state.ref.id)

      OhMyJido.Extensions.close_session(state.context)
      OhMyJido.Tools.Skill.clear(state.context)
    end

    :ok
  end

  defp terminate_child_session({_tag, child}) do
    case GenServer.whereis(Runtime.via(child.session)) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Runtime.sessions(child.session.runtime), pid)

      nil ->
        :ok
    end
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
    case Persistence.read_session({adapter, storage_opts}, {ref.runtime, ref.id}) do
      {:ok, %{version: 1} = saved, condition} ->
        with {:ok, state} <- restore_state(saved, ref, config, adapter, storage_opts),
             do: {:ok, Map.put(state, :storage_condition, condition)}

      {:error, :not_found} ->
        with {:ok, state} <- new_state(ref, config, options, adapter, storage_opts),
             do: {:ok, Map.put(state, :storage_condition, :not_found)}

      {:ok, _saved, _condition} ->
        {:error, :unsupported_checkpoint}

      {:error, reason} ->
        {:error, reason}
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
      # The replacement Thread has no original request-settlement markers.
      # Retain real complete exchanges without stale pending visibility tags.
      conversation = Enum.map(saved.conversation, &clear_pending_context/1)

      state =
        saved
        |> Map.put(:events, :queue.from_list(saved.events))
        |> Map.put(:conversation, conversation)
        |> Map.merge(%{
          ref: ref,
          config: config,
          options: options,
          context_policy: policy,
          adapter: adapter,
          storage_opts: storage_opts
        })

      case transient_state(state, options) do
        {:ok, state} -> {:ok, Map.put(state, :restored_effects, restored_pending_effects(saved))}
        {:error, _reason} = error -> error
      end
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
         agent_guard_monitor: nil,
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
         resources: %{},
         cleanup_tasks: %{},
         native_effects: %{},
         native_scopes: %{},
         native_scope_parents:
           NativeScopes.new(
             state.config[:max_resources] + state.config[:max_effects],
             state.config[:max_resources]
           ),
         native_retired: MapSet.new(),
         restored_effects: %{},
         stop: nil
       })}
    end
  end

  defp start_agent(state) do
    conversation =
      Jido.AI.Thread.Projection.append_entries(
        Jido.Session.new(id: state.ref.id),
        state.conversation
      )

    with {:ok, agent} <- restore_agent(state, conversation),
         {:ok, agent} <- CodingAgent.configure(agent, state.context, state.config),
         {:ok, pid, guard_monitor} <- start_owned_agent(state.ref, agent) do
      {:ok,
       %{
         state
         | agent_pid: pid,
           agent_monitor: Process.monitor(pid),
           agent_guard_monitor: guard_monitor
       }}
    end
  end

  defp start_owned_agent(ref, agent) do
    owner = self()
    token = make_ref()
    engine = Runtime.engine(ref.runtime)

    with {:ok, guard} <-
           Task.Supervisor.start_child(Jido.task_supervisor_name(engine), fn ->
             own_native_agent(owner, token, ref, agent, engine)
           end) do
      monitor = Process.monitor(guard)

      receive do
        {^token, {:ok, pid}} ->
          {:ok, pid, monitor}

        {^token, {:error, _reason} = error} ->
          Process.demonitor(monitor, [:flush])
          error

        {:DOWN, ^monitor, :process, ^guard, _reason} ->
          {:error, :native_agent_start_failed}
      end
    end
  end

  defp own_native_agent(owner, token, ref, agent, engine) do
    Process.flag(:sensitive, true)
    owner_monitor = Process.monitor(owner)

    with :ok <- claim_native_owner(ref, owner, owner_monitor),
         :ok <- retire_native_agent(engine, ref.id),
         {:ok, pid} <-
           Jido.AgentServer.start(
             agent: agent,
             jido: engine,
             restore: false,
             restart: :temporary
           ) do
      native_monitor = Process.monitor(pid)
      send(owner, {token, {:ok, pid}})

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          stop_native_agent(pid)

        {:DOWN, ^native_monitor, :process, ^pid, _reason} ->
          :ok
      end
    else
      {:error, reason} ->
        send(owner, {token, {:error, Jido.AgentServer.PrivateDiagnostics.error(reason)}})
    end
  catch
    _kind, _reason ->
      send(owner, {token, {:error, :native_agent_start_failed}})
  end

  defp claim_native_owner(ref, owner, owner_monitor) do
    # Serialize replacement against the preceding guard's exact-PID shutdown,
    # including owner death while native supervised startup is still blocked.
    if Process.alive?(owner) do
      case Registry.register(
             Runtime.registry(ref.runtime),
             {__MODULE__, :native_owner, ref.id},
             nil
           ) do
        {:ok, _registry} ->
          :ok

        {:error, {:already_registered, previous}} ->
          monitor = Process.monitor(previous)

          receive do
            {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
              Process.demonitor(monitor, [:flush])
              {:error, :session_owner_stopped}

            {:DOWN, ^monitor, :process, ^previous, _reason} ->
              claim_native_owner(ref, owner, owner_monitor)
          end
      end
    else
      {:error, :session_owner_stopped}
    end
  end

  defp retire_native_agent(engine, id) do
    case Jido.whereis_agent(engine, id) do
      nil ->
        :ok

      pid ->
        stop_native_agent(pid)
    end
  end

  defp stop_native_agent(pid) do
    # Await the native termination path before releasing the ownership claim.
    # A caller timeout must not let a replacement race unfinished teardown.
    Jido.AgentServer.stop(pid, :shutdown, :infinity)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _details} -> :ok
  end

  defp restore_agent(%{agent_checkpoint: nil} = state, conversation),
    do: CodingAgent.new(id: state.ref.id, state: %{conversation: conversation})

  defp restore_agent(state, conversation) do
    with {:ok, agent} <- Jido.Agent.restore(CodingAgent, state.agent_checkpoint, %{}) do
      Jido.Agent.set(agent, %{conversation: conversation})
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

  defp prompt_allowed(%{status: status}, _query)
       when status in [:stopping, :cleanup_uncertain, :stopped],
       do: {:error, :session_stopped}

  defp prompt_allowed(%{active: active}, _query) when not is_nil(active), do: {:error, :busy}
  defp prompt_allowed(%{status: :suspended}, _query), do: {:error, :suspended}

  defp prompt_allowed(_state, query) when is_binary(query) and byte_size(query) in 1..65_536,
    do: :ok

  defp prompt_allowed(_state, _query), do: {:error, :invalid_prompt}

  defp effect_allowed(%{status: status}, _run)
       when status in [:suspended, :stopping, :cleanup_uncertain, :stopped],
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

    session_status =
      cond do
        not is_nil(state.stop) -> state.status
        status == :suspended -> :suspended
        true -> :idle
      end

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

  defp restored_pending_effects(saved) do
    saved.effects
    |> Enum.filter(fn
      {_id, %{status: status, run: run} = effect} when status in [:running, :uncertain] ->
        pending_effect?(effect) and interrupted_record?(Map.get(saved.runs, run))

      _malformed_or_settled ->
        false
    end)
    |> Enum.group_by(fn {_id, effect} -> effect.run end, fn {id, _effect} -> id end)
    |> Map.new(fn {run_id, ids} -> {run_id, Enum.sort(ids)} end)
  end

  defp interrupted_record?(%{status: status}), do: status in [:running, :interrupted]
  defp interrupted_record?(_record), do: false

  defp reconciliation_idle?(state) do
    reconciliation_owner_idle?(state) and reconciliation_resources_idle?(state)
  end

  defp reconciliation_owner_idle?(state) do
    is_nil(state.active) and is_nil(state.stop) and state.status in [:idle, :suspended] and
      map_size(state.questions) == 0
  end

  defp reconciliation_resources_idle?(state) do
    map_size(state.resources) == 0 and map_size(state.child_leases) == 0 and
      map_size(state.cleanup_tasks) == 0 and map_size(state.native_scopes) == 0
  end

  defp reconciliation_effects(state, run_id, expected) when is_list(expected) do
    with %{status: :interrupted} <- Map.get(state.runs, run_id),
         {:ok, original} <- Map.fetch(state.restored_effects, run_id),
         ids = Enum.filter(original, &pending_effect?(Map.get(state.effects, &1))),
         true <- reconciliation_ids_match?(expected, ids, state.config[:max_effects]) do
      {:ok, ids}
    else
      _mismatch -> {:error, :reconciliation_mismatch}
    end
  end

  defp reconciliation_effects(_state, _run_id, _expected),
    do: {:error, :reconciliation_mismatch}

  defp reconciliation_ids_match?(expected, ids, limit) do
    ids != [] and Enum.count_until(expected, limit + 1) <= limit and Enum.sort(expected) == ids
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

    status =
      case state.status do
        :suspended -> :suspended
        status when status in [:stopping, :cleanup_uncertain] -> :cleanup_uncertain
        _status -> :idle
      end

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

    case Persistence.write_session(
           {state.adapter, state.storage_opts},
           {state.ref.runtime, state.ref.id},
           saved,
           state.storage_condition
         ) do
      {:ok, condition} -> %{state | storage_condition: condition}
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
    Enum.reduce(state.resources, state, fn {key, resource}, acc ->
      if run == :all or resource.run == run do
        start_resource_cleanup(acc, key, resource)
      else
        acc
      end
    end)
  end

  defp start_resource_cleanup(state, key, resource) do
    state = put_in(state.resources[key], Map.put(resource, :cleanup, :pending))

    start_cleanup_task(state, {:resource, key, resource.kind}, fn ->
      {resource, cancel_resource(resource)}
    end)
  end

  defp start_cleanup_task(state, key, fun) do
    if cleanup_task?(state, key) do
      state
    else
      task =
        Task.Supervisor.async_nolink(
          Jido.task_supervisor_name(Runtime.engine(state.ref.runtime)),
          fn -> run_cleanup_task(fun) end
        )

      timer =
        Process.send_after(self(), {:cleanup_task_deadline, task.ref}, @cleanup_task_timeout_ms)

      cleanup = %{key: key, task: task, timer: timer}
      %{state | cleanup_tasks: Map.put(state.cleanup_tasks, task.ref, cleanup)}
    end
  rescue
    _error -> state
  catch
    :exit, _reason -> state
  end

  defp run_cleanup_task(fun) do
    Process.flag(:sensitive, true)
    fun.()
  catch
    _kind, _reason -> {:error, :cleanup_worker_failed}
  end

  defp cleanup_task?(state, key),
    do: Enum.any?(state.cleanup_tasks, fn {_ref, cleanup} -> cleanup.key == key end)

  defp start_native_stop(%{stop: %{native: :pending}, agent_pid: pid} = state, cancel?)
       when is_pid(pid) do
    run_id = state.stop.native_run

    start_cleanup_task(state, :native, fn ->
      if cancel?, do: CodingAgent.cancel(pid, request_id: run_id, reason: :session_stopped)

      native_request_settled(pid, run_id)
    end)
  end

  defp start_native_stop(state, _cancel?), do: state

  defp native_request_settled(pid, id) do
    with {:ok, %{request: %{id: ^id, run_id: native_run, status: status}}}
         when status in [:completed, :failed] <-
           Jido.AI.Orchestration.snapshot(pid, request_id: id),
         %{pid: coordinator} <-
           Jido.AgentServer.children(pid)[{:plugin, Jido.AI.Orchestration.Plugin}],
         nil <- GenServer.call(coordinator, {:inspect, id, native_run}) do
      {:ok, %{agent: pid, coordinator: coordinator, request: id, run: native_run}}
    else
      _unconfirmed -> {:error, :native_not_idle}
    end
  end

  # A public host call may borrow the active run ID. Only the native interceptor
  # registers this provenance, against the actual Coordinator job and binding.
  defp native_effect_origin(state, run_id, %Jido.AI.Orchestration.ExecutionBinding{} = binding) do
    with true <- binding.agent_server == state.agent_pid and binding.request_id == run_id,
         %{pid: coordinator} <-
           Jido.AgentServer.children(state.agent_pid)[{:plugin, Jido.AI.Orchestration.Plugin}],
         true <- coordinator == binding.coordinator,
         %{request_id: ^run_id, run_id: native_run, worker_pid: controller}
         when is_pid(controller) <-
           GenServer.call(coordinator, {:inspect, run_id, binding.run_id}),
         true <- native_run == binding.run_id do
      {:ok,
       %{
         agent: state.agent_pid,
         coordinator: coordinator,
         request: run_id,
         run: native_run,
         controller: controller
       }}
    else
      _unconfirmed -> {:error, :native_execution_unconfirmed}
    end
  catch
    _kind, _reason -> {:error, :native_execution_unconfirmed}
  end

  defp native_effect_origin(_state, _run_id, _binding),
    do: {:error, :invalid_execution_binding}

  defp registered_native_origin(
         state,
         run_id,
         id,
         %Jido.AI.Orchestration.ExecutionBinding{} = binding
       ) do
    case Map.get(state.native_effects, id) do
      %{agent: agent, coordinator: coordinator, request: ^run_id, run: native_run} = origin ->
        if binding.agent_server == agent and binding.coordinator == coordinator and
             binding.request_id == run_id and binding.run_id == native_run,
           do: {:ok, origin},
           else: {:error, :native_execution_unconfirmed}

      _origin ->
        {:error, :native_effect_unregistered}
    end
  end

  defp registered_native_origin(_state, _run_id, _id, _binding),
    do: {:error, :invalid_execution_binding}

  defp valid_native_scope_start(
         caller,
         %{
           controller: caller,
           supervisor: supervisor,
           owner: owner,
           execution_id: _execution_id,
           parent: _parent
         }
       )
       when is_pid(supervisor) and is_pid(owner),
       do: :ok

  defp valid_native_scope_start(_caller, _proof),
    do: {:error, :native_execution_unconfirmed}

  defp native_scope_admission(state, id, origin, parent, token) do
    cond do
      state.stop ->
        {:halt, token, :session_stopped}

      origin.agent != state.agent_pid ->
        {:halt, token, :native_agent_replaced}

      effect_allowed(state, origin.request) != :ok ->
        {:halt, token, :native_request_not_active}

      MapSet.member?(state.native_retired, native_origin_key(origin)) ->
        {:halt, token, :native_request_retired}

      is_nil(parent) and not pending_effect?(Map.get(state.effects, id)) ->
        {:halt, token, :effect_not_active}

      true ->
        {:ok, token}
    end
  end

  defp inherited_native_origin(
         state,
         run_id,
         %{scope: token, controller: controller},
         caller
       )
       when is_reference(token) and is_pid(controller) do
    case Map.get(state.native_scopes, token) do
      %{origin: origin, proof: %{controller: ^controller}} ->
        native_caller_origin(state, run_id, origin, caller, controller)

      nil ->
        unregistered_native_origin(state, token, caller)

      _unconfirmed ->
        {:error, :native_execution_unconfirmed}
    end
  end

  defp inherited_native_origin(_state, _run_id, _ancestry, _caller),
    do: {:error, :native_execution_unconfirmed}

  defp native_caller_origin(state, run_id, origin, caller, controller) do
    with true <- origin.agent == state.agent_pid and origin.request == run_id,
         {:links, links} <- Process.info(caller, :links),
         true <- controller in links,
         false <- MapSet.member?(state.native_retired, native_origin_key(origin)),
         :ok <- effect_allowed(state, run_id) do
      {:ok, origin}
    else
      _unconfirmed -> {:error, :native_execution_unconfirmed}
    end
  end

  defp unregistered_native_origin(state, token, caller) do
    if Process.alive?(caller) and NativeScopes.fetch(state.native_scope_parents, token) == :error,
      do: {:ok, nil},
      else: {:error, :native_execution_unconfirmed}
  end

  defp native_origin_key(origin),
    do: {origin.agent, origin.coordinator, origin.request, origin.run}

  defp start_native_retirement(state, request_id) do
    origin =
      Enum.find_value(state.native_effects, fn {_id, origin} ->
        if origin.request == request_id, do: origin
      end)

    if origin do
      key = native_origin_key(origin)

      start_cleanup_task(state, {:native_retirement, key}, fn ->
        confirm_native_retirement(origin, request_id, key)
      end)
    else
      state
    end
  end

  defp confirm_native_retirement(origin, request_id, key) do
    with {:ok, proof} <- native_request_settled(origin.agent, request_id),
         true <- native_origin_key(proof) == key do
      {:ok, proof}
    else
      _unconfirmed -> {:error, :native_not_idle}
    end
  end

  defp retire_native_origin(state, proof) do
    state = %{state | native_retired: MapSet.put(state.native_retired, native_origin_key(proof))}
    settle_native_effects(state)
  end

  defp settle_native_effects(state) do
    live = MapSet.new(state.native_scopes, fn {_token, scope} -> scope.effect end)

    {effects, changed?} =
      Enum.reduce(state.native_effects, {state.effects, false}, fn {id, origin}, acc ->
        if MapSet.member?(state.native_retired, native_origin_key(origin)) and
             not MapSet.member?(live, origin.effect),
           do: settle_native_effect(acc, id),
           else: acc
      end)

    if changed?, do: persist!(%{state | effects: effects}), else: state
  end

  # The native group stopped, but cancellation may have interrupted a write.
  # This closes execution bookkeeping without manufacturing a tool result or
  # claiming rollback. External Process/Eval cleanup remains a separate gate.
  defp settle_native_effect({effects, changed?}, id) do
    case Map.get(effects, id) do
      %{status: status} = effect
      when status in [:running, :uncertain] and not is_map_key(effect, :completed_at) ->
        effect =
          effect
          |> Map.put(:status, :uncertain)
          |> Map.put(:completed_at, now())
          |> Map.put(:settlement, %{source: :native_exec, execution: :stopped, effect: :uncertain})

        {Map.put(effects, id, effect), true}

      _effect ->
        {effects, changed?}
    end
  end

  # An idle replacement actor can retain its restored native parent/tag even
  # when the original execution's closure receipt was lost. Retire that exact
  # actor once its request is idle; keep effect/scope/resource uncertainty and
  # the sealed Session independently until their own receipts arrive.
  defp retire_stopping_actor(
         %{stop: %{native: :confirmed, actor: :pending, actor_pid: pid}} = state
       )
       when is_pid(pid) do
    start_cleanup_task(state, :native_actor, fn -> {pid, stop_native_agent(pid)} end)
  end

  defp retire_stopping_actor(state), do: state

  defp confirm_stopped_actor(%{stop: nil} = state), do: state
  defp confirm_stopped_actor(state), do: put_in(state.stop.actor, :confirmed)

  defp stop_children(state) do
    Enum.reduce(state.children, state, fn {tag, child}, acc ->
      if MapSet.member?(state.stop.children, tag),
        do:
          start_cleanup_task(acc, {:child, tag}, fn -> OhMyJido.stop_session(child.session) end),
        else: acc
    end)
  end

  defp complete_cleanup(state, {:resource, key, _kind}, {%{id: key} = resource, result}),
    do: resource_cleanup(state, resource, result)

  defp complete_cleanup(state, {:resource, key, _kind}, result) do
    case Map.get(state.resources, key) do
      nil -> state
      resource -> resource_cleanup(state, resource, result)
    end
  end

  defp complete_cleanup(state, :native, {:ok, proof}) do
    if proof.request == state.stop.native_run do
      state
      |> retire_native_origin(proof)
      |> put_in([:stop, :native], :confirmed)
    else
      state
    end
  end

  defp complete_cleanup(state, :native_actor, {pid, :ok}) do
    if state.stop.actor_pid == pid,
      do: put_in(state.stop.actor, :confirmed),
      else: state
  end

  defp complete_cleanup(state, {:native_retirement, key}, {:ok, proof}) do
    if native_origin_key(proof) == key, do: retire_native_origin(state, proof), else: state
  end

  defp complete_cleanup(state, :native, _unconfirmed) do
    if is_nil(state.stop.result) and
         System.monotonic_time(:millisecond) < state.stop.deadline do
      Process.send_after(self(), {:poll_stop_native, state.stop.id}, 20)
    end

    state
  end

  defp complete_cleanup(state, {:child, tag}, :ok) do
    Runtime.release(Map.get(state.child_leases, tag))

    children =
      case Map.fetch(state.children, tag) do
        {:ok, child} -> Map.put(state.children, tag, %{child | status: :stopped})
        :error -> state.children
      end

    state = %{
      state
      | child_leases: Map.delete(state.child_leases, tag),
        children: children
    }

    put_in(state.stop.children, MapSet.delete(state.stop.children, tag))
  end

  defp complete_cleanup(state, :services, :ok), do: put_in(state.stop.services, :confirmed)
  defp complete_cleanup(state, _key, _unconfirmed), do: state

  defp resource_cleanup(state, resource, result) do
    confirmed = cleanup_confirmed?(resource, result)

    state =
      cond do
        confirmed ->
          remove_resource(state, resource.id)

        Map.has_key?(state.resources, resource.id) ->
          update_in(state.resources[resource.id], &Map.put(&1, :cleanup, :uncertain))

        true ->
          state
      end

    emit(
      state,
      :resource_cleanup,
      %{
        kind: resource.kind,
        outcome: Redact.sanitize(result, state.secrets),
        confirmed: confirmed
      },
      resource.run
    )
  end

  defp remove_resource(state, key) do
    case Map.pop(state.resources, key) do
      {nil, _resources} ->
        state

      {resource, resources} ->
        if resource.monitor, do: Process.demonitor(resource.monitor, [:flush])
        %{flush_resource_streams(state, resource) | resources: resources}
    end
  end

  defp pending_effects(state) do
    state.effects
    |> Enum.filter(fn {_id, effect} -> pending_effect?(effect) end)
    |> Enum.map(fn {id, _effect} -> id end)
    |> Enum.sort()
  end

  defp pending_resources(state) do
    resources = Map.new(state.resources, fn {key, resource} -> {key, resource.kind} end)

    state.cleanup_tasks
    |> Enum.reduce(resources, fn
      {_ref, %{key: {:resource, key, kind}}}, acc -> Map.put(acc, key, kind)
      _cleanup, acc -> acc
    end)
    |> Map.values()
    |> Kernel.++(List.duplicate(:native_execution, map_size(state.native_scopes)))
    |> Enum.sort()
  end

  defp stop_uncertainty(state) do
    services = if state.stop.services == :pending, do: [:session_resources], else: []
    children = Enum.map(state.stop.children, fn _tag -> :subagent end)
    actor = if state.stop.actor == :confirmed, do: [], else: [:native_agent]

    %{
      reason: :cleanup_uncertain,
      cleanup: :uncertain,
      pending_effects: pending_effects(state),
      pending_resources: Enum.sort(pending_resources(state) ++ services ++ children ++ actor),
      native: state.stop.native
    }
  end

  defp settle_stop(%{stop: nil} = state), do: state
  defp settle_stop(%{stop: %{result: :ok}} = state), do: state

  defp settle_stop(state) do
    state = retire_stopping_actor(state)

    if pending_effects(state) == [] and pending_resources(state) == [] and
         state.stop.native == :confirmed and state.stop.actor == :confirmed and
         MapSet.size(state.stop.children) == 0 do
      settle_stop_services(state)
    else
      state
    end
  end

  defp settle_stop_services(%{stop: %{services: :waiting}} = state) do
    context = state.context
    runtime = state.ref.runtime
    session_id = state.ref.id
    state = put_in(state.stop.services, :pending)

    start_cleanup_task(state, :services, fn ->
      eval = Map.get_lazy(context.metadata, :eval, fn -> Runtime.eval(runtime) end)

      with :ok <- close_eval_session(eval, session_id),
           :ok <- OhMyJido.Extensions.close_session(context) do
        OhMyJido.Tools.Skill.clear(context)
        :ok
      end
    end)
  end

  defp settle_stop_services(%{stop: %{services: :confirmed}} = state) do
    Process.cancel_timer(state.stop.timer)

    state =
      if state.active,
        do: finish_run(state, :cancelled, nil, :session_stopped),
        else: state

    state = %{state | status: :stopped} |> persist!()
    reply_stop(state, :ok)
  end

  defp settle_stop_services(%{stop: %{services: :pending}} = state), do: state

  defp close_eval_session(nil, _session_id), do: :ok
  defp close_eval_session(eval, session_id), do: OhMyJido.Eval.close_session(eval, session_id)

  defp reply_stop(state, result) do
    Enum.each(state.stop.waiters, &GenServer.reply(&1, result))
    %{state | stop: %{state.stop | waiters: [], result: result}}
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

  defp cleanup_confirmed?(
         %{kind: :eval, handle: %{execution_id: id}},
         {status, %{cleanup: :confirmed, execution_id: id}}
       )
       when status in [:ok, :error],
       do: true

  defp cleanup_confirmed?(%{kind: :process}, {status, %{cleanup: :confirmed}})
       when status in [:ok, :error],
       do: true

  defp cleanup_confirmed?(_resource, _result), do: false

  defp request_options_allowed(state, opts) do
    cond do
      Models.credential_options?(opts) -> {:error, :credentials_must_come_from_host}
      map_size(state.runs) >= state.config[:max_runs] -> {:error, {:capacity, :run_history}}
      true -> :ok
    end
  end

  defp record_effect(state, run_id, tool_call) do
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

      {:ok, persist!(%{state | effects: Map.put(state.effects, tool_call.id, record)})}
    else
      true -> {:error, :effect_already_recorded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending_effect?(%{
         status: :uncertain,
         execution_settlement: %{
           source: :operator,
           execution: :stopped,
           effect: :uncertain,
           native_stop_confirmed: false
         }
       }),
       do: false

  defp pending_effect?(%{status: status} = effect) when status in [:running, :uncertain],
    do: not Map.has_key?(effect, :completed_at)

  defp pending_effect?(%{status: status}) when status in [:completed, :failed], do: false

  # A malformed journal record is not evidence that execution has settled.
  defp pending_effect?(_effect), do: true

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

  defp effect_status({:error, %{type: :timeout}}), do: :uncertain

  defp effect_status({:error, %{type: :timeout}, _effects}), do: :uncertain

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
    case agent_conversation(state.agent_pid) do
      {:ok, messages} ->
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

        messages = Enum.map(messages, &clear_pending_context/1)

        with {:ok, _agent} <- replace_context(state, messages),
             do: {:ok, %{state | conversation: messages}}

      {:error, _reason} = error ->
        error
    end
  end

  defp clear_pending_context(message) do
    Map.update(message, :refs, nil, &Map.drop(&1 || %{}, [:context, "context"]))
  end

  defp agent_conversation(pid) do
    case Jido.AgentServer.agent(pid) do
      %Jido.Agent{state: %{conversation: conversation}} ->
        native_conversation(conversation)

      _agent ->
        {:error, :terminal_context_unavailable}
    end
  catch
    :exit, _reason -> {:error, :agent_unavailable}
  end

  defp native_conversation(%Jido.Session{thread: thread} = session) do
    # A failed request is not promoted to a successful native request. The host
    # nevertheless retains its complete tool exchanges as effect evidence.
    # Native projection still drops incomplete batches; no tool is replayed.
    entries =
      Enum.map(thread.entries, fn entry ->
        %{entry | refs: Map.drop(entry.refs, [:context, "context"])}
      end)

    Jido.AI.Thread.Projection.project(%{session | thread: %{thread | entries: entries}})
  end

  defp native_conversation(_history), do: {:error, :terminal_context_unavailable}

  defp replace_context(state, messages) do
    context = Jido.AI.Thread.Projection.append_entries(Jido.Thread.new(), messages)

    Jido.AI.Orchestration.modify_context(
      state.agent_pid,
      %{type: :replace, reason: :compaction, result_context: context},
      op_id: Jido.Util.generate_id()
    )
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
