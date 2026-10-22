# Keep sessions and recover interrupted work

Use durable sessions to preserve a coding task's conversation, progress, and tool-call records across worker or application restarts. Restoration rebuilds a session; it does not restart old processes or repeat interrupted work.

## Before you start

- Open sessions through a named, supervised runtime as described in [getting started](../getting-started.md) and [running tasks](running-tasks.md).
- Keep the runtime name, session ID, and storage configuration available across application restarts.
- Protect session storage as private application data. It contains conversation, workspace evidence, and retained task facts. A File adapter is not an encrypted credential vault; see [security](security.md) and [operations](../operations.md).

## Choose storage that survives your application

The default ETS adapter survives a session worker restart while its table remains available. It does not survive the lifetime of the BEAM instance. For application restart recovery, configure durable storage in your supervision tree:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   storage: {Jido.Persistence.File, path: "/srv/my_app/coding_sessions"}}
]
```

Use an application-owned storage directory, separate from the agent's workspace. Recreate the same named runtime with the same storage location after a restart. Configure model credentials and service adapters there again if the restored task needs them.

| Storage | Use |
|---|---|
| Default `Jido.Persistence.ETS` | Keep checkpoints across session-worker restarts, not across BEAM lifetimes. The table is specific to the runtime instance. |
| `{Jido.Persistence.File, path: directory}` | Keep checkpoints on disk across application restarts. |
| Application adapter implementing `Jido.Persistence.Adapter` | Use your own durable storage and retention policy. |

On `jido-v3-preview`, storage uses native versioned bytes and compare-and-swap (CAS), which rejects a write when the saved version has changed. Custom adapters implement `Jido.Persistence.Adapter`, including binary values from `get/2` and `compare_and_swap/4`; the storage layer retains the native conditions rather than guessing them. The master branch's Jido 2.4 `Jido.Storage` checkpoints are not automatically converted. Use a separate compatible data directory or an explicit application migration.

The File adapter needs one BEAM instance to own its directory. All callers must use the same path, without alternate symbolic links; do not share it between concurrent BEAM instances.

Storage holds session state, not a backup of the repository or a live process image. Stopping or restoring a session does not undo file changes.

## Checkpoint, stop, and restore

Once the model run and your application's direct tool calls have finished:

```elixir
session_id = session.id

:ok = OhMyJido.checkpoint(session)
:ok = OhMyJido.stop_session(session)

{:ok, restored} = OhMyJido.resume_session(MyApp.Coding, session_id)
{:ok, snapshot} = OhMyJido.inspect_session(restored)
```

The same restore call works after restarting the runtime. `checkpoint/1` rejects an active model run with `{:error, :run_active}`. Finish direct tool calls first too: an idle model run alone is not evidence that every application-owned operation has finished. The session also persists journal intents, outcomes, and progress during normal operation; explicit checkpoints provide a deliberate idle checkpoint of the Jido.AI agent.

A session's durable identity is `%OhMyJido.SessionRef{runtime: runtime_name, id: session_id}`. The optional `id:` accepted by `start_session/2` is a binary of 1–128 bytes. If that ID already has a stored checkpoint, `start_session/2` restores it rather than resetting it with new options. An already supervised identity returns `:session_exists`. Use a new identity for a new workspace or policy, or perform an explicit application-controlled storage migration.

`list_sessions/1` lists currently supervised references in ID order. It does not enumerate all saved checkpoints. `inspect_session/1` is for trusted application code: it includes private task data and an intentional transient `agent_pid`. A PID is not a durable restoration handle, JSON payload, or field to publish through UI or telemetry. Select an approved view instead. The preview also exposes `native_execution` count/limit diagnostics, not reusable execution-scope tokens or process authority.

### What survives restoration

| State | Behavior |
|---|---|
| Identity, workspace, permissions, selected tools | Persisted. The workspace is checked again; restoration does not grant new permissions. |
| Role, model, opaque account, goal | Persisted, including the retained selection from prompts. The account remains a reference; credentials are resolved again when needed. |
| Conversation, plan, retained task facts, ContextPolicy | Persisted. The saved ContextPolicy includes its own options and tool-evidence ledger. |
| Run records, effect journal, child records | Persisted as history, not instructions to restart old work. |
| Bounded event buffer and sequence counter | Persisted. A new subscriber must subscribe again; events overwritten before the checkpoint are not recovered. |
| Jido.AI agent checkpoint | Persisted after sanitation and used to rebuild the agent. Old request credentials and process handles are not restoration authority. |
| Pending questions, waiters, subscriptions, running processes, Eval handles, service PIDs | Not revived. An unanswered old question does not become approval. |
| Per-session host policy and adapters | Not persisted. Rebuilt from the current trusted runtime configuration. |
| Callback functions, per-request options, arbitrary metadata | Not persisted. Reconfigure required service policy in the runtime or an application identity-based resolver. |

The durable session options are `workspace`, `permissions`, `role`, `account`, `model`, `goal`, and `tools`. Bundle selections are resolved to Action modules and saved as `tools`, so a later runtime bundle change does not silently replace a restored session's availability.

Only these session metadata keys are retained: `git_repository_root`, `git_worktree_roots`, `delegation_roots`, `delegation_depth`, `project_instructions`, `skills`, and `skill_roots`. Session metadata overrides same-named runtime metadata when the context is built; session adapters similarly override runtime adapter entries during the live session, but those per-session adapter bindings are transient. Put durable service bindings and limits in runtime configuration. New and restored managed contexts use the same field validation as `OhMyJido.Context.new/1`; invalid permissions, tool modules, or host/service bindings fail instead of creating a partially configured agent.

Retained `metadata.project_instructions` alone does not make text approved prompt guidance. Use the trusted runtime's `project_instructions` and `project_approved` composition path. See [configuration](../reference/configuration.md) for the complete runtime/session option reference.

### What happens to interrupted work

On restoration, a run saved as `:running` becomes `:interrupted` with `error: :worker_restarted`; a running effect becomes `:uncertain`. Ordinary restored sessions become idle, suspended sessions remain suspended, and sessions saved while stopping or cleanup-uncertain remain cleanup-uncertain. No old question, process, PID, or model continuation is revived.

A suspended session needs `OhMyJido.resume/1` before you submit a new task. That operation unblocks new work; `resume_session/2` instead restores a stored identity. Neither operation automatically repeats the interrupted task.

## Stop a session with confirmed cleanup

`OhMyJido.stop_session/1` stops accepting work, cancels the active task, and waits up to five seconds for commands, subagents and services to shut down.

| Result | What your application can conclude |
|---|---|
| `:ok` | The owned execution and registered resources stopped, and the exact session child was terminated. Earlier writes are not rolled back; stored history is not deleted. |
| `{:error, %{reason: :cleanup_uncertain} = details}` | Cleanup could not be confirmed. The session stays supervised, rejects new work and can still receive cleanup confirmations. Inspect `pending_effects`, `pending_resources`, and `native` (Jido worker shutdown) in the returned details. |
| `{:error, :session_unavailable}` | The session cannot be reached. Its absence alone does not prove that external effects or resources stopped. |

An accepted `cancel/2`, worker/controller death, or caller exit does not prove cleanup. Inspect the actual owned resources through trusted application operations. Late cleanup confirmations can resolve uncertainty; retry shutdown after that reconciliation, not the tool call. Keep any application writer lock or workspace fence closed while that owner's cleanup is uncertain. See the [cleanup and retry reference](#cleanup-and-retry-reference) for V3 execution-scope tracking.

Confirmation covers registered resources and the tracked execution of tool calls. It is not proof about arbitrary escaped OS processes. `cleanup: :confirmed` and `effect: :uncertain` can both be true: execution stopped, but its earlier changes are still unknown. A normal completed Eval operation can also emit `:resource_cleanup`; event consumers should not assume an idle session emits nothing.

## Read the effect journal

An **effect** is one tool call. Managed model tools and public `execute_tool/4` calls write a durable intent before the Action runs. Journal entries identify the call ID, run ID, tool name, argument hash, status, and timestamps. Recorded outcomes include a redacted, bounded result.

```elixir
{:ok, snapshot} = OhMyJido.inspect_session(restored)

uncertain_effects =
  Enum.filter(snapshot.effects, fn {_id, effect} -> effect.status == :uncertain end)
```

Keep this inspection in trusted application code. The journal is useful evidence, not a reason to broadcast the whole snapshot.

| Effect status | Meaning |
|---|---|
| `:running` | Intent was recorded and execution has not yet produced a recorded terminal outcome. |
| `:completed` | A terminal result was recorded. Inspect `result`; it may contain an error, an approval denial, or a failed command. |
| `:uncertain` | Execution or recording was interrupted, timed out, or explicitly reported unknown effects. Some changes may already have happened. Preserve any observed result and cleanup evidence. |

### Never automatically replay uncertain effects

Do not put an uncertain tool call back into a retry queue. The library does not automatically replay uncertain non-idempotent tools, Eval cells, experiment trials, or restored model requests. See the [cleanup and retry reference](#cleanup-and-retry-reference) for tool and model retry settings.

### Handle an unrecorded result

A coordinator or storage failure after execution can return:

```elixir
{:error,
 %{
   reason: :effect_recording_failed,
   cause: cause,
   effect: :uncertain,
   effect_id: effect_id,
   result: sanitized_native_result
 }}
```

The nested `result` preserves what was observed, even though durable bookkeeping could not be confirmed. Save it with the correlation ID and reconcile actual state; do not execute again to obtain a better result record. Trusted callers can supply a unique `effect_id:` to `execute_tool/4`; reusing a recorded ID is rejected before execution. See the [API reference](../reference/api.md#tools-and-child-tasks) for correlation-ID and child-tag sanitation.

[Experiments](running-tasks.md#run-measured-experiments) likewise return the complete trial record when retention or notification fails after execution. Keep that record rather than rerunning trials to recreate a missing memory entry or event.

## Recover after an interruption

1. Obtain the terminal run result when the session is reachable. After a restart, restore the identity and inspect its private `runs`, `effects`, retained facts, and unresolved work.
2. Identify what is known and what is uncertain. A completed model answer, stopped process, or missing worker does not establish whether a write or external request happened.
3. Independently inspect the repository, processes, and external systems using authorized operations. Stop using any resource whose ownership or cleanup is unsafe.
4. Preserve the original uncertain record. Record new observations separately instead of replacing uncertainty with an assumption.
5. Stop or reconcile the original owned workers, OS process groups, and external resources. Where applicable, record the exact operator acknowledgement described below. Keep writer fences until their own cleanup requirements are met.
6. Submit a new scoped task with the observed facts and remaining constraints. If the session is suspended, call `resume/1` first. Do not reuse an old effect as a retry instruction.

## Record explicit operator reconciliation

Sometimes your application can independently establish that the original execution has stopped, while the library still lacks its original [shutdown receipt](#cleanup-and-retry-reference). A trusted operator can record that separate fact with `reconcile_interrupted/4`. It does not establish what the effect did, and it does not replace `stop_session/1`.

After selecting an originally restored interrupted run and independently reconciling its old resources, pass its run ID and complete exact pending effect-ID set from the private inspection:

```elixir
:ok =
  OhMyJido.reconcile_interrupted(
    restored,
    interrupted_run_id,
    expected_effect_ids,
    :orphan_resources_reconciled
  )
```

`expected_effect_ids` is a nonempty exact set for that run, not a wildcard or a subset acknowledgement. Do not populate it with every uncertain effect from unrelated runs.

| Requirement or error | Meaning |
|---|---|
| Idle or suspended restored session | No active run, stopping state, pending question, registered resource, child capacity reservation, live Jido Action execution scope, or cleanup task may remain. |
| `{:error, :execution_not_quiescent}` | The current session still has live execution/ownership work or is not eligible for reconciliation now. |
| `{:error, :reconciliation_mismatch}` | The run is ineligible or the expected IDs are wrong, stale, incomplete, duplicated, already reconciled, or belong to later work. The journal is unchanged. |
| `{:error, :invalid_reconciliation}` | The public acknowledgement or argument shape is invalid. |

The effect stays `status: :uncertain`: the acknowledgement does not create a result or a completion time. It makes no model request and does not continue the interrupted task. The exact recorded fields and late-result rules are in the [cleanup and retry reference](#cleanup-and-retry-reference).

A session that is already stopping or rejecting work after uncertain cleanup is not reopened by this operation. Do not expose the acknowledgement as browser input, a model tool, or an MCP argument.

The [docs-site recovery example](../../examples/docs_site/README.md#reconcile-an-orphaned-source-writer) shows the application's separate writer-ownership and operator-provenance checks.

## Keep context useful with ContextPolicy

`OhMyJido.ContextPolicy` compacts conversation extractively: it selects existing facts and excerpts without asking another model to summarize them. Managed sessions use it automatically. Goal, constraints, file facts, explicit memory, and unresolved work are stored separately from the bounded transcript.

The policy protects system guidance, recent messages, the latest user turn, pending calls, and successfully loaded lower-authority skill guidance. Keeping any call or result keeps its complete parallel exchange, including delayed results. Completed tools become continuity evidence, never instructions to execute again.

For an application that needs the data-only policy directly, checkpoints can round-trip through JSON:

```elixir
{:ok, policy} = OhMyJido.ContextPolicy.new()

{:ok, policy} =
  OhMyJido.ContextPolicy.retain(policy,
    goal: "Repair increment",
    constraints: ["Preserve the public API"],
    unresolved_work: ["Run the agreed project checks"]
  )

checkpoint = OhMyJido.ContextPolicy.checkpoint(policy)
{:ok, encoded} = Jason.encode(checkpoint)
{:ok, decoded} = Jason.decode(encoded)
{:ok, restored_policy} = OhMyJido.ContextPolicy.restore(decoded)
```

To project a transcript directly, pass chronological Jido/ReqLLM messages to `compact/2` or `compact/3`. Success returns `{:ok, %{state: policy, messages: projected, compacted: boolean, removed_messages: count}}`. Checkpoint content is data; restoration does not evaluate it or create atoms from arbitrary keys. Do not invent tool exchanges as migration evidence.

### Budgets and tool identity

| Contract | Behavior |
|---|---|
| `max_messages`, `keep_recent` | Message count triggers compaction; it is not a hard cap that can split a protected exchange. Protected content can exceed the message-count trigger. |
| `max_bytes`, `summary_bytes` | Bound the projected context and archived excerpts. Summaries quote lower-authority facts and excerpts; they do not become application instructions. |
| `max_retained_bytes` | Bounds mandatory retained facts; failure is `:retained_context_too_large`, not silent fact loss. |
| `max_tool_records` | Bounds pending/completed tool-evidence records; failure is `:context_tool_ledger_full`. |
| Mandatory projected content cannot fit | Returns `:context_budget_exceeded` rather than silently truncating an exchange or inventing success. |
| Invalid exchanges | Orphan or duplicate calls/results and tool-name mismatches fail explicitly. |

Tool evidence stores digests and bounded result excerpts, not every byte of discarded repository content. See [configuration](../reference/configuration.md) for ContextPolicy defaults and runtime configuration.

The [ContextPolicy identity reference](../reference/api.md#contextpolicy-tool-identity) explains version-2 payload matching and conflict errors.

### Move from ContextPolicy version 1

The current ContextPolicy checkpoint version is **2**. The outer session checkpoint remains its separate version-1 envelope.

Old version-1 policies return `{:error, :unsupported_context_policy_version}`. Their whole-envelope digests cannot reconstruct version-2 payload identity, so there is no compatibility shim or version-number-only migration. Preserve the historical checkpoint privately, reconcile any interrupted or uncertain effects, then create a new session identity and retain approved task facts. Never relabel the old tool ledger or silently drop it to make restoration appear successful.

## Cleanup and retry reference

| Contract | Behavior |
|---|---|
| Cleanup receipt | A confirmation tied to the original owned resource or execution. An accepted cancellation, a worker/controller exit or a caller exit is not a receipt. |
| Shutdown settlement | `stop_session/1` waits for tracked tool calls, matching resource-cleanup receipts, delegated-child cleanup, Jido worker shutdown and session-service cleanup before terminating the exact session child. The deadline is five seconds. |
| Child-result identity | The result collector reserves the original child tag until it finishes, even if Jido has removed a dead child's binding. A result must match the original child session and run; a delayed result cannot complete a replacement child or release its reserved capacity. See [subagents](subagents.md). |
| Tool retries | Managed Jido.AI tools and `Tool.execute/4` use zero tool retries. V3 `Jido.Exec` never retries tool execution; the managed coding catalog also declares `:unsafe_once` idempotency. |
| Model retries | The subscription account configuration also sets request retries to zero. This is not a guarantee about every provider's transport policy; assess model-request retries separately from tool-effect safety. |
| Operator execution record | `execution_settlement` records `source: :operator`, `execution: :stopped`, `effect: :uncertain`, and `native_stop_confirmed: false`. Existing evidence is preserved; no result, `completed_at` or Jido worker-closure receipt is invented. Late results cannot overwrite this boundary. Reconciliation makes no model request and runs no old continuation; later explicit work still needs its own shutdown confirmations. |
| V3 execution scopes | Stopping requires identity-bound Jido Exec admission and worker-supervisor closure, including nested Experiment trials, separately from Process/Eval cleanup. Each Action's scope tracks its owned supervised workers and validated ancestry. Matching public run IDs is not enough: request retirement cannot settle a nested Action until all matching scopes close through actual worker-supervisor shutdown. An unrelated direct application tool call with the same run ID still needs its own completion receipt. |
| V3 scope limits | Scope depth, live scopes and retained scope history are bounded by the resource/effect limits. Capacity rejection happens before target dispatch, although an earlier durable intent may remain recorded. `inspect_session/1` exposes bounded `native_execution` diagnostics, not credentials or authority to close a scope. |
| V3 actor retirement | The exact idle Jido agent can be retired while the session coordinator remains sealed with unresolved effect, scope or resource records. In that state, inspection can report `agent_pid: nil`; this is not cleanup confirmation. A disappearing caller/coordinator is not a closure receipt; missing receipts keep the session sealed. |

## Limits

- Durability depends on your configured storage, protected data directory, and application retention policy. ETS alone is not application-restart recovery.
- Restoration rebuilds trusted runtime bindings; it does not persist credential resolvers, adapter PIDs, arbitrary metadata, or old process ownership.
- A checkpoint is not a repository rollback, an encrypted vault, or proof that a command had no side effects.
- Cleanup confirmation covers owned registered resources. Permissions and workspace checks are not an OS sandbox; untrusted execution needs an appropriate operating-system boundary.

## Related

- [Running tasks](running-tasks.md)
- [Configuration reference](../reference/configuration.md) and [API reference](../reference/api.md)
- [Security](security.md) and [operations](../operations.md)
- [Subagents](subagents.md) and [Eval](eval.md)
- [Plain Mix restart example](../../examples/plain_mix/README.md)
- [Docs-site recovery example](../../examples/docs_site/README.md)
