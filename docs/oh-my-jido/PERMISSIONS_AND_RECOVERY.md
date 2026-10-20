# Permissions, questions and recovery

## Threat model and ownership

The model proposes operations; **the host is the authority**. Repository text, skills, tool outputs, web pages, MCP announcements and model answers cannot grant permissions, choose credentials, change billing or approve deployment. Runtime/host configuration, trusted Action implementations and adapters are privileged code.

The library protects explicit workspace paths, Action authorization, bounded admission/output and durable effect ownership. It does **not** supply an OS sandbox or prove that all native/custom services are private. A BEAM process is not a security boundary for arbitrary Elixir; a separate ERTS is crash separation, not filesystem/network confinement. A dirty-scheduler NIF is not crash isolation. Shells, candidate builds, language/debug servers, native image decoders and Python imports can execute arbitrary code under their OS identity.

Before granting execution over untrusted input, the host must supply its actual OS policy: unprivileged identity, permitted mount roots, egress restrictions, secret separation, process-tree/cgroup limits and appropriate memory/CPU/device constraints. A working directory and a tool byte quota are not those controls. A model prompt saying “stay in the workspace” is not an enforcement mechanism.

Protect four separate stores/surfaces:

- **Session storage:** private conversation, file/effect evidence and retained task facts. Native `Jido.Persistence.File` is not an encrypted vault.
- **Credential vault:** broker-only encrypted/protected records and stable host-owned key; not part of a repository or an image generation.
- **Native process state:** host-only handles, callbacks and request credentials; not a public UI payload.
- **UI/telemetry/logs:** permit only necessary redacted metadata. Do not export whole inspections, raw native state, callback URLs or credential options.

Known-key/value redaction is a defense, not arbitrary secret discovery. Unknown strings, encoded values, arbitrary custom fields and external program diagnostics need separate host policy. Use the supported pinned native diagnostics and preserve explicit failures rather than suppressing logs globally.

## Grants and host authorization

A session starts with **no permissions**. Registering a tool or binding an adapter does not grant its capability. Native model exposure intersects registered Actions, capability grants and the model's advertised tool support. Actions still authorize at their actual effect boundary.

| Grant | Intended boundary |
|---|---|
| `:read` | Read/list/search; read operations used by AST/LSP may also require this |
| `:edit` | Guarded file mutations; independently required by Git mutation, structural replacement and rename application |
| `:exec` | Arbitrary approved executables; not needed for the fixed Git adapter's inspection commands |
| `:git` | Fixed Git workflows; no remote/push/history rewrite API |
| `:ast`, `:lsp`, `:debug` | Structural operations and configured language/debug services |
| `:observe` | Bounded headless metadata from an explicitly configured live OTP target; no process state/messages/dictionaries, application env or ETS contents |
| `:delegate` | Bounded child task creation/control |
| `:planning`, `:memory`, `:experiments`, `:ask`, `:skills` | Task workflows, explicit retained facts, bounded tool trials, questions and skill guidance |
| `:mcp`, `:browser`, `:research`, `:artifact`, `:review` | Optional approved host service surfaces |
| `:eval` | Configured persistent language execution; injected tools also need their own grants |
| `:live_eval` | Additional live runtime loading/execution authority on a trusted MCP target, with sensitive digest approval; required for native Tidewave docs/source as well as last-resort code/RPC because lookup can create atoms/run`@on_load`. Independent of isolated `:eval`, not a sandbox |
| `:claude_code` | Separate official-agent delegation, plus grants for its enabled official tools |
| `:custom` | Host Action without `capability/0`; not permission for an arbitrary MFA/RPC supplied by the model |

Host-specific Actions can use additional fixed capabilities such as the Elixos example's `:candidate` and `:deploy`. Those are not core OS permissions granted by a prompt.

`Tool.authorize(context, capability, effect)` first checks the grant, then calls `Host.authorize/4`. Responses are `:ok`, a denial or `{:approval, question_map}`. The reference `Host.Local` asks when an effect declares `sensitive: true`; otherwise a granted effect is allowed. It does **not** parse every command into a danger class. In particular, granting Shell under Local is significant OS authority. Use a host policy that approves every shell/Eval/custom effect or enforces a suitable command/sandbox policy when that is required; [the embedding guide](USER_GUIDE.md#implement-a-stricter-host-policy) has a real callback example.

Source-marked sensitive effects include commits/staging, applied LSP rename, debugger launch, MCP tool calls, browser navigation/click/fill, research requests, optional external review enrichment and official Claude subprocess delegation. The host can require more approvals. A shell can perform the same effects unless its OS/host policy constrains it.

## Structured questions and human consent

Both clarification and effect approval emit:

```elixir
{:oh_my_jido,
 %OhMyJido.Event{
   kind: :approval_requested,
   payload: %{id: question_id, question: question_map}
 }}
```

`Host.question/3` can return `{:ok, answer}`, `:pending` or an error. With `:pending`, the UI uses `OhMyJido.answer(session, question_id, answer)` after a human response. Keep the session/event handler responsive; the effect waits in its supervised worker, not in the UI.

For effect consent, only `true`, `:approve` or `"approve"` grants approval. Other values deny; a default, omitted answer, timeout, dismissal or late response is not consent. Clarification questions can carry options and `multi`; their answers are data, not a new grant. Question defaults are 8 pending requests and 300,000 ms. Capacity/host/deadline failure stops the waiting operation. Run termination rejects its questions, and an already answered/expired ID returns `:unknown_question`.

Do not implement an “approve every event” consumer. Render only an authorized projection of effect details and obtain the required human decision. Credentials never belong in question text, shell arguments or a UI log. The Elixos adapter uses its own actual Ask queue and strict boolean consent; do not assume core answer spellings override that host's policy.

## Files, processes and external effects

Workspace paths are canonicalized with traversal/symlink checks and root rechecks. Guarded file edits use whole-byte snapshots, preserve unrelated text/newline bytes and refuse stale/overlapping/ambiguous targets. In-process writers serialize by canonical path. External writers are rechecked, **not locked**; an adversarial OS race needs a stronger host filesystem boundary.

Process launches have an explicit executable/argument vector, workspace cwd and child-only environment overrides. The host VM cwd/environment is not changed per session. Linux `setsid`/procfs identity and group cleanup guard against signaling a reused PID. Confirmed cleanup means no live member of the owned group remains; deliberate daemonization/group escape still needs a host sandbox/cgroup. Bytes written or network calls made before a kill are not undone.

Git uses fixed operations and disables hooks, external diffs/text conversion, signing, fsmonitor and ambient Git override variables for each child. That is not proof that malicious repository configuration or any command granted through Shell cannot perform external effects. No Git publishing/force/history-rewriting operation is supplied by the Git Action.

External adapters must enforce session ownership, deadlines, allowed origins/redirects/resources and actual cleanup. A claimed successful close without real cleanup is rejected where the contract can observe it. The core cannot make an unsafe native host API support page isolation, OS confinement or rollback by renaming its result.

## Durable effects and uncertainty: no automatic replay

Each tool call through the native agent interceptor or public `execute_tool/4` has a durable intent written **before** the Action runs. Journal entries record call ID, run ID, tool name, argument hash, status and times; outcomes retain a redacted bounded result.

`status: :completed` in this journal means a terminal result was recorded, **not** that the result was successful. Examine the stored `{:ok, ...}`/`{:error, ...}` result and operation-specific evidence. An approval denial or a known failed command is a recorded terminal outcome. An effect that disappears while `:running` becomes `:uncertain` on interruption/recovery.

Cancellation prevents new effects for the run and requests cleanup of owned processes/Eval resources. `cancel/2` returning `:ok` is request admission. `await/3` yields the observed terminal record; cancellation, suspension, deadline and worker failure are not successful task answers. `cleanup: :confirmed` and `effect: :uncertain` can both be true: a process stopped, but its past effects cannot be inferred away.

`stop_session/1` additionally seals the session and waits for settlement before terminating its actor. Native V3 ownership follows validated Exec scope ancestry and its owning outer effect, not public run-ID equality. Request retirement alone cannot settle a nested Action; all matching live scopes must close through real worker-supervisor shutdown. Conversely, an unrelated host Write with that run ID remains pending until its own real receipt. Missing proof returns cleanup uncertainty and retains the sealed actor. Scope depth/live/history retention is bounded by existing resource/effect limits; capacity rejection occurs before target dispatch, while an earlier durable attempt may remain recorded. No historical effect is rolled back or replayed.

No uncertain non-idempotent tool effect, Eval cell, experiment trial or restored request is automatically retried. CodingAgent and `Tool.execute/4` set native tool retries to zero. The subscription profile also sets request retries to zero. Native transport/auth diagnostic retryability is not a blanket promise about every provider or permission to replay a tool; the host must select/assess its inference policy explicitly.

Post-effect coordinator/storage failure returns an explicit `:effect_recording_failed` error containing the sanitized native result and correlation ID. Preserve that nested evidence even when durable recording cannot be confirmed. Experiment retention/notification failures likewise carry the complete measured trial record rather than invite repetition. Opaque receipt/child identities are sanitized as dictionary values, not mistaken for credential field names; sensitive fields inside their records still lose credential contents.

Delegated tags remain coordinator-reserved until the original result collector finishes, even after native Jido has removed a dead child's binding. Completion must match that exact child session and run. A delayed old result cannot finalize a replacement child or release its admission lease.

Recovery workflow:

1. Obtain the terminal result and inspect the **host-only** `effects`, `runs`, retained facts and pending/unresolved work.
2. Independently observe the actual repository/process/external system state within approved authority.
3. Preserve the uncertain record. Record the observation separately; do not overwrite uncertainty with an assumption or feed the old effect back into a retry loop.
4. Stop using an unsafe resource until the host reconciles cleanup/ownership.
5. Submit a new scoped task only after reconciliation, carrying constraints and observed facts. A suspended session first needs `resume/1`.

Explicit checkpoints reject active model runs. Finish direct tool calls before requesting a safe checkpoint. Durable restore reads native `Jido.Persistence` versioned bytes/CAS state, recorded root/grants/identity and current trusted service bindings. Active runs become interrupted, running effects become uncertain, and no old question/process/PID is revived. V2 `Jido.Storage` data is not automatically converted.

## ContextPolicy version 2

The current checkpoint version is **2**. The outer session checkpoint remains its separate version-1 envelope; do not confuse that envelope with the nested ContextPolicy version.

The policy is extractive, not another model summarizer. It retains goal, constraints, file facts, explicit memory and unresolved work separately from bounded transcript excerpts. Recent messages, system guidance, the latest user turn, pending calls and successfully loaded lower-authority skill guidance are protected. Keeping a call/result protects the **complete parallel exchange**, including delayed results. Completed tools become continuity evidence, never work to execute again.

Version 2 binds immutable tool payload identity: call ID/name, decoded arguments and ordered result content, including non-text content parts. JSON-object argument strings normalize to their decoded data; equivalent native text/content-part defaults normalize consistently. Native request/event references and message-envelope provenance are not semantic changes to an effect. Meaningful argument/result changes remain conflicts (`:tool_call_reused`, `:tool_evidence_conflict`); orphan/duplicate calls/results and name mismatches fail explicitly.

The summary contains quoted low-authority retained facts/excerpts and pending/completed evidence. It does not become host instructions. Tool evidence contains digests and bounded result excerpts, not every byte of discarded repository content. `max_messages` triggers compaction; protected exchanges may exceed it. The projected byte budget, retained-fact budget and tool-record budget still apply. Mandatory content that cannot fit produces `:context_budget_exceeded`, `:retained_context_too_large` or `:context_tool_ledger_full`, not silent loss or invented success.

The data-only policy API can round-trip through JSON:

```elixir
{:ok, policy} = OhMyJido.ContextPolicy.new()
{:ok, policy} =
  OhMyJido.ContextPolicy.retain(policy,
    goal: "Repair the public increment behavior",
    constraints: ["Preserve the label API"],
    unresolved_work: ["Run the agreed project checks"]
  )

checkpoint = OhMyJido.ContextPolicy.checkpoint(policy)
{:ok, encoded} = Jason.encode(checkpoint)
{:ok, decoded} = Jason.decode(encoded)
{:ok, restored_policy} = OhMyJido.ContextPolicy.restore(decoded)
```

For actual transcript projection, pass the chronological native Jido/ReqLLM messages to `compact/2,3`; success returns `%{state: policy, messages: projected, compacted: boolean, removed_messages: count}`. Do not fabricate tool exchanges as migration evidence.

### Clean cutover from version 1

`restore/1` returns `{:error, :unsupported_context_policy_version}` for old version-1 policies. Their whole-envelope digests cannot safely reconstruct version-2 payload identity, so there is no compatibility shim or version-number-only migration. Preserve the historical checkpoint as private evidence, reconcile any interrupted/uncertain effects, then create a new identity and retain approved task facts. Never relabel an old tool ledger or silently discard it to make restoration appear successful.

## Native diagnostic snapshots

This checkout includes narrowly modified native source snapshots, not a replacement agent runtime/transport and not a published fork/release claim:

| Snapshot | Original source manifest digest |
|---|---|
| Jido 2.4.0, [`vendor/jido/UPSTREAM.json`](../../vendor/jido/UPSTREAM.json) | `snapshot_sha256`: `d850dbd74d849d3deb1c7a9f8d6a130dbb7d1bc99a05ee0aabc8f81c3ff1e75c` |
| ReqLLM 1.28.0, [`vendor/req_llm/UPSTREAM.json`](../../vendor/req_llm/UPSTREAM.json) | `unmodifiedSnapshotDigest`: `be792b0751392cff0b9bf1098fb42cb4daddb84ac94a9ad06a4f4d43a10d4850` |
| Snakepit 0.14.0, [`vendor/snakepit/UPSTREAM.json`](../../vendor/snakepit/UPSTREAM.json) | `snapshot_sha256`: `aaa434dfb28d83f97b84606d9f0632a4a963fc42a11cdbe20f88227be82c0bf0` |

These values and the manifests' per-file hashes/lengths identify the **unmodified original upstream snapshot**. They are not hashes of today's patched files or loaded BEAMs. Keep the [Jido](../../vendor/jido/LICENSE) and [ReqLLM](../../vendor/req_llm/LICENSE) Apache-2.0 licenses and the [Snakepit](../../vendor/snakepit/LICENSE) MIT license, copyright notices, modified-source notices and manifest update descriptions. Build/runtime evidence has its own source/loaded-BEAM fingerprints; Snakepit also records a separate complete patched-source digest.

Jido's private diagnostic opt-in keeps opted-in AgentServer status/callback failures and directive telemetry metadata-only, including inherited native ReAct workers. It catches private callback failures before OTP can append original arguments/queued messages to its ordinary report, returns safe shutdown reasons and preserves normal non-private native behavior. This is not logger suppression or recovery that falsely continues a failed effect.

ReqLLM's supported failure normalization runs before native HTTP/stream diagnostics materialize, covers the supported native streaming transports/hooks, and binds safe errors to the actual selected model. Production turns force telemetry payloads to `:none`; native debug must be disabled before credentials are obtained. Runtime requires Jido private diagnostic version 1; model/subscription admission checks the ReqLLM normalization-version-1 boundary. Stock dependencies without those boundaries are not an acceptable drop-in for these documented credentials/privacy contracts.

Durable native checkpoints are sanitized as structured state: inference option sets and process callbacks/handles are cleared, known credentials redacted, and signed continuation tokens removed from their typed native checkpoint fields/events. A signed token can encode recoverable private state even when it is not visibly a token string. This is why preserving ordinary native event/thread data verbatim is unsafe. The parent integration owns regression verification; this guide makes no complete privacy/release gate claim.

Python Eval additionally requires the licensed Snakepit private-diagnostics boundary, opted in through trusted native worker configuration. Supported SDK requests/completions and callback states use opaque native envelopes, keeping worker configuration, source and private request values out of native status, callback-failure reports and OTP sys-debug history. Actual worker-exit and streaming callback regressions verify that boundary without suppressing logs or replaying effects. Arbitrary raw BEAM messages and host-VM introspection remain trusted administrative access, not credential isolation. Do not supply provider credentials to Eval workers. Current observations and limitations are in [operations](OPERATIONS_AND_EVIDENCE.md).
