# Run coding tasks

Use managed sessions to give a coding agent a task, show its progress in your application, and keep a human available for questions. A [run](../concepts.md) is one task submitted to a session; it is not the whole lifetime of the session.

## Before you start

- Put `{OhMyJido, name: MyApp.Coding}` under your application supervisor. Starting the runtime does not open a session or make a model request. See [getting started](../getting-started.md).
- Choose an existing workspace directory and the tools and permissions the task needs. A new session has no permissions. Tool availability does not grant permission; see [permissions and approvals](permissions-and-approvals.md).
- For model tasks, configure an explicit runtime credentials resolver, such as `credentials: {MyApp.ModelCredentials, []}`, and select an account it recognizes. An account is an opaque reference, not a token. Nothing discovers provider keys from the environment for you.

## Open a session and submit a task

This session can inspect files, edit them, run commands, and ask clarification questions. The paths and account below are application-specific values.

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:read, :edit, :exec, :ask],
    tools: OhMyJido.Tools.select!([:read_only, :editing, :process]) ++
      [OhMyJido.Tools.Question],
    role: :coding,
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic"
  )

:ok = OhMyJido.subscribe(session, self(), max_pending: 128)

{:ok, run_id} =
  OhMyJido.prompt(session, "Repair the failing test. Preserve the public API.", [])
```

`prompt/3` returns a run ID as soon as the session accepts the task, not a finished answer. One run can be active per session. Later problems, such as a rejected API key or an account that cannot use the model, appear in the result of `await/3`.

You can use `bundles:` instead of an explicit `tools:` list, but not both. A session selection replaces the runtime's tool availability. With neither option, it uses the runtime registry or `OhMyJido.Tools.default/0`. Actual model exposure also depends on permissions and the selected model's tool support.

For a credential-free first operation, call a registered tool directly:

```elixir
{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

`file.snapshot` identifies the whole file, even if a read selects only a line range. Calls you make with `execute_tool/4` use the same permission checks, policy and journal as the agent's calls. To use tools without a managed runtime, see the [own-agent and standalone-tool guide](jido-agents.md); those integrations do not get session recovery.

## Wait for the result

Call `await/3` from a process that is not your only question responder:

```elixir
result = OhMyJido.await(session, run_id, timeout: 60_000)
```

| Result | Meaning |
|---|---|
| `{:ok, %{status: :completed} = record}` | The model run returned successfully. Inspect its answer and actual tool outcomes. |
| `{:error, %{status: status} = record}` | The run ended with `:failed`, `:cancelled`, `:suspended`, `:timed_out`, or `:interrupted`. |
| `{:error, :timeout}` | This caller stopped waiting. The run continues; call `await/3` again or explicitly cancel it. |
| `{:error, :unknown_run}` | This session has no record of that run ID. |
| `{:error, :session_unavailable}` | The session process is unavailable. Use the recovery workflow rather than assuming the task stopped. |

The default wait is 30,000 ms. A caller timeout does not cancel the run and is different from the runtime's run deadline, which can produce a terminal `:timed_out` record.

### Interpret the result

| Run-record field | Use |
|---|---|
| `id`, `query` | Correlate the record with the submitted task. |
| `status`, `started_at`, `completed_at` | Distinguish a completed answer from other terminal outcomes; timestamps are milliseconds. |
| `answer`, `error` | Read the sanitized answer or failure. A restored interrupted run may not have an answer. |
| `usage` | Read accumulated usage across model turns. |
| `tools` | Find journal summaries with `id`, `name`, `status`, `started_at`, and, when available, `completed_at`. |

A model can finish after a tool failed. In the effect journal, `status: :completed` means that a terminal result was recorded, not that the operation succeeded. An approval denial and a known command failure are both recordable outcomes. Use `inspect_session/1` in trusted application code to look up `snapshot.effects[tool_id].result`, and inspect operation-specific evidence such as the actual process exit status.

Neither `status: :completed` nor `:run_completed` proves that the repository passes its tests or that a goal is verified. [Explicit goal completion](#retain-progress-and-complete-a-goal) is a separate operation.

## Consume events without blocking your UI

Subscribers receive `{:oh_my_jido, %OhMyJido.Event{}}`. Every event has `session_id`, an optional `run_id`, a session-wide `seq`, `kind`, `at_ms`, and a redacted, bounded `payload`.

Subscribe before submitting work if you need the first events. A subscription receives future events, not an automatic replay. Read the retained buffer with a sequence cursor:

```elixir
recent_events = OhMyJido.events(session, after: 0)
```

The buffer defaults to 256 events. Sequence numbers survive durable session restart, but an old cursor can miss overwritten events. A subscriber is detached when it dies or its mailbox reaches its bound (`max_pending`, default 128). The bound counts its entire mailbox, not only Oh-My-Jido messages. Re-subscribing an existing PID is idempotent; there is no separate unsubscribe API or guaranteed lossless external event log. Persist an approved application projection if you need one.

### Handle events in a GenServer

This backend coordinator accepts tasks and human answers without waiting for a model run inside a callback. Its question maps are private application data; render only an authorized projection in your authenticated UI.

```elixir
defmodule MyApp.CodingInbox do
  use GenServer

  def start_link(session), do: GenServer.start_link(__MODULE__, session)
  def submit(pid, task), do: GenServer.call(pid, {:submit, task})
  def questions(pid), do: GenServer.call(pid, :questions)
  def answer(pid, id, value), do: GenServer.call(pid, {:answer, id, value})

  @impl true
  def init(session) do
    :ok = OhMyJido.subscribe(session, self())
    {:ok, %{session: session, questions: %{}, last_event: nil}}
  end

  @impl true
  def handle_call({:submit, task}, _from, state) do
    {:reply, OhMyJido.prompt(state.session, task, []), state}
  end

  def handle_call(:questions, _from, state), do: {:reply, state.questions, state}

  def handle_call({:answer, id, value}, _from, state) do
    {:reply, OhMyJido.answer(state.session, id, value), state}
  end

  @impl true
  def handle_info(
        {:oh_my_jido,
         %OhMyJido.Event{kind: :approval_requested, payload: %{id: id, question: question}}},
        state
      ) do
    {:noreply, %{state | questions: Map.put(state.questions, id, question)}}
  end

  def handle_info(
        {:oh_my_jido, %OhMyJido.Event{kind: :approval_answered, payload: %{id: id}}},
        state
      ) do
    {:noreply, %{state | questions: Map.delete(state.questions, id)}}
  end

  def handle_info({:oh_my_jido, %OhMyJido.Event{kind: kind} = event}, state)
      when kind in [:cancellation_requested, :run_completed] do
    # Cancellation and run completion close every pending question
    # without sending :approval_answered.
    {:noreply, %{state | questions: %{}, last_event: summary(event)}}
  end

  def handle_info({:oh_my_jido, %OhMyJido.Event{} = event}, state) do
    {:noreply, %{state | last_event: summary(event)}}
  end

  defp summary(event),
    do: Map.take(Map.from_struct(event), [:session_id, :run_id, :seq, :kind, :at_ms])
end
```

Have a separate caller wait with `await/3`. A LiveView can use the same `handle_info({:oh_my_jido, %OhMyJido.Event{}}, socket)` message pattern and update its assigns instead. Do not call `await/3` in the only process that can display or answer a pending question.

### Answer approvals and clarification questions

Both use an `:approval_requested` event with `payload: %{id: question_id, question: question_map}`. The waiting operation stays in its worker while your UI obtains a human response. With the default local policy, questions remain pending until answered. A custom policy's `question/3` callback (see `OhMyJido.Host`) can instead return an immediate `{:ok, answer}` or an error.

```elixir
:ok = OhMyJido.answer(session, question_id, human_answer)
```

| Request | How to answer |
|---|---|
| Effect approval | Only `true`, `:approve`, or `"approve"` consents in the core policy. Other values deny. |
| Clarification | Return the requested data. A question can include `options` and `multi`; the answer may be structured. It does not grant a permission. |
| Expired, resolved or withdrawn question | `answer/3` returns `{:error, :unknown_question}`. A question is withdrawn when the operation waiting for it ends first; `:approval_answered` then reports `{:error, :withdrawn}`. Do not retry it as a new approval. |

There is no default consent: dismissal, omission, timeout, and a late response are not approval. The defaults are eight pending questions and a 300,000 ms deadline. Capacity, policy or deadline failure stops the waiting operation; run termination rejects its pending questions. Do not automatically approve every event, and do not put credentials in questions or UI logs. A custom policy can impose stricter consent rules. See [permissions and approvals](permissions-and-approvals.md) for policy details.

### Event-kind reference

Handle events by kind, and tolerate kinds your UI does not display. Model, tool, and repository output is data, not application instructions.

| Kinds | UI use |
|---|---|
| `:run_started`, `:run_completed` | Track application runs. Always inspect `:run_completed`'s `payload.status`; the name also covers failed, cancelled, suspended, timed-out, and interrupted runs. |
| `:request_started`, `:request_completed`, `:request_failed`, `:request_cancelled` | Observe the underlying Jido.AI model/tool request. Collect the application run record for the final result. |
| `:llm_started`, `:llm_delta`, `:llm_completed` | Show model progress and accumulated usage. Streamed text appears in `payload.delta`. |
| `:tool_started`, `:tool_completed` | Show tool activity; correlate `payload.tool_name` and `payload.tool_call_id` with journal records. |
| `:tool_output` | Show Process or Eval output from `payload.text` and `payload.stream`. Eval also supplies `payload.execution_id`. |
| `:output_started`, `:output_validated`, `:output_repair`, `:output_failed` | Show structured-output validation progress. |
| `:approval_requested`, `:approval_answered` | Add or remove a pending human decision. The answered event contains the safe result of answering. Cancellation (`:cancellation_requested`), run completion (`:run_completed`) and `stop_session/1` close every pending question without an `:approval_answered` event. |
| `:steering_queued`, `:input_injected`, `:cancellation_requested`, `:session_resumed` | Reflect run controls and input accepted by the model loop. |
| `:checkpoint`, `:checkpoint_saved`, `:context_compacted`, `:keepalive` | Observe model-loop checkpoints, explicit session checkpoints, context maintenance, and liveness. |
| `:plan_updated`, `:goal_completed`, `:experiment_completed` | Update task progress and measured experiment results. |
| `:tool_registered`, `:tool_unregistered`, `:subagent_started`, `:subagent_completed` | Reflect changing availability and delegated work. |
| `:resource_cleanup`, `:session_cleanup_uncertain`, `:worker_failed`, `:worker_recovered`, `:interrupted_execution_reconciled` | Display lifecycle and recovery state. Ordinary finished Eval work can emit cleanup events even when no run is active. |

Stream fragments are sanitized and bounded; they need not match the provider's wire chunks. The [API reference](../reference/api.md) describes the full event envelope and payload contract.

## Steer, cancel, or suspend work

| Operation | Behavior |
|---|---|
| `OhMyJido.steer(session, run_id, text)` | Queue additional input for the active model loop and retain it as a task constraint. |
| `OhMyJido.cancel(session, run_id)` | Request cancellation and prevent new effects for that run. `:ok` acknowledges the request, not cleanup or rollback. |
| `OhMyJido.suspend(session, run_id)` | Terminate this run with suspended status and block new prompts until `resume/1`. |
| `OhMyJido.resume(session)` | Unblock a suspended session for a new prompt. It does not restart the old request or repeat its effects. |

For example, while the run is active:

```elixir
:ok = OhMyJido.steer(session, run_id, "Preserve the public function names.")
:ok = OhMyJido.suspend(session, run_id)
{:error, %{status: :suspended}} = OhMyJido.await(session, run_id)

:ok = OhMyJido.resume(session)
{:ok, next_run_id} = OhMyJido.prompt(session, "Inspect the current diff before continuing.", [])
```

Controls aimed at a non-active run return `{:error, :run_not_active}`; `resume/1` otherwise returns `{:error, :not_suspended}`. A stopping or cleanup-uncertain session rejects new work with `:session_stopped`. Cancellation requests cleanup of owned Process/Eval resources, but a confirmed stop cannot undo earlier changes. See [sessions and recovery](sessions-and-recovery.md).

## Select a role, model, and account for a prompt

Per-prompt selection overrides the retained session selection. The resulting selection is retained for follow-up prompts. Roles change guidance and model choice, not permissions.

```elixir
{:ok, review_run_id} =
  OhMyJido.prompt(session, "Review the current diff without changing files.",
    role: :review,
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic",
    tools: [OhMyJido.Tools.Read, OhMyJido.Tools.Search]
  )
```

A prompt can narrow the session's registered tools, not add new ones. Unregistered tools produce `:tool_escalation`. There is no per-prompt replacement of credentials, host policy, or the request transformer; credential-bearing options are rejected with `:credentials_must_come_from_host`. See [models and accounts](models-and-accounts.md) for selection precedence and [configuration](../reference/configuration.md) for forwarded inference preferences.

## Retain progress and complete a goal

Keep important task facts separately from the transcript so they survive compaction and restoration:

```elixir
:ok = OhMyJido.retain(session, %{
  goal: "Repair increment without changing the public API",
  constraints: ["Preserve public function names"],
  file_facts: %{"lib/counter.ex" => "Owns increment behavior"},
  memory: %{"decision" => "Keep the existing return type"},
  unresolved_work: ["Run the project tests"]
})

:ok = OhMyJido.plan(session, [
  %{id: "repair", title: "Repair and test increment", status: :in_progress}
])
```

`file_facts` and `memory` are maps with binary keys and data-only values. Their entries merge with existing entries. Constraints merge and deduplicate; an explicitly supplied `unresolved_work` list replaces the previous list. Supplying `goal` updates the authoritative session goal, including when facts arrive through the JSON/string-keyed Memory Action. Omitting it preserves the goal. Retention fails if mandatory facts cannot fit; it does not silently discard them.

Plan updates include every existing item with the same ID and title. You cannot discard prior work, rename an item, or reopen a `:done` item. Plans allow at most 100 items and one `:in_progress` item. Other statuses are `:pending`, `:blocked`, and `:done`; a blocked item needs a nonempty `reason`.

After performing the repair, record an actual meaningful check and use its journal ID to complete the goal:

```elixir
check_id = "verification-" <> Integer.to_string(System.unique_integer([:positive]))

{:ok, %{status: :exited, exit_status: 0, effect: :completed}} =
  OhMyJido.execute_tool(session, "shell", %{executable: "mix", args: ["test"]},
    effect_id: check_id
  )

:ok = OhMyJido.plan(session, [
  %{id: "repair", title: "Repair and test increment", status: :done}
])

:ok = OhMyJido.complete_goal(session, %{effect_ids: [check_id]})
```

The completion gate requires a nonempty all-done plan and completed `"shell"` effects whose real process results have `status: :exited`, `exit_status: 0`, and `effect: :completed`. A self-declared `checks: [%{passed: true}]` map cannot replace those records. Your application still chooses whether a successful command is an adequate check of the requirement. Only explicit successful completion emits `:goal_completed`; an ordinary model answer does not invoke the gate.

The `effect_id:` execution option is for trusted application correlation, not a model-visible parameter or permission grant. Reusing a recorded ID is rejected before execution. Ordinary calls generate an ID for you.

## Run measured experiments

Experiments run a bounded list of registered-tool trials sequentially, once each. They require `:experiments` plus every underlying tool's permissions and authorization. This separate session compares two test seeds without making a model request:

```elixir
{:ok, experiment_session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    model: "anthropic:claude-sonnet-4-6",
    permissions: [:exec, :experiments],
    tools: [OhMyJido.Tools.Shell]
  )

{:ok, experiment} =
  OhMyJido.experiment(experiment_session, [
    %{tool: "shell", params: %{executable: "mix", args: ["test", "--seed", "0"]}},
    %{tool: "shell", params: %{executable: "mix", args: ["test", "--seed", "1"]}}
  ], timeout: 30_000)
```

| Experiment detail | Meaning |
|---|---|
| Default bounds | At most eight trials. Each trial has a 30,000 ms `timeout` for the whole trial, including approval waits inside the Action; `tool_timeout_ms` does not change it. A `:custom` approval for a trial tool without `capability/0` is asked before the trial starts and is limited by `question_timeout_ms`. Invalid, empty, or excessive trials return `:invalid_or_excessive_trials`. |
| Record | `id`, `results`, `effect`, `completed_at`, and `status`. `{:ok, record}` can still have `status: :failed`. |
| Trial result | `tool`, measured `duration_us`, `status`, `effect`, JSON-compatible `result`, exact safe `receipt`, and `receipt_error`. Operation results can include artifact references. |
| Retained result | Stored in memory under `"experiment:" <> id`, followed by an `:experiment_completed` event. |
| Failure after execution | `{:error, %{reason: reason, cause: cause, effect: certainty, experiment: complete_record}}`, where `reason` is `:experiment_retention_failed` or `:experiment_notification_failed`. |

Inspect the operation result as well as trial status: for example, a Shell call can return normally with a nonzero process exit status. Experiment `result` values convert tuples to lists for data-only retention. The Experiment Action uses `Jido.Action.Error.ExecutionFailureError`: post-execution failure fields are in `details` when called through `execute_tool/4`, and under `details.reason` from a direct `Jido.Exec.run`.

Preserve complete records returned on retention or notification failure. The trials already ran; do not repeat them to repair a missing memory or event entry. [Effect recording failures](sessions-and-recovery.md#handle-an-unrecorded-result) likewise carry the observed nested result instead of authorizing a retry.

## Limits

- Prompts must be binaries of 1–65,536 bytes; native text/transport validation still applies. One active run per session means concurrent submissions can return `:busy`; a suspended session returns `:suspended`.
- Capacity errors such as `{:capacity, :model}` and `{:capacity, :run_history}` reject work rather than queue it. Run/effect history limits survive stop and restore; see [configuration](../reference/configuration.md).
- Events are a bounded progress channel, not the full tool result or an audit log. Never export a whole `inspect_session/1` snapshot to public UI or telemetry; it contains private conversation/workspace data and a transient native PID.
- Workspace confinement and permissions are library policy, not an OS sandbox. Use appropriate OS isolation for untrusted commands; see [security](security.md).

## Related

- [Sessions and recovery](sessions-and-recovery.md)
- [Models and accounts](models-and-accounts.md)
- [Permissions and approvals](permissions-and-approvals.md)
- [Tools](tools.md) and [subagents](subagents.md)
- [API reference](../reference/api.md) and [configuration reference](../reference/configuration.md)
- [Plain Mix application example](../../examples/plain_mix/README.md)
