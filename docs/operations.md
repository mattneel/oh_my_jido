# Run Oh-My-Jido in production

Oh-My-Jido runs inside your Elixir application. Your application supervises the runtime, stores session state, supplies credentials and decides which work is allowed. Use this guide to choose storage, protect private data, monitor work and plan capacity before accepting coding tasks.

## Prepare the application

Supervise a named runtime with a private persistent storage directory and explicit limits:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   storage: {Jido.Storage.File, path: "/srv/my_app/coding_sessions"},
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

On `master`, set an explicit active `model:` or `model_roles` before model work. The Jido 2.4 default aliases include a retired model. See [models and accounts](guides/models-and-accounts.md).

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

| Choice on `master` | Use it when | Important boundary |
|---|---|---|
| Default `Jido.Storage.ETS` | You need worker-restart recovery within the current running application | It does not survive a host/VM restart. It is not a durable backup. |
| `{Jido.Storage.File, path: "/private/path"}` | One application deployment needs persistent local sessions | Use a persistent volume, restrict directory access and back up the complete adapter directory. Atomic file replacement is not encryption or a backup policy. |
| A durable adapter implementing `Jido.Storage` | Your application needs a different persistence service | Follow that adapter's consistency, ownership and backup requirements. Do not assume a shared store makes concurrent ownership of one session safe. |

A safe backup procedure is application-owned:

1. Stop accepting new tasks. Finish or cancel active runs and complete their cleanup. Use the [session and recovery guide](guides/sessions-and-recovery.md) to handle interrupted or uncertain work; do not delete journal records to make it appear complete.
2. Take a consistent snapshot with writers stopped, or use your storage service's supported snapshot mechanism. Include session storage, the matching workspaces/artifacts and any application database that maps users to session IDs. Back up the encrypted vault separately.
3. Encrypt the archive, restrict access and retain the configuration, dependency pins and original runtime/session identities needed to read it. Preserve canonical workspace paths or plan an explicit application migration.
4. Restore into an isolated deployment with the same compatible library/SDK versions. Restore vault access through the secret service, rebuild adapters and call `OhMyJido.resume_session/2` for the intended IDs. Re-subscribe event consumers.
5. Inspect restored runs and effects before continuing. An interrupted effect becomes `:uncertain` and is never automatically retried. Operator reconciliation records your decision; it does not invent a successful result or undo an effect.

The library has no automatic archive rotation or history-pruning service. Set retention in your application. Storage failures stop the session rather than claiming a durable transition succeeded.

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
| Jido 2.4 | `[:jido, :agent, :cmd, phase]`, `[:jido, :agent_server, :signal, phase]`, `[:jido, :agent_server, :directive, phase]`; `[:jido, :agent_server, :queue, :overflow]` | SDK execution and queue pressure. Lifecycle phases include `:start`, `:stop` and `:exception`; an SDK queue is not a queue for rejected Oh-My-Jido runs. |
| Jido.AI | `[:jido, :ai, :request, phase]`, `[:jido, :ai, :llm, phase]`, `[:jido, :ai, :tool, phase]` | Model/tool lifecycle, normalized `duration_ms`, token counters, retry count and `queue_ms`. Available phases depend on the family. Some measurements default to zero; a zero value does not prove usage or queue latency was measured. |
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

Tool calls may wrap core refusal reasons in the SDK's error envelope. Use the [API](reference/api.md) and [configuration](reference/configuration.md) references for complete return shapes and tool-specific budgets. Runtime capacities and timeouts must be positive integers.

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

Run against a settled checkout with the prescribed dependency overrides. The harness needs Linux procfs and `sh`, `setsid`, `mkfifo`, `cat`, `kill` and `sleep`. Keep the complete JSON report and its source fingerprints. Model delays are simulated, so this is not provider throughput or a calibrated per-agent memory benchmark. See [the benchmark guide](../bench/README.md) for options, output fields and interpretation, and [project status](project-status.md) for retained measurements.

## Platform requirements

The project requires Elixir `~> 1.20`. Tested with Elixir 1.20.2 / OTP 28 on Linux x86_64.

Tools that start OS processes (List, Search, Shell, Git, Claude Code, language servers, debuggers, MCP servers and Eval) need Linux with `setsid` and `/proc`. Elsewhere they fail closed with `{:capability_unavailable, :linux_process_groups}`, `:protocol_platform_unavailable` or `{:backend_unavailable, …}`. Other operating systems are untested; Read, Write, Edit, AST, Observer and the model loop do not start OS processes.

| Capability | Additional requirement |
|---|---|
| Shell and managed process tools | Linux `/proc`, `setsid`, `sh`, `mkfifo`, `cat` and `kill`. Other operating systems fail closed. |
| List and Search | The same Linux process requirements, plus ripgrep (`rg`). |
| Git tools and worktrees | The same Linux process requirements, plus `git`. |
| Language servers and debugging | The Linux stdio launcher requirements and a configured trusted LSP or DAP server executable. These tools can compile or run project code outside the application VM. |
| Observer process inventory | OTP 28+ process iterator support; older runtimes refuse this operation. Observer needs no GUI or wxWidgets. |
| Eval | Linux process supervision and explicit backend configuration. Elixir uses a separate ERTS; JavaScript additionally needs QuickBEAM; Python needs the supplied Snakepit integration and a provisioned Python environment. Check compiled-library target/ABI support. |
| MCP servers | The Linux stdio launcher requirements and a configured trusted server executable. Your application owns permissions and cleanup policy. |
| Browser, research and live-application integrations | Explicit application-owned adapters, services, permissions and cleanup policy. |

No macOS, Windows, Linux aarch64 or Elixos guest support is established by the Linux x86_64 record. Declaring a dependency or starting a separate ERTS is not proof of target support or OS isolation. Sessions and managed process calls do not change the application VM's working directory or environment; inherited environment variables, mounts and same-user filesystem access still require your isolation policy. The curated Python infrastructure path avoids Snakepit's global-environment/installer startup; it does not hide inherited secrets from arbitrary worker code.

## Troubleshoot dependency mismatches

Keep the patched dependency overrides from [getting started](getting-started.md). These version checks prevent startup or model requests when the required diagnostic protection is missing; do not bypass them to make a stock package work.

| Dependency | Required boundary | Failure and action |
|---|---|---|
| Jido | `Jido.AgentServer.private_diagnostics_version/0` returns `1`. | Runtime startup raises `ArgumentError` if the boundary is unavailable. Restore the pinned Jido override. |
| ReqLLM | `ReqLLM.Streaming.Failure.normalization_version()` returns `1`. | Model and subscription requests reject the unsupported boundary with `:unsupported_req_llm_version`. Restore the pinned ReqLLM override. |
| Snakepit, when Python Eval is enabled | `Snakepit.GRPCWorker.private_diagnostics_version()` returns `1`. | Python Eval returns `{:error, {:backend_unavailable, :python, :snakepit_private_diagnostics_unavailable}}` otherwise. Select the supplied Snakepit snapshot and compile the matching backend. |

See [security](guides/security.md#keep-the-bundled-patched-dependencies) for what each patch protects.

## Upgrade with a clean cutover

1. Pin the library and its matching dependency snapshots. Review branch-specific installation and configuration changes before resolving a new graph; do not independently upgrade one privacy-patched SDK component.
2. Stop admission, settle active work and take a consistent private backup. Retain the old application and dependencies so you can recover with the versions that wrote the data.
3. Exercise restoration in an isolated deployment. ContextPolicy version 2 rejects older policy checkpoints whose effect identities cannot be reconstructed; do not relabel them as version 2.
4. Replace the application as a unit, rebuild trusted service bindings and restore only compatible sessions. Confirm permissions, account references and pending decisions before resuming work.

The V3 preview uses `Jido.Persistence.Adapter`, not `Jido.Storage`. It has a different file layout and byte/compare-and-swap contract. There is no automatic V2-to-V3 checkpoint conversion. Treat switching SDK tracks as a clean cutover with a separate store, not a drop-in upgrade or shared writable directory. See [getting started](getting-started.md) for the matching install recipe.

## Elixos ownership

Elixos integration belongs to Elixos. Oh-My-Jido has no Elixos dependency or OS boot callback. Elixos owns its adapter lifecycle, request-local workspace, confirmations, browser ownership, target packaging, build provenance, privilege helpers and the NEXT → reboot → health → COMMIT/fallback workflow. The library does not provide root escalation, reboot or guest promotion. The [Elixos example](../examples/elixos/README.md) is a historical integration reference, not a claim that a deployed OS includes the library or its optional backends.

## Related

- [Sessions and recovery](guides/sessions-and-recovery.md)
- [Security](guides/security.md)
- [Configuration reference](reference/configuration.md)
- [Project status and evidence](project-status.md)
