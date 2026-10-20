# Credential-free density evidence

This is the human-invoked harness for [T11](../docs/oh-my-jido/ACCEPTANCE.md#t11-process-density).
It supervises `OhMyJido.Runtime` in an ordinary OTP supervisor and calls the public
session API. Installed Jido.AI ReAct owns every model/tool turn; installed Jido
Actions execute the filesystem and process operations. Nothing in `bench/` is
loaded by the library application.

## Run

From the project root, after integration edits have stopped:

```sh
MIX_ENV=test mix run bench/density.exs -- --output bench/results/density-new.json
```

Linux procfs and `sh`, `setsid`, `mkfifo`, `cat`, `kill`, and `sleep` are required.
Use the installed, approved native dependency overrides in this repository.
No account, API key, subscription, external provider request, or external service
is needed. Native scripts exercise ReqLLM over an actual temporary loopback
HTTP/SSE model server. The fixture host refuses credential callbacks and
unexpected effects. This is not a live-provider performance measurement.

The command writes one complete JSON document. Existing evidence is never
overwritten; choose a new `--output` path for a second run. Without `--output`, a
unique timestamped name under `bench/results/` is selected. The final stdout line
is a JSON object containing `result`, `evidence_file`, and `schema_version`.
Compilation and logger output may also appear on stdout: retain the JSON file,
not a redirected terminal transcript, as the evidence artifact.

A smaller smoke invocation still exercises idle density, real tools, model
admission, and the configured session ceiling:

```sh
MIX_ENV=test mix run bench/density.exs -- --populations 1,3 --active 1 --rounds 1 --idle-ms 25 --model-ms 10,15,10,15 --tool-ms 1,2,1 --process-ms 10,20 --run-timeout-ms 3000 --tool-timeout-ms 1000 --deadline-ms 20000 --output bench/results/density-smoke-new.json
```

The integration owner has now executed both retained native workloads on Linux
x86_64: [the 1/3 smoke](results/density-smoke.json) and [the full 1/10/100/500
report](results/density.json) each record `result: "passed"`. The full artifact
records active capacity 8, six rounds, elapsed benchmark work 83,927.167 ms and
confirmed teardown/cwd/env/descendant-count invariants. Native model latency is
still simulated; no provider throughput, comparative scaling improvement,
aarch64/guest result or complete acceptance gate follows from that result.
The source/loaded-BEAM fingerprints identify the measured implementation.
See [operations and measured tables](../docs/oh-my-jido/OPERATIONS_AND_EVIDENCE.md)
for exact values and remaining verification. This documentation task ran no
benchmark, test, build or formatter and did not overwrite either JSON artifact.

## Workload and bounds

Defaults:

| Option | Default | Meaning |
|---|---|---|
| `--populations` | `1,10,100,500` | Independent idle supervised session populations, each removed before the next |
| `--active` | `8` | Runtime model-run and process lease ceilings |
| `--rounds` | `6` | Repetitions at each distinct offered concurrency |
| `--idle-ms` | `250` | Minimum idle observation window |
| `--sample-ms` | `25` | Requested interval between pressure samples; actual sampling cost is retained |
| `--model-ms` | `120,240,180,300` | Bounded simulated gateway delay, cycled over native model turns |
| `--tool-ms` | `10,20,10` | Bounded authorization delay for read, edit, and exec respectively |
| `--process-ms` | `80,160,120,240` | Actual shell sleep values, deterministically selected per job |
| `--tool-timeout-ms` | `5000` | Confined process/tool budget |
| `--run-timeout-ms` | `15000` | Runtime deadline and public await bound |
| `--deadline-ms` | `180000` | Whole benchmark-work deadline, followed by bounded supervisor teardown |

Population values are unique integers from 1 through 500, active capacity is
1–64, and all configured sleeps are 0–2000 ms. Invalid or inconsistent bounds
are rejected before sessions start. The command's Mix startup/compilation and
host metadata collection precede the benchmark-work deadline. Supervisor
teardown has a separate 15000 ms bound. Slow or failed native work produces
failed/partial evidence, not invented terminal timings.

Before any measured baseline, one bounded actual native scripted gateway request
initializes the VM-owned OTP resolver used by loopback HTTP/SSE. Its temporary
session, checkpoint, runtime, owned Finch, ETS tables and workspace are fully
retired before the empty-runtime snapshot. `gateway_warmup` records the observed
model call,
request/initialization bounds, teardown and cold/warm OS descendant identities.
This is infrastructure initialization, not an exclusion or a baseline reset after
measured work: shared `inet_gethost` processes are never killed or claimed as
session-owned. Measured workloads still must return exactly to the baseline.

The measured model label is explicitly `anthropic:claude-sonnet-4-6`; startup
requires actual catalog metadata with tool capability enabled. Missing/retired
model capabilities are never treated as tool permission. Each population owns
an ordinary supervised Finch selected through native `req_http_options[:finch]`.
Its temporary loopback endpoint pools are stopped between populations and at
final teardown; no benchmark request may accumulate pools in the application's
shared Finch. `after_sessions` is sampled before this fixture Finch is stopped,
so VM-wide BEAM counts there include its still-owned endpoint pools.

Each population first measures an empty-runtime baseline and then the requested
number of actual idle sessions. Idle acceptance counts native Agent actors from
their preserved OTP module metadata, not every worker under AgentSupervisor.
`native_plugin_lifecycle_count` and `native_agent_supervisor_child_count` retain
the separate Plugin lifecycle and total-child observations without a hardcoded
multiplier. Coordinator/actor counts must match the session population, with zero
active leases. With population `N`, the offered
concurrency sweep is the distinct values of `1`, `min(8,N)`, and `min(9,N)` for
default active capacity; `--active` changes the last two values accordingly.
Each wave offers its entire batch behind one start barrier. There is no driver
backlog, implicit `async_stream` queue, retry, or resubmission of a rejected run.

`Runtime.reserve/3` uses `Task.Supervisor.max_children`. Exceeding that limit
returns an immediate capacity **rejection**, not queued work. Reports retain
accepted-call and rejected-call latencies separately. In-flight driver attempts,
mailboxes, and the VM runnable queue are separate pressure measurements. A model
saturation point is recorded only from observed capacity rejections. Below the
model ceiling, every offered run must be admitted and complete; an oversubscribed
wave must admit exactly the configured capacity and reject its excess calls.
The final/largest population also offers one extra session to observe the session
ceiling. A population below the configured ceiling cannot prove that ceiling and
records `not_exercised`.

Every admitted job performs this finite, native scripted sequence:

1. Read the exact contents of `input.txt` through `OhMyJido.Tools.Read`.
2. Create `output.txt` through the snapshot-guarded `OhMyJido.Tools.Write`, using
   the native `missing` snapshot contract.
3. Use `OhMyJido.Tools.Shell` to check the written contents, sleep in an actual
   OS subprocess, and write receipt/cwd/env observations. The child uses a nested
   cwd and one child-scoped environment override; stdout and stderr are distinct.
4. Receive the script's terminal model answer through the normal native loop.

The benchmark verifies the native model/tool event sequence, actual completed
effect records, read content, returned snapshots, written file bytes, process
exit/cleanup/effect status, output streams, and receipt/cwd/env files. A scripted
answer alone is not success. Tool failures cannot be concealed by that answer.
Process duration, exit status, byte counts, hashes, requested sleeps, and observed
sleep durations accompany the boolean checks.

The benchmark-only transformer first successfully delegates to
`OhMyJido.Models.Transformer`, then sleeps **inside the native runner** before
returning the unchanged override. This is simulated model-gateway latency, not a
provider RTT. It does not delay AgentServer telemetry handlers or introduce
another model loop. Runtime's trusted `request_transformer` configuration selects
it; per-task transformer overrides remain disallowed.

Each job uses a fresh native session at a fixed population slot. Its session is
stopped, its dedicated checkpoint is deleted, its workspace is removed, and the
slot is replenished outside measured run latency. This keeps the scripted model
fixture's request history fresh without altering Jido's loop or compaction.
Idle populations remain fixed; the benchmark does not measure growing-session
history, live-provider transport, Eval, subagents, or optimal throughput. Wave
wall time also includes evidence collection; population wall time includes slot
replacement. Per-job run latency ends at the actual public `await` result, before
post-run artifact checks.

Explicit runtime configuration is retained in each population's `limits` and the
report's `workload`: host module, model label, grants, actions, ETS storage,
resource budgets, process/output/file limits, timeouts, iteration/history/effect
bounds, context policy, event/subscriber limits, and disabled Eval backends. The
model label is local capability metadata only. Dedicated ETS tables are created
before idle baselines, owned by the benchmark controller task, and removed with
that task. Retired sessions do not accumulate checkpoints between populations.

All workspaces are under a randomly named disposable temporary root. Native
session references and run IDs are ordinary strings; transient PID/Port handles
are never serialized. The host VM cwd and environment are not changed. An
in-memory environment fingerprint is compared before/after; neither environment
values nor that fingerprint are retained. Reports exclude prompts, raw native
error payloads, file contents, credentials, and diagnostic stack traces.

## Metrics schema and interpretation

[`density.schema.json`](density.schema.json) is the JSON Schema 2020-12 contract.
The emitted discriminator is `schema: "oh_my_jido.density"`, `schema_version: 1`.
Times use observed monotonic milliseconds; memory uses bytes; counts are actual
observations. Absolute report time is UTC. Distributions contain
`count`, `min`, `max`, `p50`, `p95`, and `p99`, using nearest rank, without
interpolation. Empty distributions contain zero count and null values. Small
sample sets, especially the one-session population, cannot establish stable tail
performance merely because p99 is present.

| JSON path | Evidence |
|---|---|
| `host` | Actual kernel/architecture/CPU/physical memory, cgroup constraints when available, Elixir/OTP/ERTS build, scheduler and VM limits, loaded application versions, executable paths, source and loaded-BEAM fingerprints |
| `configuration` / `workload` | Exact requested population/workload/sleep bounds and interpretation |
| `gateway_warmup` | One actual native scripted model request before baselines, observed gateway delay, bounded initialization, full temporary-resource teardown, and cold/warm OS descendant identities |
| `populations[].baseline` | Same empty supervised runtime immediately before that population |
| `populations[].idle` | Idle samples, observed invariant, pressure distributions, and resident/VM-memory/process deltas from the empty runtime |
| `populations[].active[].admission` | Offered, admitted, rejected, model-capacity-rejected, completed, and failed/unobserved counts; queued is zero because this workload has no backlog |
| `populations[].active[].latency_ms` | Separate distributions for all observed admitted-run outcomes, successful runs, accepted calls, rejected calls, and driver dispatch |
| `populations[].active[].waves[].jobs[]` | Actual per-attempt timings, native run identity/status, effect/process evidence, invariant checks, errors, and measured delay observations |
| `populations[].active[].waves[].samples[]` | Raw VM memory/process/port/runnable counts, OS RSS/descendants, active leases, runtime mailboxes, observer mailbox, and in-flight driver attempts |
| `populations[].saturation` | Actual session-capacity probe, first observed model-rejection load, observed lease peak, admission/resource-bound invariants, and explicit non-queue semantics |
| `populations[].cleanup` / `cleanup` | Population removal, supervisor termination, disposable-root removal, cwd/env preservation, and exact before/after live OS descendant counts and identities |
| `errors` / population error alternative | Safe error codes/types; unavailable work is failed/partial, never success or a synthetic timing |

`os.beam_rss_bytes` comes from Linux `VmRSS`; it includes the VM's resident heap,
allocator arenas, code, stacks, and native allocations. `beam_memory_bytes` comes
from `:erlang.memory/0` and is VM-accounted allocated memory, **not** RSS.
`VmHWM` is a process-lifetime high-water mark, not a resettable population peak.
Live descendant RSS is a separate sum and does not deduplicate shared pages.
Zombies, vanished processes, missing RSS, and supervisor read races are recorded
separately. VM counters include Mix, application processes, the benchmark driver,
and retained evidence, while runtime mailbox/process counts traverse the actual
runtime supervision tree. Baselines are population-specific: startup warming,
allocator retention, and prior evidence can change absolute RSS across phases.

Sampling itself costs work and can miss short-lived mailbox/process peaks; its
observed duration is reported. Empty mailboxes do not prove zero scheduling
latency. Current reports retain each live descendant's PID, procfs start ticks,
name, parent, process group and session, and require exact identity and count
equality after teardown; no arbitrary helper process is excluded. Historical
reports lacking `live_descendants` prove count equality only. Actual Shell
cleanup status and stopped supervisors provide separate lifecycle evidence.
No unmeasured performance improvement, provider throughput, or scaling
claim follows from a `passed` result. `passed` means this finite workload and its
recorded cleanup/admission invariants passed; exit status is nonzero for failed
or partial runs.
