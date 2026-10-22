# Public API reference

Use this reference to embed a coding agent, control a session, or connect individual tools to your own Jido agent. Start with [Getting started](../getting-started.md) for a working application setup. Jido owns agent supervision, Jido.AI runs the model/tool loop, and ReqLLM connects to model providers.

There are three integration paths: managed sessions through `OhMyJido`, tools attached with `OhMyJido.Plugin`, and individual Jido Actions with an `OhMyJido.Context`. Only managed sessions provide the session effect journal, recovery, child-task coordination, and built-in approval conversation.

This page describes `jido-v3-preview` and its native Jido V3 integration. The `master` branch has its own reference for Jido 2.4; persistence and native-agent contracts are not interchangeable.

In the tables below, short module names such as `Context` mean `OhMyJido.Context`. Optional keyword arguments default to `[]` unless shown otherwise. Timeout options use milliseconds; authentication expiry timestamps and `Auth.Error.retry_after` use seconds; `duration_us` uses microseconds. Internal helpers marked `@doc false` are not additional integration APIs; standard supervision callbacks are shown for convenience.

## Types and result conventions

| Type | Contents and use |
|---|---|
| `SessionRef.t()` | `%OhMyJido.SessionRef{runtime: atom, id: binary}`. A durable identity, not a PID or proof that a worker is running. |
| `Event.t()` | `%OhMyJido.Event{session_id: binary, run_id: binary_or_nil, seq: nonnegative_integer, kind: atom, at_ms: integer, payload: map}`. Delivered as `{:oh_my_jido, event}`. |
| `Context.t()` | Required `session_id`, canonical `workspace`, and `permissions: MapSet`. Also carries `run_id`, `runtime`, `coordinator`, `account`, `model`, `role`, `host`, `tools`, `adapters`, `limits`, and `metadata`. Trusted application configuration, not model input. |
| `Process.Handle.t()` | Transient, caller-owned handle from `OhMyJido.Process.start/4`. Contains process/monitor identities and callbacks. Never persist it. |
| `Auth.Error.t()` | Safe diagnostic with `code`, `provider`, optional `status`, `request_id`, `retry_after`, `eligibility`, `quota`, and boolean `retryable`/`reauth_required`. Does not contain raw HTTP bodies, tokens, or callbacks. |
| `ContextPolicy.t()` | Versioned retained facts, bounded excerpts, pending/completed tool evidence, and summary digest. Serialize with `ContextPolicy.checkpoint/1`. |
| `Eval.Backend.handle()` | Transient backend handle map; not checkpoint data. |
| `Eval.Backend.request()` | Map with binary `id`/`source` and positive `timeout`, `output_limit`, and `generation`. |

Most calls return `{:ok, value}`, `:ok`, or `{:error, reason}`. Jido Actions can also return native three-element tuples with directives. Errors may be atoms, tuples, structured maps, or safe native exceptions. Match the documented reason/code rather than assuming an error is a string. An outer `{:ok, record}` does not always mean the operation inside the record succeeded: inspect run, process, Eval, and experiment status fields.

All managed-session calls can fail with `{:error, :session_unavailable}` or `{:error, :timeout}` when the coordinator cannot answer. A timeout is not permission to repeat an effect.

## Runtime and session lifecycle

```elixir
children = [{OhMyJido, name: MyApp.Coding}]

{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:read]
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

| Function | Returns | Behavior and errors |
|---|---|---|
| `OhMyJido.child_spec(options)` | Supervisor child specification | Use `{OhMyJido, name: MyApp.Coding}` in your supervision tree. `:name` is required. Starts no session, model request, or optional service. Invalid runtime configuration raises. |
| `OhMyJido.start_link(options)` | `Supervisor.on_start()` | Starts the named runtime directly. Same configuration as the child specification; startup errors are Supervisor errors. |
| `Runtime.child_spec(options)` | Supervisor child specification | Supervision callback used by the facade; the runtime name is the child ID. |
| `Runtime.start_link(options)` | `Supervisor.on_start()` | Same runtime as the facade. Requires a stable atom name; invalid names or limits raise. |
| `OhMyJido.start_session(runtime, options)`, `Runtime.start_session(runtime, options)` | `{:ok, session_ref}` or `{:error, reason}` | Requires an existing `workspace:` directory. Permissions default to none. Optional `id:` is a binary of 1–128 bytes. Errors include `:runtime_unavailable`, `:invalid_session_options`, `:invalid_session_id`, workspace/configuration errors, `:session_exists`, and `{:capacity, :sessions}`. |
| `OhMyJido.resume_session(runtime, id)`, `Runtime.resume_session(runtime, id)` | `{:ok, session_ref}` or `{:error, reason}` | Reads native `Jido.Persistence` versioned bytes/compare-and-swap state and restores without replaying interrupted work. Storage, checkpoint-version, and restore errors propagate; an already supervised ID returns `:session_exists`. |
| `OhMyJido.list_sessions(runtime)`, `Runtime.list_sessions(runtime)` | Sorted list of `SessionRef` values | Lists currently supervised sessions, not every stored checkpoint. Call with a running runtime; this registry operation does not wrap an unavailable runtime in a session error tuple. |
| `OhMyJido.inspect_session(session)` | `{:ok, snapshot}` or `{:error, reason}` | Redacted state for trusted application code. Includes private workspace/conversation data, bounded `native_execution` diagnostics, and a transient `agent_pid` (possibly nil after the sealed session retires its native actor). Do not expose the whole map to public UIs or telemetry. |
| `OhMyJido.checkpoint(session)` | `:ok` or `{:error, reason}` | Captures an explicit checkpoint only when no run is active. Returns `:run_active` otherwise; native checkpoint errors propagate. |
| `OhMyJido.stop_session(session)` | `:ok` or `{:error, reason}` | Blocks new work, then waits up to 5,000 ms for owned execution, effects, resources, children and services to settle. Terminates the exact session child only after confirmed cleanup. An error with `reason: :cleanup_uncertain` leaves the coordinator supervised and sealed (not accepting new work); its exact idle Jido agent can be retired independently without inventing effect/resource closure. Does not roll back changes or delete storage. |
| `OhMyJido.reconcile_interrupted(session, run_id, expected_effect_ids, :orphan_resources_reconciled)` | `:ok` or `{:error, reason}` | Records an operator's acknowledgement after independently stopping/reconciling orphaned resources. Requires the complete nonempty original pending effect-ID set and an idle/suspended coordinator with no active run, stop, resources, live native execution scopes, or cleanup work. Errors include `:invalid_reconciliation`, `:execution_not_quiescent`, and `:reconciliation_mismatch`. |

Starting a session with an ID already present in storage restores that checkpoint; it does not replace its workspace or permissions with new options. Use a new ID for a new policy or perform an explicit application-owned storage migration. Tool availability can be selected with `bundles:` or `tools:`, not both; selection never grants permissions.

Inspection fields are `id`, `status`, `active_run`, `agent_pid`, `workspace`, `permissions`, `role`, `account`, `model`, `conversation`, `goal`, `plan`, `retained`, `effects`, `runs`, `children`, `pending_questions`, `native_execution`, and `seq`. `native_execution` contains bounded count/limit diagnostics, not reusable execution tokens or process authority. Project only application-approved fields for a UI. PIDs are not JSON values or durable handles.

Reconciliation makes no model call and replays no continuation. Its durable `execution_settlement` records `source: :operator` and `native_stop_confirmed: false`; uncertain outcomes stay uncertain, missing results/timestamps stay missing, and late results cannot overwrite the boundary. Never expose this acknowledgement as a model tool, browser request, or MCP input. Worker or caller death alone is not cleanup evidence.

The default ETS storage survives only while its table remains available. For application restarts, configure `storage: {Jido.Persistence.File, path: "/private/coding-sessions"}` or another `Jido.Persistence.Adapter` implementation with binary values and compare-and-swap writes. One BEAM instance must own the file adapter directory. Jido 2.4 `Jido.Storage` checkpoints are not automatically migrated. Restored sessions use the current runtime's host policy, credential resolver, adapter bindings, and resource limits; those executable bindings are not recovered from repository text or stored credentials. See [Sessions and recovery](../guides/sessions-and-recovery.md) and [Configuration](configuration.md).

## Task execution and control

| Function | Returns | Behavior and errors |
|---|---|---|
| `OhMyJido.prompt(session, task, options \\ [])` | `{:ok, binary_run_id}` or `{:error, reason}` | Admits one task; `task` must be a binary of 1–65,536 bytes. One active model request per session. Errors include `:busy`, `:suspended`, `:session_stopped`, `:invalid_prompt`, selection/configuration errors, `:tool_escalation`, `:credentials_must_come_from_host`, and capacity errors. |
| `OhMyJido.await(session, run_id, options \\ [])` | `{:ok, completed_record}` or `{:error, record_or_reason}` | Default `timeout: 30_000`. Unknown IDs return `:unknown_run`; caller expiry returns `:timeout` without cancelling the run. Only `status: :completed` produces the success tuple. |
| `OhMyJido.steer(session, run_id, text)` | `:ok` or `{:error, reason}` | Queues input for the active native ReAct request and retains it as a constraint. Returns `:run_not_active` for other runs; retention/native errors propagate. |
| `OhMyJido.cancel(session, run_id)` | `:ok` or `{:error, reason}` | Requests cancellation, prevents new effects for the run, and starts owned resource cancellation. `:ok` means the request was accepted, not that earlier effects were undone. Returns `:run_not_active` for a nonactive run. |
| `OhMyJido.suspend(session, run_id)` | `:ok` or `{:error, reason}` | Cancels the active run with suspended status. New prompts remain blocked until `resume/1`. Same active-run checks as cancellation. |
| `OhMyJido.resume(session)` | `:ok` or `{:error, reason}` | Allows a new task after suspension; never continues the cancelled request. Returns `:not_suspended` or `:session_stopped` when inappropriate. |
| `OhMyJido.answer(session, question_id, answer)` | `:ok` or `{:error, reason}` | Resolves one approval or clarification. Expired, resolved or withdrawn IDs return `:unknown_question`. Effect consent accepts only `true`, `:approve`, or `"approve"`. |

A terminal run record has `id`, `status`, `query`, `started_at`, `completed_at`, `answer`, `error`, `usage`, and `tools`. Tool summaries identify journal entries with `id`, `name`, `status`, `started_at`, and optional `completed_at`. Terminal statuses are `:completed`, `:failed`, `:cancelled`, `:suspended`, `:timed_out`, and `:interrupted`. A model can return successfully after a tool failed; inspect tool results and checks before treating the task as verified.

Model or credential errors may occur after `prompt/3` returns a run ID. Always obtain the terminal result. Prompt options choose role/model/account, narrow registered tools, and pass approved inference preferences; they cannot replace host policy, credentials, or the request transformer. This branch defaults to `"anthropic:claude-sonnet-4-6"` for coding/planning/review/advisor and `"anthropic:claude-haiku-4-5"` for exploration/compaction. Explicit inputs or configured aliases can override them. See [Running tasks](../guides/running-tasks.md) and [Configuration](configuration.md).

## Events

| Function | Returns | Behavior and errors |
|---|---|---|
| `OhMyJido.subscribe(session, pid, options \\ [])` | `:ok` or `{:error, reason}` | Receives future events. `max_pending:` defaults to runtime `subscriber_limit`; subscribing the same PID again is idempotent. Pass a real PID and a valid bound. |
| `OhMyJido.events(session, options \\ [])` | List of `Event` values or `{:error, reason}` | Returns retained events with `seq > after`; default `after: 0`. Does not recover events already overwritten by `event_limit`. |

Subscribers receive `{:oh_my_jido, %OhMyJido.Event{}}`. Sequence numbers survive durable coordinator restart. A dead subscriber or one whose **whole process mailbox** reaches its bound is detached. There is no separate unsubscribe API or guaranteed lossless external log. Persist an approved projection in your application if you need one.

### Native model and tool events

Every projected native payload includes `iteration`, `tool_name`, and `tool_call_id` (tool identity fields may be nil). It copies only these native data fields when present: `usage`, `reason`, `status`, `termination_reason`, `retry_after`, `text`, `delta`, `chunk_type`, `error_code`, and `code`. It does not broadcast full prompts, tool arguments/results, checkpoint tokens, or arbitrary native error bodies. Use `await/3` or authorized inspection for the terminal result.

| Kind | Meaning and payload notes |
|---|---|
| `:request_started` | Native request began. The raw query and configuration fingerprint are not projected. |
| `:llm_started` | A model turn began; carries the common native identity/iteration fields, not the full request. |
| `:llm_delta` | Streaming model fragment in `delta`, with `chunk_type` when provided. Redaction can combine/split provider chunks. |
| `:llm_completed` | Model turn finished; bounded/redacted `text` and `usage` when supplied. Full content parts and tool-call arrays are not projected. |
| `:output_started` | Structured-output validation began; includes projected `status` when supplied. |
| `:output_validated` | Structured output passed validation; full parsed output/schema are not broadcast. |
| `:output_repair` | Native structured-output repair began; bounded status metadata, not the repair prompt. |
| `:output_failed` | Structured-output validation failed; only allowlisted diagnostic fields are projected. |
| `:tool_started` | A native tool call began; identify it with `tool_name`/`tool_call_id`, not arguments. |
| `:tool_completed` | A native tool call returned. Does not include its full result or prove a goal is verified. |
| `:keepalive` | Native execution is still alive; no completion or cleanup guarantee. |
| `:checkpoint` | Native checkpoint notification; the checkpoint token is not projected. |
| `:request_completed` | Native request returned; projected `usage` and `termination_reason` when supplied. The answer is in the run result. |
| `:request_failed` | Native request failed; projected safe code/status/reason fields only when present. Detailed terminal error is in the run record. |
| `:request_cancelled` | Native cancellation notification; `reason` when supplied. Does not imply rollback. |
| `:input_injected` | Pending input reached the native loop; its content and input ID are not projected. |

### Session events

All payloads below are sanitized and bounded. Treat model, repository, page, and tool text as untrusted data even after redaction.

| Kind | Payload and meaning |
|---|---|
| `:run_started` | `%{role: role, model: label}`; a managed run was admitted. |
| `:run_completed` | `%{status: terminal_status, usage: usage}`; terminal run state, not automatic goal verification. |
| `:steering_queued` | `%{text: text}`; steering was accepted and retained. |
| `:cancellation_requested` | `%{reason: reason}`; cancellation/suspension was requested. |
| `:approval_requested` | `%{id: question_id, question: map}`; effect approval or clarification. Answer with `answer/3`. |
| `:approval_answered` | `%{id: question_id, answer: result}`; the safe resolution result, such as `{:ok, answer}` or an error, including `{:error, :withdrawn}` when the waiting operation ended first. Cancellation, run completion and `stop_session/1` close pending questions without this event. |
| `:checkpoint_saved` | `%{safe: true}`; explicit checkpoint captured. |
| `:session_resumed` | `%{replay: false}`; session unblocked for a new task, not replayed. |
| `:context_compacted` | `%{removed_messages: count}`; conversation projection removed older messages. |
| `:plan_updated` | `%{plan: items}`; validated plan replacement. |
| `:goal_completed` | `%{goal: goal, evidence: verified_checks}`; explicit goal gate passed. |
| `:tool_registered` | `%{name: exact_name}`; available tool registry changed. |
| `:tool_unregistered` | `%{name: exact_name}`; future exposure removed. |
| `:subagent_started` | `%{tag: tag, child_session: id, child_run: id}`; tracked child started. |
| `:subagent_completed` | `%{tag: tag, result: result}`; tracked child returned. |
| `:experiment_completed` | `%{id: id, status: status, results: trials}`; measured trials were retained. |
| `:tool_output` | `%{stream: stream, text: fragment}` for process output; Eval adds `execution_id`. These are the public output events, not `:process_output` or `:eval_output`. |
| `:resource_cleanup` | `%{kind: kind, outcome: result, confirmed: boolean}`; observed owned-resource cleanup outcome. |
| `:session_cleanup_uncertain` | Cleanup diagnostic map with `reason: :cleanup_uncertain`; session remains sealed because settlement was not confirmed. |
| `:worker_failed` | `%{reason: safe_reason, replay: false}`; native agent worker exited. |
| `:worker_recovered` | `%{replay: false}`; replacement native worker started without replay. |
| `:interrupted_execution_reconciled` | `%{effects: ids, source: :operator, native_stop_confirmed: false}`; application operator acknowledgement, not successful effects. |

## Memory, plans, goals, and experiments

| Function | Returns | Behavior and errors |
|---|---|---|
| `OhMyJido.retain(session, facts)` | `:ok` or `{:error, reason}` | Retains `goal`, `constraints`, `file_facts`, `memory`, and `unresolved_work`. Errors include `:invalid_retained_context`, `:nonserializable_context`, and `:retained_context_too_large`. |
| `OhMyJido.plan(session, items)` | `:ok` or `{:error, reason}` | Validates/replaces the plan while preserving every prior item and title and keeping completed work done. Errors include `:invalid_plan`, `:invalid_task`, `:ambiguous_plan`, `:blocked_task_requires_reason`, and `:plan_would_discard_completed_or_required_work`. |
| `OhMyJido.complete_goal(session, %{effect_ids: ids})` | `:ok` or `{:error, reason}` | Requires a nonempty, all-done plan and eligible successful shell journal effects. Errors include `:verification_required`, `:unverified_effect`, `:verification_failed`, `:plan_required`, and `:unfinished_plan`. |
| `OhMyJido.experiment(session, trials, options \\ [])` | `{:ok, record}` or `{:error, reason}` | Runs explicit `%{tool: exact_name, params: map}` trials sequentially once. Requires `:experiments` plus each tool's permissions/authorization. Default trial bound is 8 and trial `timeout:` is 30,000; it limits the whole trial, including approval waits inside the Action, and `tool_timeout_ms` does not change it. A `:custom` approval for a trial tool without `capability/0` is asked before the trial starts and is limited by `question_timeout_ms`. Invalid/empty/excessive trials return `:invalid_or_excessive_trials`. |

`file_facts` and `memory` are maps with binary keys and data-only values. Constraints merge and deduplicate; supplied unresolved work replaces the previous list. An admitted `goal` becomes the authoritative session goal, including string-keyed facts from the Memory Action; facts without a goal preserve it. Retention fails rather than silently dropping required facts.

Plan items have binary `id` (1–128 bytes), binary `title` (1–2,048 bytes), `status` (`:pending`, `:in_progress`, `:blocked`, or `:done`), and optional `reason`. String status values are also accepted. At most 100 items and one `:in_progress` item are allowed. A blocked item needs a nonempty reason.

Goal evidence is `%{effect_ids: [binary_id, ...]}`, not self-declared `checks: [%{passed: true}]`. Every ID must identify a completed `"shell"` journal entry with a real exited process, exit status 0, and `effect: :completed`. Your application/task must choose meaningful checks: any successful command is not automatically a sufficient test. Model-run completion never calls this gate; only explicit successful goal completion emits `:goal_completed`.

An experiment record has `id`, `results`, `effect`, `completed_at`, and `status`. Each trial includes its tool, actual `duration_us`, status/result, effect certainty, exact safe `receipt`, and `receipt_error`; artifacts remain in the trial result. It is retained under memory key `"experiment:" <> id`. `{:ok, record}` may have `record.status == :failed`.

If retention or notification fails after trials ran, the API returns `{:error, %{reason: reason, cause: cause, effect: certainty, experiment: complete_record}}`, where `reason` is `:experiment_retention_failed` or `:experiment_notification_failed`. Preserve the record and reconcile; do not rerun trials to repair missing bookkeeping. The Experiment Action uses a native Jido error envelope: these fields are in `details` when called through `execute_tool/4`, and under `details.reason` from a direct `Jido.Exec.run`.

## Tools and child tasks

| Function | Returns | Behavior and errors |
|---|---|---|
| `OhMyJido.register_tool(session, action_module)` | `:ok` or `{:error, reason}` | Registers an application-authored Jido Action while no run is active. Native validation errors propagate; active runs return `:run_active`. |
| `OhMyJido.unregister_tool(session, exact_name)` | `:ok` or `{:error, reason}` | Removes future tool exposure while idle. Does not undo prior calls; active runs return `:run_active`. |
| `OhMyJido.execute_tool(session, exact_name, params, options \\ [])` | Native Action result or `{:error, reason}` | Executes a registered Action with authorization and journal recording. Defaults to the session's call limit, `tool_timeout_ms` plus `question_timeout_ms`, so one approval wait does not use the tool budget; no automatic effect retries. Options are `:timeout` and trusted `:effect_id`. Errors include unknown tool, permission/approval, admission, native Action, and recording errors. |
| `OhMyJido.delegate(session, task, options \\ [])` | `{:ok, %{tag: tag, session: child_ref, run: run_id, workspace: root, role: role}}` or `{:error, reason}` | Starts a separately tracked child with narrower permissions. Requires `:delegate`; errors include `:permission_escalation`, `:read_only_child`, `:invalid_child_permissions`, `:delegation_depth`, `:invalid_child_tag`, `:child_workspace_not_granted`, tag/capacity/native errors. |
| `OhMyJido.await_child(session, tag, options \\ [])` | Child's `await/3` result | Default wait timeout is 30,000. A caller timeout does not cancel the child. Unknown/starting children return `:unknown_child`/`:child_starting`. |
| `OhMyJido.steer_child(session, tag, text)` | `:ok` or `{:error, reason}` | Steers the tracked child run. Child lookup and active-run errors propagate. |
| `OhMyJido.cancel_child(session, tag)` | `:ok` or `{:error, reason}` | Cancels child work without cancelling the parent. Child lookup and active-run errors propagate. |

Names are exact binaries; model input never becomes an atom. Built-in Actions authorize at each effect boundary. Custom Actions without `capability/0` require `:custom`. Declaring a capability is not authorization: call `Tool.authorize/3` or a library operation that does so.

Child options include `tag:` (1–96 bytes), `role:` (default `:exploration`), `writable:` (default false), narrowed `permissions:`, an application-approved isolated `workspace:`, and `llm_opts:`, `req_http_options:`, `max_iterations:`. Children inherit the account and use the role's model selection. `:delegate` is removed from their permissions. Writable children need a distinct approved workspace or a real clean detached Git worktree; they do not write directly to the parent's root. See [Tools](../guides/tools.md) and [Subagents](../guides/subagents.md).

A trusted caller can pass `effect_id: id` to correlate an operation with a journal entry. Reusing a recorded ID is rejected before execution. It is not a tool parameter or a permission grant. If result sanitation or journal recording loses the coordinator after execution, the API returns:

```elixir
{:error,
 %{
   reason: :effect_recording_failed,
   cause: cause,
   effect: :uncertain,
   effect_id: id,
   result: sanitized_native_result
 }}
```

The nested result preserves observed outcomes, including complete Experiment trial records. The outer error means durable recording was not confirmed. Reconcile rather than execute again. Opaque effect IDs and child tags are dictionary identities, not credential-field names; their contents still receive credential sanitation.

## Standalone tools and context

| Function | Returns | Behavior and errors |
|---|---|---|
| `Tools.bundles()` | Map of bundle atoms to Action lists | `:read_only` = Read/Search/List; `:editing` = Write/Edit; `:elixir` = AST/LSP/Debug; `:process` = Shell/Git; `:live_inspection` = Observer. No permissions or services are granted. |
| `Tools.select(bundle_or_list)` | `{:ok, actions}` or `{:error, reason}` | Stable deduplication in caller order; empty list supported. Errors: `{:unknown_bundle, name}`, `{:invalid_bundle, value}`, `{:invalid_bundle_selection, :expected_atom_or_list}`. |
| `Tools.select!(bundle_or_list)` | Action list | Same selection, raising `ArgumentError` for invalid configuration. |
| `Tools.default()` | Complete implemented Action list | Not a blanket permission set or optional-service installer. Unconfigured services fail when invoked. |
| `Context.new(options)` | `{:ok, context}` or `{:error, {:invalid_context, field, reason}}` | Existing workspace required; canonicalizes symlinks. Defaults to a generated Jido session ID, no permissions, read-only availability, and `Host.Local`. |
| `Context.new!(options)` | Context | Same constructor; raises `ArgumentError` on invalid configuration. |
| `Context.fetch(context_or_execution_context)` | `{:ok, context}` or `{:error, :missing_context}` | Accepts a Context or `%{oh_my_jido: context}`. Extracts an existing trusted value; does not validate untrusted data into authority. |
| `Context.permitted?(context, permission_atom)` | Boolean | Checks the explicit permission set without atom conversion. |
| `Tool.authorize(context, capability, effect \\ %{})` | `:ok` or `{:error, reason}` | Checks permission and host policy. Approval waits in managed sessions; standalone approval returns `:approval_required`. Denial/errors include `{:permission_denied, capability}`, `:approval_denied`, `{:host_denied, capability}`, and `:authorization_service_failed`. |
| `Tool.find(context, exact_name)` | `{:ok, action_module}` or `{:error, {:unknown_tool, name}}` | Exact binary-name lookup only. |
| `Tool.execute(context, exact_name, params, options \\ [])` | Native Action result or `{:error, reason}` | Same execution boundary as `execute_tool/4`; journals only when a coordinator is present. Options: `:timeout` and `:effect_id`. |

`Context.new/1` accepts all Context fields plus `bundles:`. `tools:` replaces bundle selection and conflicts with `bundles:`. A host binding is a module or `{module, keyword_options}`. Adapter bindings are `%{capability_atom => {module, keyword_options}}` with `invoke/3`. Limits are atom-keyed nonnegative integer budgets. Unknown/duplicate options fail. Bindings are checked, not invoked: construction starts no application, credential lookup, model, language server, distribution, or process.

Run an Action directly with `Jido.Exec.run(action, params, %{oh_my_jido: context})`. Native V3 Exec does not retry and rejects the old `max_retries` execution option. The Action's workspace, permission, and host checks still apply. This is not a managed-session journal or durable recovery boundary. See [Jido agents](../guides/jido-agents.md).

## Direct file, process, and Git APIs

These APIs are for trusted code that already has a Context. They do not create a managed session by themselves. Prefer `execute_tool/4` or managed Actions when you need session journal entries.

| Function | Returns | Behavior and errors |
|---|---|---|
| `Workspace.new(root)` | `{:ok, canonical_absolute_root}` or `{:error, reason}` | Existing directory required. Errors include `:invalid_path`, `:enotdir`, and filesystem errors. |
| `Workspace.resolve(context, path, options \\ [])` | `{:ok, absolute_path}` or `{:error, reason}` | Confines paths without changing VM working directory. `allow_missing: true` permits explicitly supported missing targets. Traversal/symlink escape returns `:outside_workspace`. |
| `Workspace.relative(context, path)` | Relative path binary or `{:error, reason}` | Produces a workspace-relative display path; rejects invalid/outside paths. Does not itself open the file. |
| `Files.read(context, path, options \\ [])` | `{:ok, file_map}` or `{:error, error_map}` | Requires `:read`. Supports inclusive one-based `start_line:`/`end_line:` and byte limits. Binary line ranges return `:binary_range`; invalid/out-of-bounds ranges and filesystem errors are explicit. |
| `Files.write(context, path, content, snapshot, options \\ [])` | `{:ok, write_map}` or `{:error, error_map}` | Requires `:edit`; atomically creates/replaces UTF-8 content after checking a complete-file snapshot or `"missing"`. Rejects stale snapshots, invalid content, changed confinement, and oversized files. |
| `Files.edit(context, path, snapshot, edits, options \\ [])` | `{:ok, edit_map}` or `{:error, error_map}` | Requires `:edit`; exact nonoverlapping replacements against one original snapshot. Missing/ambiguous text, overlaps, stale snapshots, and binary edits are rejected. |
| `Files.snapshot(bytes)` | Lowercase SHA-256 binary | Hashes the exact complete original bytes, including newline sequences. |
| `Search.files(context, path \\ ".", options \\ [])` | `{:ok, %{paths: paths, count: count, skipped: skipped, truncated: boolean, truncation: flags, path: path}}` or `{:error, error_map}` | Requires `:read` and ripgrep. Confined discovery with ripgrep glob/ignore semantics and explicit bounds. |
| `Search.text(context, pattern, options \\ [])` | `{:ok, search_map}` or `{:error, error_map}` | Requires `:read`; returns matches, precise locations, counts, scanned files/bytes, skipped records, and truncation flags. Defaults to `path: "."`; invalid patterns/options and discovery failures are explicit. |
| `Process.run(context, executable, args, options \\ [])` | `{:ok, process_result}` or `{:error, reason}` | Starts and awaits one authorized Linux child process. Defaults: 30,000 ms timeout and 1,048,576 bytes per output stream. Check exit status, effect certainty, and cleanup separately. |
| `Process.start(context, executable, args, options \\ [])` | `{:ok, handle}` or `{:error, reason}` | Starts the same command without blocking for completion. Caller owns the handle; owner death cancels the command. Permission, capacity, platform, executable, and option errors propagate. |
| `Process.await(handle, timeout \\ :infinity)` | `{:ok, process_result}` or `{:error, reason}` | Only the handle owner can await; otherwise `:not_process_owner`. Wait expiry returns `:await_timeout` without cancelling or replaying the command. This differs from managed-run `await/3`, which returns `:timeout`. |
| `Process.cancel(handle)` | Observed cancellation result or `{:error, reason}` | Cancels the owned group. Errors include `:not_running` and a map with `reason: :cancellation_unconfirmed`, `effect: :uncertain`, `cleanup: :uncertain`. |
| `Process.capture_identity(os_pid)` | `{:ok, identity}` or `{:error, reason}` | Trusted Port integration helper for Linux start/group/session identity. Invalid input returns `:invalid_process_identity`. Does not grant process authority. |
| `Process.terminate_group(os_pid, identity)` | `:ok` or `{:error, :cleanup_uncertain}` | Terminates an owned session-leader group without signalling a reused PID. Requires the captured matching identity. |
| `Git.status(context, options \\ [])` | `{:ok, status_map}` or `{:error, reason}` | Requires `:git`; real NUL-delimited porcelain entries, clean flag, and process result. |
| `Git.diff(context, options \\ [])` | `{:ok, diff_map}` or `{:error, reason}` | Bounded diff; options `cached:` (staged diff, default `false`), `base:`, `paths:` and `context_lines:` (0–100, default 3). Invalid context returns `:invalid_diff_context`. No external diff/text conversion. |
| `Git.log(context, options \\ [])` | `{:ok, log_map}` or `{:error, reason}` | Bounded actual commit log; `limit:` defaults to 20 and accepts 1–100. Invalid revision/limit or Git failures are explicit. |
| `Git.patch_context(context, options \\ [])` | `{:ok, context_map}` or `{:error, reason}` | Real HEAD identity, status, and bounded patch together; fails if any underlying operation fails. |
| `Git.commit(context, message, options \\ [])` | `{:ok, commit_map}` or `{:error, reason}` | Requires `:git` and `:edit`, explicit approved paths, and sensitive authorization. Does not include unrelated staged work. |
| `Git.create_worktree(context, path, options \\ [])` | `{:ok, worktree_map}` or `{:error, reason}` | Requires mutation permissions; creates a detached worktree at an absent approved path, pinned to a commit. Invalid/existing/unapproved targets are rejected. |
| `Git.remove_worktree(context, path, options \\ [])` | `{:ok, removal_map}` or `{:error, reason}` | Removes only a registered, approved, clean worktree. Dirty targets return `{:dirty_worktree, path}`. |
| `Git.isolate(context, child_id, options \\ [])` | `{:ok, %{workspace: root, repository_root: source_root, context: child_context, ...}}` or `{:error, reason}` | Creates clean pinned isolation for writable children. Rejects invalid isolation IDs/roots and dirty source repositories. |

File failures are maps with at least `reason` and `message`. Reads return `path`, full-file `snapshot`, `bytes`, `bytes_returned`, `encoding`, `binary`, `line_count`, `newline`, `truncated`, and `truncation`. Text reads also return `content`, `start_line`, and `end_line`; binary reads return bounded `base64` with `content: nil`. Edits are `%{old: nonempty_exact_bytes, new: bytes, occurrence: optional_one_based_index}`. Guarded writes require a complete lowercase SHA-256 or `"missing"` for creation.

Process options include `:cwd`, `:env` (nil unsets a child variable), `:timeout`, `:max_output_bytes`, `:kill_grace_ms`, `:on_output`, and `:observer`. Function output callbacks run in the owner during await, not in the cleanup task. Output retention and streaming share the cap; extra bytes are drained. Results preserve stdout/stderr, status, exit status, duration, truncation, effect certainty, and cleanup certainty. Confirmed cleanup does not undo earlier writes. Linux helper executables and OS isolation requirements are in [Tools](../guides/tools.md) and [Security](../guides/security.md).

## Model, prompt, and context-policy helpers

| Function | Returns | Behavior and errors |
|---|---|---|
| `Models.roles()` | List of six role atoms | `:coding`, `:planning`, `:exploration`, `:review`, `:advisor`, `:compaction`. |
| `Models.select(session_options, runtime_config)` | `{:ok, %{role: role, model: resolved, account: ref, source: source, account_source: source}}` or `{:error, reason}` | Precedence: explicit options, retained session selection, approved project config, user config, runtime defaults. Errors include `:invalid_model_config`, `:invalid_role`, `:invalid_model_roles`, `:project_config_must_be_declarative`, `:invalid_account_reference`, and resolution errors. |
| `Models.resolve(input)` | `{:ok, resolved_model_input}` or `{:error, reason}` | Locally resolves native model inputs and configured aliases with `Jido.AI.Models.resolve/1`. Errors: `:invalid_model` or `:credentials_must_come_from_host`. |
| `Models.describe(input)` | `{:ok, LLMDB.Model}` or `{:error, :invalid_model}` | Local capability metadata only, not network model discovery. |
| `Models.account_reference?(value)` | Boolean | Accepts nonempty valid strings, non-boolean/non-nil atoms, integers, or nonempty tuples of valid references. Rejects secret maps and process handles. |
| `Models.granted_tools(context, requested)` | `{:ok, name_to_action_map}` or `{:error, reason}` | Intersects requested tools with the exact registered Actions and permissions. Native normalization errors or `:tool_registry_name_mismatch` are explicit. |
| `Models.credential_options?(value)` | Boolean | Detects forbidden credential fields, including within known nested inference-option containers. |
| `Models.lifecycle_options?(value)` | Boolean | Detects broker lifecycle records that must not be retained as inference options. |
| `Prompt.compose(context, task_metadata, runtime_config)` | `{:ok, text}` or `{:error, reason}` | Composes approved instructions, role/model/tool guidance, and quoted task data. Errors include `:missing_context`, `:invalid_role`, `:invalid_prompt_config`, `:invalid_instructions`, `:invalid_approved_skill`, and `:invalid_task_metadata`. Never evaluates project files. |
| `ContextPolicy.new(options \\ [])` | `{:ok, policy}` or `{:error, reason}` | Accepts direct options or nested `:context_policy`. Invalid policy budgets return `:invalid_context_policy_options`. |
| `ContextPolicy.retain(policy, facts)` | `{:ok, updated_policy}` or `{:error, reason}` | Merges data-only retained facts with explicit unresolved-work replacement. Rejects invalid, nonserializable, or over-budget facts. |
| `ContextPolicy.compact(policy, chronological_messages, options \\ [])` | `{:ok, %{state: policy, messages: projected, compacted: boolean, removed_messages: count}}` or `{:error, reason}` | Preserves tool call/result consistency and retained facts; accepts transient `secrets:`. Invalid messages/evidence, full tool ledger, or unsatisfied context budget fail explicitly. |
| `ContextPolicy.checkpoint(policy)` | Versioned JSON-compatible map | No executable values or process handles. Use instead of serializing the struct. |
| `ContextPolicy.restore(checkpoint)` | `{:ok, policy}` or `{:error, reason}` | Evaluates no content. Invalid data returns `:invalid_context_policy_checkpoint`; incompatible versions return `:unsupported_context_policy_version`. |
| `Redact.sanitize(value, known_secrets \\ [], max_bytes \\ 8_192)` | Sanitized value | Recursive credential-key/known-value redaction, bounded strings/lists, and removal of process handles/functions. Not arbitrary encoded-secret detection. |
| `Redact.secrets(value)` | List of credential-value binaries | Collects known secrets from credential fields for transient redaction; does not resolve credentials. |

Project model overrides require `project_approved: true` or `%{approved: true, config: declarative_map}`. This module does not read repository configuration itself. Account values are opaque references, not tokens. See [Models and accounts](../guides/models-and-accounts.md) and [Configuration](configuration.md).

### ContextPolicy tool identity

| Contract | Behavior |
|---|---|
| Tool payload identity | Version 2 binds call ID/name, decoded arguments, and ordered result content, including non-text parts. JSON-object argument strings and equivalent Jido/ReqLLM text/content representations normalize consistently. |
| Conflicting evidence | Changed arguments/names return `{:tool_call_reused, id}`; changed result content returns `{:tool_evidence_conflict, id}`. Jido/ReqLLM request/event references and message-envelope provenance are not changes to an effect. |

## Plugin on your own Jido agent

Declare the plugin inside native `agent do` and explicitly route the coding tools you expose. For AI agents, add `OhMyJido.Plugin.AgentExtension` to native `extensions:`; it binds selected Actions to the static AI profiles without replacing your domain tools or model policy. Before startup, export `private_diagnostics?/0` returning `true`. Privacy is not retroactive for work performed before that configuration.

```elixir
# Inside agent do:
plugin OhMyJido.Plugin,
  config: %{bundles: [:read_only], context_provider: MyApp.CodingContexts}

# Inside routes do:
route "oh_my_jido.read", OhMyJido.Plugin.Tools.Read
```

| Contract | Returns | Behavior and errors |
|---|---|---|
| `Plugin.ContextProvider.fetch_context(%{agent_module: module, agent_id: id})` | `{:ok, context}` or `{:error, reason}` | Application callback, evaluated inside each coding Action, not during construction/preparation/admission. Return `{:error, :not_bound}` for missing bindings. Resolve authority using native identity, never model/tool parameters. |
| `Plugin.cmd(agent, original_action_or_exact_name, params)` | Native `{:ok, agent, directives}` or `{:error, reason}` | Uses the original agent's Signal route. The selected `oh_my_jido.<name>` route must target that bound Action; otherwise `:explicit_coding_route_required`. Successful coding results live under `agent.state.oh_my_jido_tools`; the reducer preserves domain fields instead of merging arbitrary tool keys at top level. |
| `Plugin.tool_catalog(config \\ %{})` | `{:ok, catalog_entries}` or `{:error, reason}` | Builds the selected bound Actions as a validated native catalog for programmatic profiles. Zero retries, `:unsafe_once` idempotency, and identity-only context projection. Invalid bundle/config/catalog errors are explicit. Does not construct an agent or start work. |

The application retains its model, transport, request transformer, interceptors, coordinator, and native `ask`/`await`/`ask_stream` lifecycle. Request selections may narrow the catalog, never broaden targets or retry policy. Native V3 rejects unsafe AI queries before provider execution: `ask/3` and `ask_stream/3` return an error without creating a rejected model turn or synthetic request handle. Reused request IDs do not terminate the original stream. Coding errors can use native Jido.Action error envelopes with machine reasons in `details`; do not treat them as plain strings.

Do not configure the old agent option `tool_max_retries`: the V3 extension/catalog supplies the execution policy. Direct native V3 Exec also rejects the old `max_retries` option and does not retry effects.

Context is looked up at execution and never copied into agent/request/checkpoint state. Preparation is configuration-only and starts no model loop or service. This path does not instantiate `CodingAgent` or Runtime. Managed journal/recovery, Goal/Memory/Subagent tools, Eval, and the built-in approval conversation require sessions. Standalone sensitive effects need deliberate host authorization; `Host.Local` approval without a managed session returns `:approval_required`. See [Jido agents](../guides/jido-agents.md).

## Host and authentication contracts

### Host policy

| Callback/function | Returns | Behavior and errors |
|---|---|---|
| `Host.authorize(context, capability, effect, options)` | `:ok`, `{:error, reason}`, or `{:approval, question_map}` | Application policy after the permission check. Callbacks must respect deadlines. |
| `Host.credentials(context, account, options)` | `{:ok, req_llm_options}` or `{:error, reason}` | Resolves credentials on each model request. Account is an opaque reference. Never return lifecycle records as inference options. |
| `Host.invoke(context, capability, request, options)` | `{:ok, result}` or `{:error, reason}` | Dispatches a structured optional-service request to trusted application code. |
| `Host.question(context, question_map, options)` | `{:ok, answer}`, `:pending`, or `{:error, reason}` | Immediate answer or asynchronous UI decision. |
| `Host.call(context, callback, arguments)` | Callback's result | Adds the configured context/options and dispatches directly. Does not add permissions or rescue arbitrary callback errors. |

`Host.Local` is the default implementation:

| Function | Returns | Behavior and errors |
|---|---|---|
| `Host.Local.authorize(context, capability, effect, options)` | `:ok` or `{:approval, question_map}` | Requests approval for `sensitive: true` effects, omitting raw content/source from the question. Otherwise allows the effect after tool permission checks. |
| `Host.Local.credentials(context, account, options)` | `{:ok, req_llm_options}` or `{:error, reason}` | Calls the configured resolver's `resolve(context, account, config)`. Missing account/resolver returns `:credentials_required`; resolver results propagate. |
| `Host.Local.invoke(context, capability, request, options)` | Adapter's result | Uses the Context's adapter binding. Missing services return `{:error, {:capability_unavailable, capability}}`. |
| `Host.Local.question(context, question, options)` | `:pending` | Leaves the question for your application's UI and `answer/3`. |

This is library policy, not an OS sandbox. See [Permissions and approvals](../guides/permissions-and-approvals.md).

### Account broker

| Function | Returns | Behavior and errors |
|---|---|---|
| `Auth.child_spec(options)` | Child specification | Supervisor entry for the explicit broker; needs a vault and task supervisor. |
| `Auth.start_link(options)` | `GenServer.on_start()` | Starts a broker with `store: {vault_module, options}` and a non-nil `task_supervisor:` binding. Vault startup failures return safe `:vault_unavailable`; missing/invalid required bindings return `:invalid_broker_configuration`. Your application must supervise the actual task supervisor. |
| `Auth.begin_login(server, options \\ [])` | `{:ok, %{attempt_ref: ref, authorization_url: url}}` or `{:error, Auth.Error}` | Starts human sign-in without opening a browser/listener. `account_ref:` selects returning-account login. Bounded attempts can return `:auth_busy`; provider/binding errors are typed. |
| `Auth.complete_login(server, attempt_ref, callback)` | `{:ok, safe_account_metadata}` or `{:error, Auth.Error}` | Consumes the attempt once and commits only validated credentials. Invalid, expired, cancelled, or stale attempts fail explicitly. |
| `Auth.cancel_login(server, attempt_ref)` | `:ok` or broker error | Cancels unused/in-flight completion; existing account use is unchanged. Unknown attempts are harmless. |
| `Auth.list_accounts(server)` | `{:ok, metadata_list}` or `{:error, Auth.Error}` | Sorted allowlisted account metadata, never token records or identity tokens. |
| `Auth.credentials(server, account_ref)` | `{:ok, per_request_options}` or `{:error, Auth.Error}` | Privileged boundary with single-flight refresh. Errors include `:unknown_account`, `:logged_out`, `:reauth_required`, `:consent_required`, `:credentials_expired`, `:auth_busy`, and safe provider/vault errors. |
| `Auth.logout(server, account_ref)` | `{:ok, %{local: :logged_out, remote: status, ...}}` or `{:error, Auth.Error}` | Invalidates local use first. Remote status is `:revoked`, `:unconfirmed`, or `:not_requested`; unconfirmed revocation includes a safe error. Local persistence errors are failures. |
| `Auth.resolve(context, account_ref, options)` | Same credential result | Credentials resolver helper; requires `broker:` in options, otherwise safe `:broker_unavailable`. |

`Auth.Vault` callbacks operate on privileged handles/credential records, not public metadata:

| Callback | Returns | Contract |
|---|---|---|
| `init(options)` | `{:ok, handle}` or `{:error, atom}` | Opens application-selected protected storage. |
| `list(handle)` | `{:ok, [account_ref]}` or `{:error, atom}` | Enumerates stored reference strings. |
| `load(handle, account_ref)` | `{:ok, credential_record}` or `{:error, atom}` | Loads a privileged credential record. |
| `put(handle, account_ref, credential_record)` | `:ok` or `{:error, atom}` | Commits the record. |
| `delete(handle, account_ref)` | `:ok` or `{:error, atom}` | Deletes the stored record. |

Low-level OpenAI functions return privileged attempts/records; prefer the broker for one-shot attempts, account generations, and refresh coordination:

| Function | Returns | Behavior and errors |
|---|---|---|
| `Auth.OpenAI.begin_login(options)` | `{:ok, attempt}` or `{:error, Auth.Error}` | Requires explicit application identity/redirect configuration; creates PKCE/state/nonce data and URL. Never opens a browser. |
| `Auth.OpenAI.complete_login(attempt, callback, options \\ [])` | `{:ok, credential_record}` or `{:error, Auth.Error}` | Validates callback/state/issuer/client/identity and exchanges the code. Does not provide broker attempt ownership by itself. |
| `Auth.OpenAI.refresh(record, options \\ [])` | `{:ok, refreshed_record}` or `{:error, Auth.Error}` | Checks host binding and refresh token; explicit network refresh, not inference retry. |
| `Auth.OpenAI.revoke(record, options \\ [])` | `:ok` or `{:error, Auth.Error}` | Explicit remote revocation; may return `:revocation_unavailable` or `:revocation_unconfirmed`. |
| `Auth.Error.new(code, attributes \\ %{})` | Safe `Auth.Error` | Builds a bounded allowlisted diagnostic. |
| `Auth.Error.from_response(status, body, headers \\ %{})` | Safe `Auth.Error` | Classifies HTTP/statusless provider errors without retaining the raw body. |
| `Auth.Error.safe(error)` | Safe `Auth.Error` | Drops arbitrary exception metadata. |
| `Auth.Error.terminal?(error)` | Boolean | Reports `reauth_required`; `retryable` metadata never authorizes replaying an effect. |

### Subscription model profile

`Models.Subscription` is a ReqLLM profile/diagnostic boundary, not another inference client. Credential-bearing options stay inside trusted application code. No subscription error silently switches account or metered billing.

| Function | Returns | Behavior and errors |
|---|---|---|
| `Models.Subscription.provider_id()` | Provider atom | ID used for the narrow native provider profile. |
| `Models.Subscription.register()` | `:ok` or `{:error, Auth.Error}` | Registers through ReqLLM; unsupported streaming boundaries fail explicitly. |
| `Models.Subscription.boundary_supported?(module \\ ReqLLM.Streaming.Failure)` | Boolean | Checks the supported safe streaming-normalization version. |
| `Models.Subscription.options(token)` | `{:ok, credential_options}` or `{:error, Auth.Error}` | Builds explicit OAuth/streaming options with zero retries and payload-free telemetry. Missing token returns `:access_token_missing`. Privileged result. |
| `Models.Subscription.subscription?(options)` | Boolean | Identifies this module's request hook. |
| `Models.Subscription.validate_options(options)` | `:ok` or `{:error, Auth.Error}` | Rejects unsupported explicit inference/HTTP/tool preferences before generic defaults are added. |
| `Models.Subscription.validate_context(context_or_prompt)` | `:ok` or `{:error, Auth.Error}` | Rejects unsupported original media/context rather than allowing encoder omission. |
| `Models.Subscription.configure(model, options, config \\ [])` | `{:ok, {LLMDB.Model, options}}` or `{:error, Auth.Error}` | Validates preferences, registers/selects the profile, and keeps credentials request-scoped. Invalid selections return `:subscription_configuration_invalid` or another typed diagnostic. |
| `Models.Subscription.profile_body(encoded_body)` | `{:ok, shaped_body}` or `{:error, Auth.Error}` | Shapes an already encoded Responses body; unsupported capability fails explicitly. |
| `Models.Subscription.classify_chunk(chunk)` | `:continue`, `:completed`, or `{:error, Auth.Error}` | Classifies decoded terminal stream status without retaining diagnostic text. |
| `Models.Subscription.classify_error(error)` | Safe `Auth.Error` | Projects HTTP/ReqLLM errors. |
| `Models.Subscription.normalize_stream_error(error, model)` | Safe `Auth.Error` or `:cancelled` | Shared safe streamed-error projection for subscription and metered requests; provider identity comes from the selected model. |

See [Models and accounts](../guides/models-and-accounts.md) for broker configuration, API keys, and the separate official Claude Code delegation path.

## Language intelligence and extension contracts

Adapters are trusted application code. They must enforce deadlines, workspace/target scope, result bounds, and cleanup of resources they own. Missing services fail explicitly; the library does not invent an implementation.

| API | Returns | Behavior and errors |
|---|---|---|
| `Intelligence.LSP.child_spec(options)`, `Intelligence.DAP.child_spec(options)`, `Extensions.MCP.child_spec(options)` | Child specification | Explicit supervised stdio service; executable/arguments are application configuration. |
| `Intelligence.LSP.start_link(options)`, `Intelligence.DAP.start_link(options)`, `Extensions.MCP.start_link(options)` | `GenServer.on_start()` | Starts one session/workspace-bound `Intelligence.Stdio` owner using its protocol. Authorization, platform, executable, or startup errors are explicit. |
| `Intelligence.LSP.invoke(context, request, options)`, `Intelligence.DAP.invoke(context, request, options)`, `Extensions.MCP.invoke(context, request, options)` | `{:ok, result_map}` or `{:error, reason}` | Structured protocol operations via configured `server:`. Missing service, invalid operation/scope, protocol timeout, and native server failures propagate. Not unrestricted RPC tools. |
| `Intelligence.LSP.close_session(context, options)`, `Intelligence.DAP.close_session(context, options)`, `Extensions.MCP.close_session(context, options)` | `:ok` or `{:error, reason}` | Requires the matching owner; unconfirmed cleanup is an error. |
| `Extensions.MCP.close(context, options)` | `{:ok, cleanup_map}` or `{:error, reason}` | Explicit close of the bound MCP owner. |
| `Intelligence.AST.execute(context, request)` | `{:ok, result_map}` or `{:error, reason}` | Structural Elixir requests with normal workspace/permission checks. Invalid/unsupported requests fail explicitly. |
| `Intelligence.TextEdits.plan(context, workspace_edit, snapshots)` | `{:ok, plans}` or `{:error, reason}` | Plans bounded edits against current file contents and records the supplied snapshots without applying them. |
| `Intelligence.TextEdits.apply(context, plans, document_versions \\ %{})` | `{:ok, results}` or `{:error, reason}` | Applies only after version/snapshot preflight. Rejects missing snapshots with `:lsp_snapshot_required` and stale snapshots with `:stale_snapshot`; conflicts and partial failures remain explicit. |
| `Intelligence.TextEdits.transform(source, edits)` | `{:ok, transformed_text}` or `{:error, reason}` | Pure guarded text transformation; rejects excessive, invalid, or overlapping edits. |
| `Intelligence.TextEdits.uri(context, path)` | `{:ok, file_uri}` or `{:error, reason}` | Converts a confined existing path. |
| `Intelligence.TextEdits.uri_path(context, uri)` | `{:ok, path}` or `{:error, reason}` | Accepts confined local file URIs, not arbitrary URI schemes/hosts. Rejections use `:lsp_uri_not_granted` or path errors. |
| `Intelligence.Observer.invoke(context, request, options)` | `{:ok, snapshot}` or `{:error, reason}` | Headless read-only OTP observations. Requires `:observe` and trusted `target: :local` or a node atom; only configured supervisor roots are traversable. Remote targets must already provide the collector. Target failures include `:observer_timeout`, `:observer_target_unavailable`, and `:observer_target_failed`. |
| `Extensions.Tidewave.invoke(context, request, options)` | `{:ok, result}` or `{:error, reason}` | Binding over the existing MCP owner, not an evaluator. Requires trusted `server:`, loopback `port:`, and explicit `tools:` allowlist. Every call uses `:mcp`; calls other than `get_logs` also require `:live_eval` and sensitive target-bound authorization, including docs/source lookups. |
| `Extensions.Tidewave.close_session(context, options)` | `:ok` or `{:error, reason}` | Closes only the bound session owner, including after permissions are revoked; invalid binding/cleanup errors remain explicit. |
| `Extensions.close_session(context)` | `:ok` or `{:error, failures}` | Invokes optional configured adapter cleanup hooks at teardown; reports each capability's failure. |

Observer starts no GUI, distribution, cookie, or evaluator. Tidewave points at an explicitly approved external application, not the library VM or isolated Eval. Docs/source lookups may allocate atoms and load modules, so they are not exempt from its live permission/approval boundary. See [Language intelligence](../guides/language-intelligence.md) and [Live applications](../guides/live-applications.md).

### Stdio owner

| Function | Returns | Behavior and errors |
|---|---|---|
| `Intelligence.Stdio.start_link(options)` | `GenServer.on_start()` | Starts a linked owner with `context:`, `protocol:`, and trusted executable configuration. Invalid context/protocol/platform/startup fails explicitly. |
| `Intelligence.Stdio.start(options)` | `GenServer.on_start()` | Unlinked monitored owner for a finite, explicitly invoked integration check. Same checks as linked startup. |
| `Intelligence.Stdio.bind(server, context)` | `{:ok, identity}` or `{:error, reason}` | Requires the exact session/workspace binding. |
| `Intelligence.Stdio.request(server, command, params, timeout \\ 10_000)` | `{:ok, response}` or `{:error, reason}` | Bounded protocol request/reply. |
| `Intelligence.Stdio.begin_request(server, command, params, timeout \\ 300_000, max_id_bytes \\ :infinity)` | `{:ok, request_id}` or `{:error, reason}` | Begins a pending request with its own expiry and optional request-ID byte budget. Supports arities 3, 4, and 5. |
| `Intelligence.Stdio.await_response(server, request_id, timeout \\ 10_000)` | `{:ok, response}` or `{:error, reason}` | Waits for the identified response; does not issue another request. |
| `Intelligence.Stdio.notify(server, method, params)` | `:ok` or `{:error, reason}` | Sends a protocol notification. |
| `Intelligence.Stdio.await_event(server, name, selector \\ %{}, timeout \\ 10_000)` | `{:ok, event_map}` or `{:error, reason}` | Waits for a matching bounded event; supports arities 2–4. |
| `Intelligence.Stdio.latest_event(server, name, selector \\ %{})` | `{:ok, event_map}` or `{:error, reason}` | Reads a retained matching event without requesting new work. |
| `Intelligence.Stdio.document_version(server, uri, operation, requested \\ nil)` | `{:ok, version}`, `:ok`, or `{:error, reason}` | Tracks `:open`, `:change`, and `:close` versions for owned documents. |
| `Intelligence.Stdio.document_versions(server)` | `{:ok, version_map}` or `{:error, reason}` | Current document version projection. |
| `Intelligence.Stdio.document_sources(server)` | `{:ok, fingerprint_map}` or `{:error, reason}` | Fingerprints of full source text successfully sent to the LSP owner. |
| `Intelligence.Stdio.close(server, context)` | `{:ok, cleanup_map}` or `{:error, reason}` | Closes only the matching session/workspace. |

Common stdio failures include `:protocol_closed`, `:protocol_timeout`, and `{:protocol_owner_unavailable, reason}`, plus binding/request-specific errors. No unrestricted command, executable, or target comes from model parameters.

### Browser, research, artifacts, and review

Each behaviour below defines `invoke(context, request, options) :: {:ok, map} | {:error, reason}` and optional `close_session(context, options) :: :ok | {:error, reason}`. The result/error is adapter-specific within the validated contract.

| Behaviour | Request/result contract |
|---|---|
| `Extensions.Browser` | Operations `:navigate`, `:snapshot`, `:click`, `:fill`, `:close`; bounded `timeout_ms`/`max_output_bytes` and operation-specific URL/page/selector/value fields. Navigation returns a real opaque `page_id`; close must confirm `closed: true`. The adapter owns origin/redirect/download/popup scope and page cleanup. |
| `Extensions.Research` | Operations `:search` and `:read` with deadlines/output caps. Search returns `%{results: [%{url: url, title: title, snippet: text}]}`; read returns `%{url: url, title: title, content: text}`. Optional `truncated: true` preserves incomplete results. Every request is a sensitive external effect. |
| `Extensions.Artifact` | Operations `:inspect` and `:read_text` with a confined path, relative path, kind, size, and input/output caps. Recheck confinement at actual open. Local reading does not permit upload or code execution. `Extensions.Artifact.Local` handles UTF-8, PNG/GIF header dimensions, and binary identity without executing content; other decoders must be supplied explicitly. |
| `Extensions.Review` | Captures actual workspace Git changes (`:diff`) and optional approved enrichment (`:review`); never accepts model-supplied diff evidence. Native diff needs `:review` plus `:git`. Enrichment is a separate sensitive external effect; findings are untrusted hints tied to changed paths/lines, not proof of exploitability or complete security. |

Human-invoked integration helpers also keep normal permissions and approvals:

| Function | Returns | Requirements/errors |
|---|---|---|
| `Intelligence.LSP.smoke(context, server_options, path, position)` | `{:ok, observations}` or `{:error, reason}` | Real supplied server and navigation; normal sensitive smoke authorization and server errors. |
| `Intelligence.DAP.smoke(context, server_options, plan)` | `{:ok, observations}` or `{:error, reason}` | Real supplied debugger with breakpoint/step/variable plan; authorization/protocol errors remain explicit. |
| `Extensions.MCP.smoke(context, server_options, plan)` | `{:ok, observations}` or `{:error, reason}` | Real scoped tool/resource plan, not automatic discovery of new authority. |
| `Extensions.Browser.smoke(context, url, expected_content, options \\ [])` | `{:ok, observations}` or `{:error, reason}` | Requires `human_initiated: true`, a configured browser, and expected nonempty content; navigates, observes, and closes. |
| `Extensions.Research.smoke(context, query, expected_url, expected_content, options \\ [])` | `{:ok, observations}` or `{:error, reason}` | Requires `human_initiated: true`; checks actual search/read content. |
| `Extensions.Artifact.smoke(context, path, options \\ [])` | `{:ok, %{observed: true, artifact: result}}` or `{:error, reason}` | Requires `human_initiated: true`; opens a real confined file. |
| `Extensions.Review.smoke(context, options \\ [])` | Native review result | Requires `human_initiated: true`; uses actual workspace changes. |

Helpers with the `human_initiated` option return `:human_initiated_required` when absent; missing expected content is an error, not a simulated observation. See [Integrations](../guides/integrations.md) for exact operation schemas and adapter configuration.

## Eval server and backend contracts

Configure Eval backends explicitly; none is enabled by default. Direct APIs use language atoms `:elixir`, `:javascript`, and `:python`; the model-facing Action uses string enums. Elixir runs in a separate ERTS, JavaScript uses QuickBEAM, and Python uses Snakepit-managed workers. This is separate from the agent/model loop.

| Function | Returns | Behavior and errors |
|---|---|---|
| `Eval.start_link(options \\ [])` | `Supervisor.on_start()` | Starts a supervised manager/kernel tree, not a language kernel until opened. Startup/backend configuration errors are explicit. |
| `Eval.open(server, context, language, options \\ [])` | `{:ok, kernel_info}` or `{:error, reason}` | Requires `:eval`; opens/reuses a configured kernel for the session/language. Does not compare workspaces or set per-cell budgets. Errors include `{:backend_unavailable, language}`, `:kernel_limit`, or kernel invalidation. |
| `Eval.execute(server, context, language, source, options \\ [])` | `{:ok, result_record}` or `{:error, reason}` | Requires `:eval`; runs one cell with `timeout:`, `output_limit:`, and optional `cell_id:`. Check `status`, `effects`, and `kernel_state` even on a success tuple. Errors include `:invalid_eval_request`, `:kernel_busy`, `:session_mismatch` for a different workspace, and `{:kernel_invalidated, reason}`. |
| `Eval.interrupt(server, session_id, language)` | `:ok` or `{:error, reason}` | Interrupts current execution if busy; otherwise no-op for an open kernel. Unknown kernels return `:not_open`. |
| `Eval.interrupt(server, session_id, language, execution_id)` | `:ok` or `{:error, reason}` | Interrupts only the matching execution; stale IDs return `:stale_execution`. |
| `Eval.reset(server, context_or_session_id, language)` | `{:ok, kernel_info}` or `{:error, reason}` | Explicitly discards retained state and increments generation. Context is needed when a lost controller cannot supply it. Errors include `:not_open`, `:reset_context_required`, and `:session_mismatch`. |
| `Eval.close(server, session_id, language)` | `:ok` or manager error | Closes the session/language kernel and removes its retained entry. |
| `Eval.close_session(server, session_id)` | `:ok` or manager error | Closes every language kernel for that session. |
| `Eval.info(server, session_id, language)` | `{:ok, kernel_info}` or `{:error, reason}` | Reports transient `controller`, `worker`, generation, status, reason, and last use. Unknown kernels return `:not_open`. A live invalidated kernel returns `{:ok, info}` with `status: :invalidated` and its `reason`. A lost controller returns `{:kernel_invalidated, reason}`. |

Direct open/reset/info results contain PIDs; the model-facing Action removes them. Execution defaults are 30,000 ms and 65,536 output bytes, with configured maxima. A language-level error can be `{:ok, %{status: :error, ...}}`; timeout/crash/cancellation can invalidate the kernel and make effects uncertain. No cell or callback effect is automatically retried. Once retained state is invalidated, explicitly reset or close before using it again. Elixir/JavaScript need an explicit trusted-code or application-supplied OS-isolation mode; a separate runtime is not an OS sandbox.

| `Eval.Backend` callback | Returns | Responsibility |
|---|---|---|
| `open(context, options)` | `{:ok, handle}` or `{:error, reason}` | Opens an explicitly configured, crash-separated kernel. |
| `execute(handle, request)` | `{:ok, result_map}` or `{:error, reason}` | Executes the identified generation with source, deadline, and output bounds. |
| `interrupt(handle, execution_id_or_nil)` | `:ok` or `{:error, reason}` | Stops matching work and reports unconfirmed cleanup as an error. |
| `reset(handle)` | `{:ok, new_handle}` or `{:error, reason}` | Discards retained language state. |
| `close(handle)` | `:ok` or `{:error, reason}` | Releases backend-owned resources. |

See [Eval](../guides/eval.md) for backends, injected APIs, result fields, output limits, and isolation.

## Source installer API

The source installer edits only dependency declarations in the consumer's `mix.exs`. It uses Igniter/Rewrite, not a runtime agent. Bootstrap from the consumer directory:

```sh
elixir /checkout/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
elixir /checkout/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes
```

| Function | Returns | Behavior and errors |
|---|---|---|
| `OhMyJido.Install.new()` | Empty `Igniter` plan | No evaluation of target configuration. These APIs are available when Igniter is loaded by the bootstrap/tooling environment. |
| `OhMyJido.Install.plan(igniter, options)` | Updated `Igniter` plan | Requires `source:`; optional boolean `snakepit:` defaults false. No files written. Invalid source/options, computed dependency layouts, or conflicting declarations become native plan issues. |
| `OhMyJido.Install.run(argv, default_source \\ nil)` | `{:ok, native_result_atom}` or `{:error, message}` | Preview by default (`:dry_run_with_changes`/`:dry_run_with_no_changes`); applies only with `--apply --yes`. Refuses unknown/repeated/contradictory arguments and plans with issues. |

The standalone `elixir` bootstrap does not evaluate the target Mix project, formatter, Igniter, or application configuration. It may fetch its pinned installer tooling but never resolves/compiles the consumer or starts its services. The optional `mix oh_my_jido.install --source /checkout --dry-run` task is for an already-resolved dependency graph and necessarily performs ordinary Mix project/configuration loading first.

Discovery uses literal AST matching, not alias/macro/environment expansion. It requires a literal `project/0` result with `deps: deps()` and a literal private `deps/0` list. Preview prints Igniter's plain diff without interaction; apply starts Rewrite tooling only. On this branch it adds vendored native Jido V3 Core, Jido.AI, Jido.Action, and patched ReqLLM paths, plus compatible pinned Jido.Signal and Zoi source revisions; `--snakepit` adds optional Python Eval support. Neither entrypoint configures a runtime, permissions, credentials, external services, or OS prerequisites. Resolve and compile your consumer separately after reviewing/applying the change. See [Getting started](../getting-started.md).

## Common errors

These are representative machine-readable reasons, not an exhaustive list of every native dependency failure. Reasons may be direct error values or appear in a structured map/native exception's `details`.

| Reason/code | Meaning | What to do |
|---|---|---|
| `:runtime_unavailable`, `:session_unavailable` | Named runtime/coordinator is not available. | Check supervision; resume the stored session when appropriate. |
| `:session_exists` | This identity is already supervised. | Reuse its reference; do not use start as reset. |
| `:invalid_session_id`, `:invalid_prompt` | Input violates the documented byte/type bound. | Correct the input before retrying admission. |
| `{:conflicting_options, [:bundles, :tools]}` | Both availability selectors were supplied. | Choose bundles or an explicit tool list. |
| `{:invalid_context, field, reason}` | Standalone context configuration is invalid. | Correct the named trusted configuration field. |
| `:busy`, `:run_active` | Operation requires no active run. | Await/cancel the existing run before changing idle-only state. |
| `:suspended`, `:not_suspended` | Control operation does not match session state. | Use `resume/1` only after suspension; it permits a new prompt. |
| `:session_stopped` | Admission is sealed for stopping/uncertain cleanup. | Reconcile cleanup; do not submit more effects. |
| `:unknown_run`, `:run_not_active`, `:unknown_question` | ID does not identify the required active/pending operation. | Refresh your application state; never guess IDs. |
| `:timeout` | Caller/coordinator wait expired. | Inspect/await the existing operation; a wait timeout does not cancel it. |
| `{:capacity, kind}` | Runtime/session history/resource budget was reached. | Wait for owned work to settle or adjust the relevant explicit limit. |
| `{:unknown_tool, name}`, `:tool_escalation` | Tool is unavailable or a request tried to broaden its selection. | Register/select permitted Actions in application configuration. |
| `{:permission_denied, capability}` | Required permission is absent. | Decide explicitly whether the session should receive it; availability is not permission. |
| `:approval_required`, `:approval_denied` | No managed approval conversation, or consent was refused. | Supply deliberate application authorization or use a managed session/UI. |
| `:credentials_required`, `:credentials_must_come_from_host` | Resolver/account missing, or credentials were passed through task/model input. | Resolve credentials per request in trusted application code. |
| `:invalid_model`, `:invalid_account_reference` | Model metadata or opaque account selection is invalid. | Fix model/role/account configuration, not credentials in task text. |
| `:outside_workspace` | Path would escape the workspace or its canonical root changed. | Use an allowed workspace-relative path; do not widen roots from model input. |
| `:stale_snapshot`, `:concurrent_change` | File changed since the supplied full snapshot. | Read current bytes and reconsider the edit instead of forcing it. |
| `:verification_required`, `:unverified_effect`, `:unfinished_plan` | Explicit goal gate lacks eligible checks or done plan items. | Supply actual successful shell effect IDs and finish the plan. |
| `:effect_recording_failed` | Effect returned but durable recording could not be confirmed. | Preserve nested result/ID and reconcile; do not execute again. |
| `:experiment_retention_failed`, `:experiment_notification_failed` | Trials ran but their memory/event recording failed. | Preserve the returned complete experiment record; do not rerun it. |
| `:cleanup_uncertain` | Owned work/resources did not provide confirmed settlement. | Keep the sealed session and reconcile actual resources; process death is insufficient. |
| `:execution_not_quiescent`, `:reconciliation_mismatch` | Operator reconciliation is unsafe or its original ID set is stale/incomplete. | Independently settle resources and use the exact eligible restore-time set. |
| `{:capability_unavailable, capability}` | Required adapter/service binding is absent. | Configure the real service explicitly or leave the tool unavailable. |
| `{:backend_unavailable, language}`, `{:kernel_invalidated, reason}` | Eval backend absent or retained state lost. | Configure the backend; explicitly reset/close invalidated state. |
| `Auth.Error` with `reauth_required: true` | Selected account needs human sign-in. | Start a deliberate login; do not switch accounts or billing automatically. |

## Related

- [Configuration reference](configuration.md)
- [Running tasks](../guides/running-tasks.md)
- [Sessions and recovery](../guides/sessions-and-recovery.md)
- [Tools](../guides/tools.md)
- [Models and accounts](../guides/models-and-accounts.md)
- [Jido agents](../guides/jido-agents.md)
- [Security](../guides/security.md)
