# Acceptance and verification

A test validates a public behavior, not a private implementation detail.
Prefer stable behavior tests and scripted model fixtures over upstream byte-level differential tests.

Current core quality, independent consumers, interrupted-recovery and density/schema results are retained in the [source-bound core record](evidence/core-reconciliation-20261020.json) and [progress ledger](PROGRESS.md). The earlier [462-case library record](evidence/library-acceptance-20261019.json) is historical, not acceptance of later CMS/native-preview work. Human scope decisions in [INDEX](INDEX.md#scope-change) narrowly authorize the private-editor Linux keeper; they do not waive generic host, provider coding, quality, density or the added CMS runtime gates.

## Required test layers

| Layer | Scope | Evidence |
|---|---|---|
| Unit | Tool validation, path policy, model roles, prompt composition, state transitions | Focused ExUnit results |
| Component | Jido agent turns with scripted model and host callback fixtures | Real Jido runtime traces |
| Integration | Git, filesystem, shell, LSP, DAP, Eval backends, MCP, browser | Actual adapter operations |
| Fault | Worker crash, cancellation, timeout, partial result, restart | Recovery and no duplicate effects |
| Host | Independent plain Mix application | Host-owned lifecycle and tool authority |
| Live opt-in | Authorized subscription accounts and external services | Explicit, redacted smoke-test report |
| Performance | Multiple concurrent agent and tool populations | Memory, latency, queue and error measurements |

## Behavioral scenarios

### T1: real code repair

Create a disposable Mix project with a failing test and a narrow defect.
Ask an embedded agent to repair the defect without changing unrelated behavior.
Assert that a Jido model loop calls real tools and produces a targeted diff.
Run the project's tests and record their exit result.
Assert that the host receives progress and completion events.

### T2: edit correctness

Test concurrent edits against the same file snapshot.
Reject a stale edit before it overwrites another writer's changes.
Cover Unicode, CRLF, empty files, binary detection, and file permission errors.
Assert that the edit tool reports a precise conflict instead of silent overwrite.

### T3: workspace boundaries

Grant one workspace root to an agent.
Attempt traversal, sibling-prefix escapes, symlink escapes, and absolute paths outside the grant.
Reject unauthorized access and report it without leaking path contents.
Assert that the host VM's working directory and environment remain unchanged.

### T4: interruption and uncertain effects

Start an effectful tool and cancel its parent run while it executes.
Verify that cancellation reaches the child process and releases resources.
Distinguish confirmed cancellation from uncertain effect completion.
Do not replay uncertain effects merely because a worker disappears.

### T5: controlled subagents

Start parallel read-only exploration tasks and one mutating task.
Verify that permissions and workspaces remain separate.
Collect structured results in the parent session.
Cancel one child and verify that the parent remains usable.

### T6: context continuity

Run a scripted long conversation until compaction occurs.
Preserve the user's goal, active constraints, relevant file facts, and unresolved work.
Restart the session process and resume the conversation from persistent state.
Verify that the resumed agent does not repeat completed effects.

### T7: subscription and billing safety

Exercise OAuth states with local authorized mocks: login, refresh, logout, expiry, and revocation.
Attempt a subscription request with an expired or unapproved account.
Return a specific error when the user cannot access the provider.
Assert that the request never silently falls back to a metered API credential.
Assert that session events, logs, and errors never reveal raw tokens.

### T8: three-language Eval

Run two consecutive Elixir cells with retained binding state inside a separate ERTS.
Run two JavaScript cells with retained state inside a QuickBEAM Eval context.
Run two Python cells with retained state inside a Snakepit worker.
Exercise one authorized host tool call and one denied tool call per backend.
Verify that each backend handles cancellation, output limits, errors, and cleanup.
Crash an isolated Eval worker and verify that the host application remains alive.

### T9: advanced coding tools

Exercise an actual AST search and targeted transformation on a fixture repository.
Exercise LSP diagnostics and symbol navigation with a supported language server.
Exercise a debugger breakpoint, step, variable lookup, and session teardown.
Use fake adapters for baseline tests and real servers for optional smoke tests.
The configured native Elixir rename alternative must prove cross-file symbol identity, default-arity/multiclause and import/capture handling, scoped bindings, destination conflicts, immutable preview and snapshot/version-guarded publication. Native package success without complete supported-source evidence is not a passing rename.
Corroborate the native server's source buffers with actual confined text before trusting semantic locations; unchanged version counters alone do not prove freshness after same-length disk edits.

### T11: process density

Measure 1, 10, 100, and 500 idle supervised sessions on a documented host.
Measure bounded active sessions with realistic scripted tool and model latency.
Record resident memory, process count, p50/p95/p99 latency, and queue pressure.
Keep resource limits explicit and record the point of saturation.
Treat unmeasured performance improvements as hypotheses, not delivered claims.

### T12: headless live Observer

Observe an actual running OTP application using the public Action, locally and on an explicitly configured separate node.
Read bounded system/application/process/supervision/ETS metadata; preserve private state, queued messages, process dictionaries and table contents.
Prove independent grants, confined supervision roots, limits/truncation, disappeared targets and owned fixture cleanup.
Do not start wxWidgets, distribution, alter cookies or inject code as part of an Observer request.
Return native collection failures as tagged failures without exiting the caller; process pagination must use bounded native iteration rather than a full process-list copy.

### T13: live runtime escape hatch

Use real runtime tools against an owned live application, not a mock catalog or isolated Eval kernel.
Read exact installed documentation, source locations and an actual app log challenge.
Reject target overrides, missing grants and unapproved evaluation or runtime-loading source lookups before target effects. Native docs/source must not create atoms or execute`@on_load` without the additional runtime authority.
With explicit approval, evaluate fixed code and invoke native RPC against actual app state in a distinct target VM.
Preserve transport/tool error and uncertain-effect envelopes; never retry or automatically escalate.
Confirm owned client/target cleanup; do not attach to a real user app without approval.

## Quality gates

- `mix compile --warnings-as-errors` succeeds.
- `mix format --check-formatted` succeeds.
- `mix test` succeeds without credentials or network access.
- Static analysis passes if the project enables Credo and Dialyzer in its Mix configuration.
- No production code imports Oh My Pi TypeScript or requires a Bun runtime.
- No test uses an always-success stub as evidence of the actual capability.
- All secrets remain absent from fixture snapshots, logs, and normal event streams.
- Native code and Eval workers keep failures within documented isolation boundaries.
- Public examples compile against the implemented API.
- Required capability rows cite direct current-revision evidence in `PROGRESS.md`.

## Completion report

Report the exact commit and test commands for the completed build.
Include verified capabilities, live provider checks, external blockers, and benchmark results.
State unavailable optional host backends explicitly.
Do not call an unverified provider integration complete.
