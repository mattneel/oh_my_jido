# Run Oh-My-Jido in production

Oh-My-Jido runs inside your Elixir application. Your application supervises the runtime, stores session state, supplies credentials and decides which work is allowed. Use this guide to choose storage, protect private data, monitor work and plan capacity before accepting coding tasks.

## Prepare the application

Supervise a named runtime with a private persistent storage directory and explicit limits:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   storage: {Jido.Persistence.File, path: "/srv/my_app/coding_sessions"},
   max_sessions: 100,
   max_active: 4,
   max_processes: 4,
   max_subagents: 8,
   bundles: [:read_only, :editing]}
]
```

The path and limits above are application-specific choices, not recommended sizing. Create the storage directory with access restricted to the application user before startup. Opening a runtime starts no session or model request. Tool bundles control availability, not permissions; each session starts with no permissions unless you supply them.

Before accepting work:

- Bind each session to an existing workspace and grant only the permissions it needs. Use an OS user, container, cgroups and network policy appropriate for code you do not trust. Library permissions are not an OS sandbox.
- Configure the credential resolver and approval UI outside the model. Keep vault keys and tokens out of repositories, command arguments, model inputs and build images.
- Keep ReqLLM debug logging disabled and retain the patched dependency snapshots from the installation recipe. Enable Python only with the supplied Snakepit diagnostic boundary and a provisioned worker environment.
- Provision optional servers, compiled libraries and executables explicitly. Configuring an adapter or Eval backend does not install its service or prove its ABI and licensing requirements are met.
- Own adapter cancellation and teardown. After a restart, rebuild service bindings from trusted configuration rather than restoring process handles.

The V3 preview has provider-qualified built-in model defaults. Inference still requires your application's selected account and credential resolver. Explicit invalid model selections fail instead of falling back. See [models and accounts](guides/models-and-accounts.md).

## Know where state lives

| Data | Location and lifetime | Protection and recovery |
|---|---|---|
| Session identity, options, selected model/account reference, runs, effect journal, conversation, native checkpoint, retained context, goal, plan, child identities and recent events | The runtime's configured `storage:` adapter | Private application data. Checkpoints are sanitized, not encrypted by the session store. Protect the store and its backups like repository source and conversations. |
| Repository files, Git worktrees, generated files and tool artifacts | The workspace or application-selected artifact store | Back these up separately. A session checkpoint is not a filesystem snapshot and does not roll back edits or commands. |
| API keys and OAuth credentials | Your credential resolver or separately supervised account broker/vault | Never use session storage as a credential vault. Account references are opaque identifiers, not secrets. |
| Live agent processes, subscribers, pending callers, adapter handles and Eval kernels | Runtime memory and owned external processes | Recreate after restart. A checkpoint does not preserve an OS process, browser lease, debugger or Eval interpreter state. |
| Application logs, telemetry exports and any external audit log | Infrastructure you control | Export allowlisted metadata. Do not dump native state, host-only inspection maps or conversations into general logs. |

`OhMyJido.Auth.FileStore` encrypts account records with AES-256-GCM and writes private files. Your application supplies its random 32-byte key; the store never persists that key. Keep a recoverable copy in your secret service, separate from vault backups. Losing it prevents account recovery. See [security](guides/security.md) for the redaction and diagnostic boundaries.

## Choose storage and back it up

| Choice on `jido-v3-preview` | Use it when | Important boundary |
|---|---|---|
| Default `Jido.Persistence.ETS` | You need worker-restart recovery within the current running application | It does not survive a host/VM restart. It is not a durable backup. |
| `{Jido.Persistence.File, path: "/private/path"}` | One application deployment needs persistent local sessions | Use a persistent volume, restrict directory access and back up the complete adapter directory. Exactly one BEAM instance must own it; use the same canonical path, not alternate symlink paths. |
| A durable adapter implementing `Jido.Persistence.Adapter` | Your application needs a different persistence service | The native contract stores binary keys/values and opaque compare-and-swap conditions. Follow the adapter's ownership, consistency and backup requirements; a shared store is not permission to concurrently own one session. |

The file adapter uses atomic replacement and a per-key lock within the local BEAM. Separate BEAMs or OS processes must not write the directory concurrently. The SDK recommends Redis for storage shared across BEAM instances; your application still owns session coordination. The adapter does not encrypt the stored bytes.

A safe backup procedure is application-owned:

1. Stop accepting new tasks. Finish or cancel active runs and complete their cleanup. Use the [session and recovery guide](guides/sessions-and-recovery.md) to handle interrupted or uncertain work; do not delete journal records to make it appear complete.
2. Take a consistent snapshot with writers stopped, or use your storage service's supported snapshot mechanism. Include session storage, the matching workspaces/artifacts and any application database that maps users to session IDs. Back up the encrypted vault separately.
3. Encrypt the archive, restrict access and retain the configuration, dependency pins and original runtime/session identities needed to read it. Preserve canonical workspace paths or plan an explicit application migration.
4. Restore into an isolated deployment with the same compatible library/SDK versions. Restore vault access through the secret service, rebuild adapters and call `OhMyJido.resume_session/2` for the intended IDs. Re-subscribe event consumers.
5. Inspect restored runs and effects before continuing. An interrupted effect becomes `:uncertain` and is never automatically retried. Operator reconciliation records your decision; it does not invent a successful result or undo an effect.

The library has no automatic archive rotation or history-pruning service. Set retention in your application. Storage failures, including compare-and-swap conflicts or indeterminate outcomes, stop the session rather than claiming a durable transition succeeded.

## Collect telemetry without logging payloads

The library emits one telemetry event for each public session event:

| Event name | Measurements | Metadata |
|---|---|---|
| `[:oh_my_jido, :event]` | `%{seq: integer, at_ms: integer}` | `%{session_id: binary, kind: atom}` |

`seq` is the session's increasing event sequence. `at_ms` is system time in milliseconds, not a duration. The telemetry metadata contains no runtime name, run ID or event payload. If you use the same session ID in multiple runtimes, this event alone cannot distinguish them.

Attach a lightweight handler and forward measurements to a supervised collector:

```elixir
:telemetry.attach(
  "my-app-coding-events",
  [:oh_my_jido, :event],
  fn _event, measurements, metadata, collector ->
    send(collector, {:coding_event_metric, metadata, measurements})
  end,
  collector_pid
)
```

Here `collector_pid` is your application's collector process. Detach the handler with `:telemetry.detach("my-app-coding-events")` when its owner stops. Handlers execute synchronously in the emitting process: do not do slow I/O inside them. Aggregate by event kind rather than creating unbounded metric labels for every session ID.

The dependencies emit additional telemetry, with their own contracts:

| Source | Event families | Interpretation |
|---|---|---|
| Jido V3 | Agent lifecycle/turn/commit/directive and persistence spans; `[:jido, :agent, :turn, :settled]`, `[:jido, :agent, :admission, :rejected]`, `[:jido, :scheduler, :delivery]` | Native V3 lifecycle, post-commit settlement and SDK admission/scheduling. These are not the removed Jido 2.4 AgentServer command/signal/queue event families. SDK scheduling is not a queue for rejected Oh-My-Jido runs. |
| Jido.AI | `[:jido, :ai, :request, phase]`, `[:jido, :ai, :llm, phase]`, `[:jido, :ai, :tool, phase]` | Model/tool lifecycle with `duration_ms`, token counters and retry count. The native emitter sets `queue_ms` to zero and defaults missing counters/durations to zero; these values do not prove latency or usage was measured. |
| ReqLLM | `[:req_llm, :request, phase]`, `[:req_llm, :reasoning, phase]`, `[:req_llm, :token_usage]` | Provider request, reasoning and usage lifecycle. ReqLLM `duration` uses VM monotonic time units; convert with `System.convert_time_unit(duration, :native, :millisecond)`. |

Credential-bearing model turns force ReqLLM telemetry `payloads: :none`. Do not enable raw payloads or debug logs to investigate live credentials. Redaction does not make arbitrary third-party logs or trusted-host introspection safe.

For UI updates, consume `{:oh_my_jido, %OhMyJido.Event{}}` messages, not telemetry. Keep questions and approvals responsive while another caller waits for a run. Track event sequence cursors and explicitly re-subscribe after a consumer is detached. The bounded event ring is not a permanent audit log. See the [API reference](reference/api.md) for event kinds and payloads.

## Set capacity and handle saturation

Admission is the decision to accept work now. The runtime refuses work when a limit is full; it does not place rejected runs in a background queue. These defaults come from `OhMyJido.Runtime`:

| Option | Default | Scope and saturation behavior |
|---|---:|---|
| `max_sessions` | 500 | Sessions per runtime; starting another returns `{:error, {:capacity, :sessions}}`. |
| `max_active` | 8 | Active model runs per runtime; admission returns `{:error, {:capacity, :model}}`. A second run on the same busy session returns `{:error, :busy}`. |
| `max_processes` | 8 | Process leases per runtime; the core refusal reason is `{:capacity, :process}`. |
| `max_subagents` | 16 | Subagent leases per runtime; the core refusal reason is `{:capacity, :subagent}`. |
| `max_resources` | 64 | Tracked live resources per session; refusal is `:resource_capacity`. |
| `max_runs` | 128 | Retained runs per session; refusal is `{:capacity, :run_history}`. Completed runs still count. |
| `max_effects` | 1,024 | Effect records per session; refusal is `{:capacity, :effect_history}`. Completed records still count. |
| `max_secrets` | 256 | Registered redaction secrets per session; refusal is `:redaction_capacity`. |
| `max_pending_questions` | 8 | Outstanding questions per session; refusal is `:question_capacity`. |
| `event_limit` | 256 | Retained events per session; oldest events are removed when the ring is full. |
| `subscriber_limit` | 128 | Default pending-message threshold for each subscriber, not a subscriber-count cap. A consumer at the threshold is detached. |
| `eval: [max_kernels: ...]` | 8 | Live Eval kernels per runtime's Eval manager; refusal is `:kernel_limit`. No Eval backend is enabled by default. |
| `max_iterations` | 40 | Maximum native model/tool iterations per run. A prompt can choose a lower limit. |

Tool calls may wrap core refusal reasons in the SDK's error envelope. V3 wraps an Action's `{:error, reason}` in `Jido.Action.Error.ExecutionFailureError`; match `error.details.reason`. Plugin failures and non-map reasons also carry `details.retry: false`. Use the [API](reference/api.md) and [configuration](reference/configuration.md) references for complete return shapes and tool-specific budgets. Runtime capacities and timeouts must be positive integers.

| Timeout | Default | Purpose |
|---|---:|---|
| `question_timeout_ms` | 300,000 ms | How long a question or approval waits for an answer. The wait does not use the tool budget. |
| `tool_timeout_ms` | 30,000 ms | Command deadline ceiling. A tool call is stopped after `tool_timeout_ms` plus `question_timeout_ms`. |
| `run_timeout_ms` | 300,000 ms | Managed run deadline. This is separate from a caller's `await/3` timeout. |

Monitor refusals, active work, run and tool latency, failures, pending approvals, usage/plan errors and uncertain effects. Also watch mailbox lengths, VM run queues, ports, OS descendants and cleanup outcomes. A quiet mailbox is not proof of zero scheduling latency. If your application needs a backlog, own and bound it explicitly; do not resubmit work blindly after a timeout or uncertain effect. Archive and start a fresh session before a history ceiling is reached rather than silently discarding the journal.

A model answer or completed plan does not prove that repository tests passed. Use actual test-process results and retained check results.

## Run the density benchmark

From the repository root, use the credential-free harness to observe idle session populations, real file/process tools, immediate capacity refusal and cleanup:

```sh
MIX_ENV=test mix run bench/density.exs -- --output bench/results/density-full.json
```

The default populations are `1,10,100,500`, active capacity is `8` and each offered concurrency runs for six rounds. Choose an unused output path; the harness refuses to overwrite a report. Omitting `--output` creates a timestamped file.

For a smaller smoke run:

```sh
MIX_ENV=test mix run bench/density.exs -- --populations 1,3 --active 1 --rounds 1 --idle-ms 25 --model-ms 10,15,10,15 --tool-ms 1,2,1 --process-ms 10,20 --run-timeout-ms 3000 --tool-timeout-ms 1000 --deadline-ms 20000 --output bench/results/density-smoke-new.json
```

Run against a settled checkout with the prescribed dependency overrides. The harness needs Linux procfs and `sh`, `setsid`, `mkfifo`, `cat`, `kill` and `sleep`. The V3 fixture uses a temporary loopback HTTP/SSE model server, not an external provider. Keep the complete JSON report and its source fingerprints. Model delays are simulated, so this is not provider throughput or a calibrated per-agent memory benchmark. See [the benchmark guide](../bench/README.md) for options, output fields and interpretation, and [project status](project-status.md) for retained measurements.

## Platform requirements

The project requires Elixir `~> 1.20`. Tested with Elixir 1.20.2 / OTP 28 on Linux x86_64.

Tools that start OS processes (List, Search, Shell, Git, Claude Code, language servers, debuggers, MCP servers and Eval) need Linux with `setsid` and `/proc`. Elsewhere they fail closed with `{:capability_unavailable, :linux_process_groups}`, `:protocol_platform_unavailable` or `{:backend_unavailable, …}`. Other operating systems are untested; Read, Write, Edit, AST, Observer and the model loop do not start OS processes.

| Capability | Additional requirement |
|---|---|
| Subprocess tools | Linux procfs, `setsid`, `sh`, `mkfifo`, `cat` and `kill`. This includes List, Search, Shell, Git, language servers, debuggers, MCP servers and Eval. |
| List and Search | The Linux requirements above, plus ripgrep (`rg`). |
| Git tools and worktrees | The Linux requirements above, plus `git`. |
| Language servers and debugging | The Linux requirements above, plus a configured trusted LSP or DAP server executable. These tools can compile or run project code outside the application VM. |
| Observer process inventory | OTP 28+ process iterator support; older runtimes refuse this operation. Observer needs no GUI or wxWidgets. |
| Eval | The Linux requirements above and explicit backend configuration. Elixir uses a separate ERTS; JavaScript additionally needs QuickBEAM; Python needs the supplied Snakepit integration and a provisioned Python environment. Check compiled-library target/ABI support. |
| MCP servers | The Linux requirements above, plus an explicitly configured server, permissions and cleanup policy. |
| Browser, research and live-application integrations | Explicit application-owned adapters, services, permissions and cleanup policy. Any subprocess-backed adapter also needs the Linux requirements above. |

The process runner returns `{:capability_unavailable, :linux_process_groups}` when Linux or `/proc` is unavailable. Stdio-backed servers use protocol-specific startup failures such as `:protocol_platform_unavailable`. No macOS, Windows, Linux aarch64 or other guest-platform support is established by the Linux x86_64 record. Declaring a dependency or starting a separate ERTS is not proof of target support or OS isolation. Sessions and managed process calls do not change the application VM's working directory or environment; inherited environment variables, mounts and same-user filesystem access still require your isolation policy. The curated Python infrastructure path avoids Snakepit's global-environment/installer startup; it does not hide inherited secrets from arbitrary worker code.

## Troubleshoot dependency mismatches

Use the bundled snapshots as a matching set. Replacing one independently can remove the diagnostic boundary before an error reaches Oh-My-Jido's redaction layer.

| Dependency | Required boundary and failure |
|---|---|
| Jido V3 Core | Runtime startup requires `Jido.AgentServer.private_diagnostics_version/0` to return `1`; a missing boundary raises `ArgumentError`. Own-agent plugins report `:native_private_diagnostics_required`. |
| Jido.Action V3 | Use the bundled Action snapshot with the selected Core/AI revisions. Its private diagnostic projector and ownership observer supply worker-stop evidence; their options do not create a separate execution engine or a retry path. |
| Jido.AI V3 | Use the bundled AI snapshot and activate privacy before accepting private work. Successful model/tool values and ordinary non-private behavior remain unchanged. |
| ReqLLM | Model/subscription requests require `ReqLLM.Streaming.Failure.normalization_version()` to return `1`; an unsupported boundary returns a typed `:unsupported_req_llm_version` diagnostic. |
| Snakepit | Python Eval requires `Snakepit.GRPCWorker.private_diagnostics_version()` to return `1`, or returns `{:error, {:backend_unavailable, :python, :snakepit_private_diagnostics_unavailable}}`. |

Do not suppress logs or turn off the checks to bypass a mismatch. Restore the [branch's dependency overrides](getting-started.md#2-add-oh-my-jido), keep ReqLLM debugging disabled, and activate private diagnostics before private work starts.

## Upgrade with a clean cutover

1. Pin the library and its matching dependency snapshots. Review branch-specific installation and configuration changes before resolving a new graph; do not independently upgrade one privacy-patched SDK component.
2. Stop admission, settle active work and take a consistent private backup. Retain the old application and dependencies so you can recover with the versions that wrote the data.
3. Exercise restoration in an isolated deployment. ContextPolicy version 2 rejects older policy checkpoints whose effect identities cannot be reconstructed; do not relabel them as version 2.
4. Replace the application as a unit, rebuild trusted service bindings and restore only compatible sessions. Confirm permissions, account references and pending decisions before resuming work.

This branch uses `Jido.Persistence.Adapter` with binary keys/values and opaque compare-and-swap conditions. Stable `master` uses `Jido.Storage`. There is no automatic V2-to-V3 checkpoint conversion, and the file layouts differ. Treat switching SDK tracks as a clean cutover with a separate store, not a drop-in upgrade or shared writable directory. See [getting started](getting-started.md) for the matching install recipe.

## Keep deployment policy in your application

Your application owns adapter lifecycle, request-local workspaces, confirmations, browser ownership, target packaging, build provenance, privilege helpers and OS promotion/health/fallback workflows. Oh-My-Jido provides no OS boot callback, root escalation, reboot or guest-promotion workflow.

## Related

- [Sessions and recovery](guides/sessions-and-recovery.md)
- [Security](guides/security.md)
- [Configuration reference](reference/configuration.md)
- [Project status and evidence](project-status.md)
