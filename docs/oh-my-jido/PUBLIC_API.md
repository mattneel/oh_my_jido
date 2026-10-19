# Public API reference

The source facade is [`OhMyJido`](../../lib/oh_my_jido.ex). Choose ordinary managed sessions, native plugin attachment to your own Jido agent, or individual `Jido.Action` tools. Managed sessions use a named host-supervised runtime and `%OhMyJido.SessionRef{}`; standalone contexts/tools do not create that runtime or claim its journal/recovery features. Modules/functions marked `@doc false` remain implementation details.

Default optional arguments below are keyword lists `[]` unless stated otherwise. Times are milliseconds. Tool and native dependency errors may be tagged tuples, maps or safe exceptions; match the relevant status/code instead of assuming every failure is a string.

## Types

| Type | Fields and ownership |
|---|---|
| `OhMyJido.SessionRef.t()` | `%SessionRef{runtime: host_atom, id: binary}`; durable identity, not a PID |
| `OhMyJido.Event.t()` | `%Event{session_id: binary, run_id: binary_or_nil, seq: nonnegative_integer, kind: atom, at_ms: integer, payload: map}`; delivered as `{:oh_my_jido, event}` |
| `OhMyJido.Context.t()` | Required `session_id`, canonical `workspace`, `permissions: MapSet`; also `run_id`, `runtime`, `coordinator`, opaque `account`, `model`, `role`, `host`, `tools`, `adapters`, `limits`, `metadata`; trusted host/action context, not a model request schema |
| `OhMyJido.Process.Handle.t()` | Opaque caller-owned native handle from `Process.start/4`; contains process/monitor identities and callbacks; never persist it |
| `OhMyJido.Auth.Error.t()` | Safe `code`, `provider`, optional HTTP status/request ID/retry-after/eligibility/quota, `retryable`, `reauth_required`; no raw HTTP body, token or callback |
| `OhMyJido.ContextPolicy.t()` | Versioned retained facts, bounded excerpts, pending/completed tool evidence and summary digest; serialize with `checkpoint/1`, not by inspecting the struct |
| `OhMyJido.Eval.Backend.handle()` / `request()` | Native backend handle map; execution request has binary `id`/`source`, positive `timeout`/`output_limit`/`generation`; backend handles are transient |

`Context.fetch/1` accepts a Context or `%{oh_my_jido: context}`. `Context.permitted?/2` checks an existing atom grant. Neither function establishes authority from repository/model text.

## Tool composition without a coding runtime

| Call | Result and authority |
|---|---|
| `Tools.bundles()` | Fixed named availability map: `:read_only`, `:editing`, `:elixir`, `:process`, `:live_inspection` |
| `Tools.select(bundle_or_list)` | `{:ok, action_modules}` or structured selection error; stable deduplication in caller order, empty list supported |
| `Tools.select!(bundle_or_list)` | Same selection as a list, or actionable `ArgumentError` at host configuration time |
| `Context.new(options)` | `{:ok, Context}` or `{:error, {:invalid_context, field, reason}}`; existing workspace required, grants default empty |
| `Context.new!(options)` | Same constructor, raising on invalid configuration |

Context construction defaults to read-only tool availability, **not** read permission. Explicit `:tools` replaces bundle selection; specifying both `:tools` and `:bundles` is rejected. A supplied `:session_id` is retained or a native Jido ID is generated. Host/adapter callback bindings are checked, not invoked; no credentials, applications, language servers, distribution or processes are started by the constructor.

Execute a selected Action through `Jido.Exec.run(action, params, %{oh_my_jido: context}, max_retries: 0)`. Its real root/grant/host checks still apply. This direct path is not the managed session effect journal, approval conversation or durable recovery boundary. `Tools.default/0` remains the complete registry, not the recommended blanket grant or an optional-service installer.

## Native plugin on your own agent

Attach `OhMyJido.Plugin` through the native `plugins:` option. Its configuration selects `bundles:` and a trusted `context_provider:` module implementing `OhMyJido.Plugin.ContextProvider.fetch_context/1`. The provider receives native `agent_module`/`agent_id` identity and returns `{:ok, Context}` or an explicit error. Resolve a stable per-agent workspace, grants, host policy and service bindings there; never accept those bindings from model text or tool parameters.

Mount is configuration-only. Bundle-bound native Actions resolve context at execution rather than copying authority into native agent/request/checkpoint state. Existing application state, genuine domain tools and native model/transformer policy remain host-owned. A native Jido.AI consumer must explicitly implement `private_diagnostics?/0` returning `true` and configure `tool_max_retries: 0`; attaching a plugin is not permission to change global diagnostics or retry effects.

`Plugin.cmd(agent, original_action_or_exact_name, params)` returns the caller's native `{agent, directives}` result, or an explicit preflight error. Native Direct instruction failures are error directives/signals, not necessarily an `{:error, reason}` reply from `AgentServer.call/3`; inspect the real outcome. Successful Direct Actions merge result fields into native agent state in the usual way.

Rejected AI queries retain native bounded request insertion, stream ownership and completion. A rejecting native request transformer fails before provider/tool calls; errors carry the native `{:failed, :error, {:request_transformer, reason}}` envelope. Stream consumers may receive native lifecycle/checkpoint events before terminal `:request_failed`, not a synthetic one-event stream. Use native `ask`/`await`/`ask_stream` for AI tasks.

This integration does not instantiate `CodingAgent`, Runtime or another model loop. Managed session journals, recovery, goal/subagent coordination and the built-in approval conversation require the Runtime/session path. For direct plugin effects, provide deliberate host authorization; availability still does not grant an Action or install external services.

## Source installation tooling

`OhMyJido.Install.new/0` creates an empty native Igniter plan without evaluating target configuration. `plan/2` accepts that plan and explicit `source:`/optional boolean `snakepit:`; refusal becomes native plan issues. `run/2` defaults to preview and only applies with `--apply --yes`.

Use `elixir /checkout/priv/oh_my_jido/install.exs --dry-run` from the consumer directory for the no-target-evaluation bootstrap; then explicitly apply and separately resolve/compile the consumer. The optional native `mix oh_my_jido.install --source /checkout --dry-run` task is for an already-resolved graph and necessarily follows ordinary Mix target loading. Neither entrypoint configures Runtime, grants, credentials or optional service provisioning.

Discovery is literal AST matching, not environment-aware alias/macro expansion. Preview renders native Igniter's plain diff noninteractively; controlled apply starts native Rewrite tooling only, never consumer application services.

## Runtime and session lifecycle

| Call | Result and behavior |
|---|---|
| `OhMyJido.child_spec(options)` | Public `{OhMyJido, name: MyApp.Coding}` supervisor entrypoint; named runtime, no implicit session |
| `OhMyJido.start_link(options)` | Starts the same named Runtime directly; ordinary Supervisor result |
| `Runtime.child_spec(options)` | Ordinary Supervisor child; `name` is required and is the child ID |
| `Runtime.start_link(options)` | `{:ok, pid}` or Supervisor error; no session/request starts implicitly |
| `OhMyJido.start_session(runtime, options)` | `{:ok, SessionRef}` or error; existing rooted workspace required; optional `id` 1–128 bytes; grants default empty |
| `OhMyJido.resume_session(runtime, id)` | Fetches the configured `Jido.Storage` checkpoint and restores without replay; errors for unavailable/unsupported state |
| `OhMyJido.list_sessions(runtime)` | Sorted list of currently supervised references, not an enumeration of all stored checkpoints |
| `OhMyJido.inspect_session(session)` | `{:ok, snapshot}` or error; redacted **host-only** inspection, including an intentional transient `agent_pid` |
| `OhMyJido.checkpoint(session)` | `:ok` only while no run is active; otherwise `{:error, :run_active}` |
| `OhMyJido.stop_session(session)` | Stops owned session resources, preserves durable state; not archive deletion or effect rollback |

`start_session/2` with an ID already present in storage uses that checkpoint; it is not a reset/override of a stored session. Starting an already supervised identity returns `:session_exists`. A new workspace/policy needs a new identity or an explicitly managed host storage migration.

An inspection contains `id`, `status`, `active_run`, `agent_pid`, `workspace`, `permissions`, `role`, `account`, `model`, `conversation`, `goal`, `plan`, `retained`, `effects`, `runs`, `children`, `pending_questions` and `seq`. Do not send the whole map to a public UI or telemetry exporter. It includes private workspace/conversation evidence, and its native PID is not JSON or a durable handle. Project a host-approved view.

The ETS default only persists as long as its table/host remains available. For host restart use `{Jido.Storage.File, path: host_path}` or another actual `Jido.Storage` adapter. Restored policy/capability bindings come from the runtime; see [configuration](RUNTIME_CONFIGURATION.md#session-options-and-restore).

## Task execution and control

| Call | Result and behavior |
|---|---|
| `prompt(session, task, options \\ [])` | `{:ok, binary_run_id}` or error; task admission requires a binary of 1–65,536 bytes; native text/transport validity still applies; one active native request per session |
| `await(session, run, options \\ [])` | `{:ok, completed_record}` or `{:error, record_or_reason}`; `timeout: 30_000` default; a caller timeout does not cancel |
| `steer(session, run, text)` | Queues native ReAct pending input and retains the constraint; `:ok` or error |
| `cancel(session, run)` | Requests cancellation/prevents new effects for the run; `:ok` means request accepted, not rollback |
| `suspend(session, run)` | Cancels this run with suspended status; a new prompt remains blocked until `resume/1` |
| `resume(session)` | Unblocks a suspended session for a new task; `:not_suspended` otherwise; does not continue the cancelled request |
| `answer(session, question_id, answer)` | Resolves one waiting structured question; `:unknown_question` for expired/resolved requests |

A terminal run record carries `id`, `status`, `query`, `started_at`, `completed_at`, `answer`, `error`, `usage` and `tools`. Tool summaries identify actual journal records with `id`, `name`, `status` and times. Success is specifically `status: :completed`; other terminal statuses include `:failed`, `:cancelled`, `:suspended`, `:timed_out`, `:interrupted`. A completed model request can coexist with tool errors: check the effect's result and actual verification evidence.

Common admission/control errors are `:busy`, `:suspended`, `:invalid_prompt`, `:unknown_run`, `:await_timeout`, `:run_not_active`, `:tool_escalation`, `:credentials_must_come_from_host`, and `{:capacity, kind}`. Model-boundary account/credential failures can occur after `prompt/3` returns a run ID; obtain the terminal result rather than treating admission as inference success.

Task options select role/model/account, narrow registered tools and supply approved native inference preferences; [configuration](RUNTIME_CONFIGURATION.md#six-native-model-roles-and-account-selection) lists the forwarded fields. There is no public per-task replacement of host policy, credentials or the transformer.

## Events

| Call | Result and behavior |
|---|---|
| `subscribe(session, pid, options \\ [])` | `:ok` or error; `max_pending` defaults to runtime `subscriber_limit`; re-subscribing an existing PID is idempotent |
| `events(session, options \\ [])` | List of retained events whose `seq > after`; `after: 0` default; error if the session is unavailable |

Subscription receives future events; it is not an automatic historical replay. `events/2` is bounded by `event_limit`, so an old cursor can miss overwritten records. Sequence numbers survive durable coordinator restart. A dead or over-bound subscriber is detached; its entire process mailbox, not just library messages, is counted. The API has no separate unsubscribe call or guaranteed lossless external event log. Persist a permitted UI projection in the host if needed.

Native kinds projected into the host envelope include `:request_started`, `:llm_started`, `:llm_delta`, `:llm_completed`, `:tool_started`, `:tool_completed`, output-validation kinds, `:checkpoint`, `:request_completed`, `:request_failed`, `:request_cancelled`, `:input_injected` and `:keepalive`. Harness kinds include `:run_started`, `:run_completed`, `:approval_requested`, `:approval_answered`, `:checkpoint_saved`, `:session_resumed`, `:plan_updated`, `:goal_completed`, `:tool_registered`, `:tool_unregistered`, `:subagent_started`, `:subagent_completed`, `:experiment_completed`, `:process_output`, `:eval_output` and cleanup/worker-fault events.

An approval request has `payload: %{id: question_id, question: map}`. The same channel handles clarification and effect consent. An approval answer event contains the safe answer. For streaming output inspect the kind/payload; model and process fragments are redacted/bounded and need not preserve the provider's wire chunk boundaries. Treat all model/repository output as data.

## Memory, plans, goals and experiments

| Call | Result and behavior |
|---|---|
| `retain(session, facts)` | `:ok` or error; known keys are `goal`, `constraints`, `file_facts`, `memory`, `unresolved_work` |
| `plan(session, items)` | Validates/replaces the plan without discarding any prior item, renaming an item or reopening completed work |
| `complete_goal(session, evidence)` | `:ok` only for a nonempty all-done plan and actual eligible check effects |
| `experiment(session, trials, options \\ [])` | `{:ok, record}` or error; explicit bounded `%{tool: name, params: map}` trials run sequentially once; default tool timeout 30,000 |

`file_facts` and `memory` are maps with binary keys and data-only values. Constraints are merged/deduplicated; explicitly provided unresolved work **replaces** the prior list. A successfully admitted `goal` updates the authoritative session goal, including JSON/string-keyed Memory Action facts; facts without a goal preserve the current goal. Retention can fail rather than lose mandatory facts.

Plan items have binary `id`, binary `title`, `status` in `:pending | :in_progress | :blocked | :done`, and an optional `reason`. At most 100 items and one `:in_progress` item are allowed. `:blocked` requires a nonempty reason.

Completion evidence is **`%{effect_ids: [binary_id, ...]}`**, not a self-declared `checks: [%{passed: true}]`. Each ID must resolve to a completed `"shell"` journal entry with a real exited process, exit status 0 and `effect: :completed`. This validates observed process outcomes, not that an arbitrary successful command is a sufficient test of your requirement. The host/task must choose meaningful checks. Native `run_completed`/task `status: :completed` means a model run returned; it does not invoke this gate or imply a verified goal. Only explicit successful goal completion emits `:goal_completed`. Library task completion is unrelated to the project's full delivery gates.

Experiments require `:experiments` and each underlying tool's grants/authorization. The default trial bound is 8. Results retain actual duration in microseconds, status/result, artifact references, exact safe `receipt`, `receipt_error` and effect certainty in memory under `"experiment:" <> id`. `{:ok, record}` can have `record.status == :failed`; do not equate the outer tuple with every trial succeeding.

If retention or notification fails **after trials execute**, the public experiment API returns `{:error, %{reason: reason, cause: cause, effect: certainty, experiment: complete_record}}`. Reasons are `:experiment_retention_failed` or `:experiment_notification_failed`. Preserve that returned record; the effects already happened and must not be retried merely to recover a lost memory/event entry. An Experiment Action failure uses the native Jido error envelope, with these fields under `details`.

Trusted host callers may pass `effect_id: binary_id` to `execute_tool/4` to correlate a known operation with its receipt. Reusing a recorded ID is rejected before execution. This is an execution option, not a model-visible tool parameter or permission grant; ordinary calls keep generated native IDs.

If execution returns but result sanitation/journal persistence loses the coordinator, `execute_tool/4` returns `{:error, %{reason: :effect_recording_failed, cause: cause, effect: :uncertain, effect_id: id, result: sanitized_native_result}}`. The nested result preserves observed outcomes, including an Experiment's complete trial record; the outer error means durable bookkeeping could not be confirmed. Reconcile rather than execute again. Opaque receipt IDs and child tags are dictionary identities, not credential field names; record contents still receive credential sanitation.

## Tools and child tasks

| Call | Result and behavior |
|---|---|
| `register_tool(session, action_module)` | Host-authored `Jido.Action` registration; idle session only |
| `unregister_tool(session, exact_name)` | Removes future native tool exposure; idle session only |
| `execute_tool(session, exact_name, params, options \\ [])` | Runs a registered Action through `Jido.Exec`, host authorization and effect recording; default timeout is the session tool budget; zero automatic effect retries |
| `delegate(session, task, options \\ [])` | `{:ok, %{tag: tag, session: child_ref, run: run_id, workspace: root, role: role}}` or error |
| `await_child(session, tag, options \\ [])` | Child run result; caller timeout does not cancel it |
| `steer_child(session, tag, text)` | Steers the tracked active child run |
| `cancel_child(session, tag)` | Cancels child work without cancelling the parent |

Tool names are exact binaries, not input-derived atoms. Built-in Actions declare a capability and authorize at each effect boundary. Host Actions without `capability/0` require `:custom`. Declaring `capability/0` is not an implementation of authorization: the Action must call `Tool.authorize/3` or a native library operation that does so. See [custom tools and delegation](TOOLS_AND_EXTENSIONS.md).

Child options include `tag`, `role` (default `:exploration`), `writable` (default false), a narrowed `permissions` list, an approved isolated `workspace`, and native prompt preferences `llm_opts`, `req_http_options`, `max_iterations`. `:delegate` is removed from child grants. Account is inherited; child role uses configured native selection. Writable work requires a granted distinct workspace or a real clean detached Git worktree, not a sibling writing directly to the parent's root.

## Direct native tool APIs

For trusted integrations that already possess a Context, these functions expose the same operation boundaries. Prefer `execute_tool/4` or native agent Actions when session journaling is required; merely calling a low-level operation with a hand-built Context does not create a session journal.

| Module | Documented operations |
|---|---|
| `Workspace` | `new(root)`, `resolve(context, path, options \\ [])`, `relative(context, path)`; canonical existing root; `allow_missing: true` only for explicitly permitted missing targets |
| `Files` | `read(context, path, options \\ [])`, `write(context, path, content, snapshot, options \\ [])`, `edit(context, path, snapshot, edits, options \\ [])`, `snapshot(bytes)` |
| `Search` | `files(context, path \\ ".", options \\ [])`, `text(context, pattern, options \\ [])`; bounded relative paths, explicit skipped/truncation flags |
| `Process` | `run(context, executable, args, options \\ [])`, `start(...)`, owner-only `await(handle, timeout \\ :infinity)`, `cancel(handle)`; trusted Port integrations also have `capture_identity(pid)` and `terminate_group(pid, identity)` |
| `Git` | `status(context, options)`, `diff`, `log`, `patch_context`; `commit(context, message, options)`, `create_worktree(context, path, options)`, `remove_worktree(context, path, options)`, `isolate(context, child_id, options)`; options default `[]` |
| `Tool` | `authorize(context, capability, effect \\ %{})`, `find(context, name)`, `execute(context, name, params, options \\ [])` |
| `Tools` | `default()` returns the implemented native Action registry, not a grant |
| `Models` | `roles()`, `select(session_options, runtime_config)`, `resolve(input)`, `describe(input)`, `account_reference?(value)`, `granted_tools(context, requested)`; credential/lifecycle field detection helpers reject unsafe request configuration |
| `Prompt` | `compose(context, task_metadata, runtime_config)` returns `{:ok, text}` or error; approved runtime instructions only |
| `ContextPolicy` | `new(options \\ [])`, `retain(policy, facts)`, `compact(policy, chronological_messages, options \\ [])`, `checkpoint(policy)`, `restore(checkpoint)` |
| `Redact` | `sanitize(value, known_secrets \\ [], max_bytes \\ 8_192)`, `secrets(value)`; bounded value/key redaction, not arbitrary encoded-secret detection |

File APIs return `{:ok, map}` or `{:error, %{reason: reason, message: text, ...}}`. A read reports complete-file SHA-256 identity, total/returned bytes, encoding/binary status and truncation; text reads additionally report original one-based inclusive line boundaries and newline style. A binary read supplies bounded base64 with `content: nil`; a binary line range is rejected. Guarded writes require a complete lowercase SHA-256 or `"missing"` for creation. Edits use `%{old: nonempty_exact_bytes, new: bytes, occurrence: optional_one_based_index}` against one original snapshot. Other tools' results and additional requirements are detailed in [tools and extensions](TOOLS_AND_EXTENSIONS.md).

## Host, auth, extension and Eval contracts

`OhMyJido.Host` callbacks are:

```elixir
authorize(context, capability, effect, options)
# :ok | {:error, reason} | {:approval, question_map}
credentials(context, opaque_account, options)
# {:ok, explicit_req_llm_options} | {:error, reason}
invoke(context, capability, request, options)
# {:ok, result} | {:error, reason}
question(context, question_map, options)
# {:ok, answer} | :pending | {:error, reason}
```

`Host.call/3` dispatches to the configured host; `Host.Local` is the reference implementation. Hosts are trusted code and must respect authority, deadlines and resource ownership. `Auth.Vault` has `init/1`, `list/1`, `load/2`, `put/3`, `delete/2`; vault handles/records are privileged, unlike the metadata returned by `Auth.list_accounts/1`.

`Auth.start_link/1`/`child_spec/1`, `begin_login/1,2`, `complete_login/3`, `cancel_login/2`, `list_accounts/1`, `credentials/2`, `logout/2`, and the host resolver `resolve/3` are documented in [account operations](ACCOUNT_OPERATIONS.md). `Auth.OpenAI.begin_login/1`, `complete_login/2,3`, `refresh/1,2`, `revoke/1,2` are low-level privileged auth operations; use the broker for one-shot attempts, account generations and single-flight refresh.

`Models.Subscription` exposes `provider_id/0`, `register/0`, `boundary_supported?/0,1`, `options/1`, `subscription?/1`, `validate_options/1`, `validate_context/1`, `configure/2,3`, `profile_body/1`, `classify_chunk/1`, `classify_error/1`, `normalize_stream_error/2`. These are native profile/diagnostic seams, not another inference client; tokens returned by `options/1` stay inside the privileged host credential boundary. `Auth.Error.new/1,2`, `from_response/2,3`, `safe/1`, `terminal?/1` construct/project typed safe errors; `retryable` is metadata, not permission to replay an effect.

Reference `Intelligence.LSP`, `Intelligence.DAP` and `Extensions.MCP` implement `start_link/1`, `child_spec/1`, `invoke/3`, `close_session/2` with one session-bound `Intelligence.Stdio` owner. `Intelligence.AST.execute/2` handles structural requests. `Intelligence.TextEdits.plan/3`, `apply/2`, `transform/2`, `uri/2`, `uri_path/2` handle guarded LSP edits. Stdio offers `start_link/1`, finite-smoke `start/1`, `bind/2`, `request/3,4`, `begin_request/3,4`, `await_response/2,3`, `notify/3`, `await_event/2,3,4`, `latest_event/2,3`, `document_version/3,4`, `close/2`. These trusted native seams are not unrestricted RPC tools for models.

Browser, artifact, research and review adapters implement `invoke(context, request, options)` with optional `close_session/2`; the library does not fabricate an implementation for an unconfigured service. Their exact requests/results, scoped MCP lists, and human-invoked `smoke` helpers are in [tools and extensions](TOOLS_AND_EXTENSIONS.md). The `Extensions.close_session/1` hook invokes configured cleanup callbacks at session teardown.

`Intelligence.Observer.invoke(context, request, options)` is the stateless headless native OTP adapter for `Tools.Observer`; trusted `target: :local | node_atom` and approved `supervisors` belong to host configuration. It does not create a GUI, distribution, cookie or evaluator. Grant `:observe` separately and use bounded structured operations; remote targets must already provide the fixed collector module. See [live Observer](TOOLS_AND_EXTENSIONS.md#headless-live-observer).

`Extensions.Tidewave.invoke(context, request, options)` and `close_session/2` are a thin trusted-target binding over the existing MCP owner. Configure `server`, loopback `port` and an explicit `tools` allowlist; use the existing MCP Action, not a new evaluator. Only logs avoid extra`:live_eval` authority: native docs/source lookups can allocate atoms/load modules and require the same targeted approval boundary. See [live application tools](TOOLS_AND_EXTENSIONS.md#tidewave-style-live-application-tools).



`Eval.start_link(options \\ [])` creates a supervised manager. For a trusted host-managed standalone Eval server: `open(server, context, language, options \\ [])`, `execute(server, context, language, source, options \\ [])`, `interrupt(server, session_id, language)` or `/4` with execution ID, `reset(server, context_or_session_id, language)`, `close(server, session_id, language)`, `close_session(server, session_id)`, `info(server, session_id, language)`. Language values here are existing atoms, unlike the Action's string enum. `open/4` does not set per-cell budgets; execute options do. Direct `info`/open/reset results contain transient worker/controller PIDs; the model-facing Eval Action removes them. See [Eval operations](EVAL_OPERATIONS.md) for results and limits.
