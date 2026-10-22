# Measure session density and capacity

The density harness measures how a supervised Oh-My-Jido runtime behaves with idle sessions and bounded concurrent coding tasks. It uses scripted Jido.AI responses, real file tools and actual Linux subprocesses. Run it to inspect memory, capacity refusals, latency and cleanup on your machine without an account, API key or external provider request. Nothing in `bench/` starts with the library application.

## Before you start

- Use a settled repository checkout with its prescribed native dependency overrides and installed Mix dependencies.
- Run on Linux with procfs and `sh`, `setsid`, `mkfifo`, `cat`, `kill` and `sleep` available.
- Choose a new report path. The harness refuses to overwrite an existing file.

The test host refuses credential callbacks and effects outside the fixture. On this stable SDK track, scripted model turns need no network service. The model delays are simulated; this is not a provider performance test.

## Run the benchmark

From the repository root, measure the default populations of 1, 10, 100 and 500 sessions:

```sh
MIX_ENV=test mix run bench/density.exs -- --output bench/results/density-full.json
```

For a smaller smoke run that still exercises real tools, model capacity and the session ceiling:

```sh
MIX_ENV=test mix run bench/density.exs -- --populations 1,3 --active 1 --rounds 1 --idle-ms 25 --model-ms 10,15,10,15 --tool-ms 1,2,1 --process-ms 10,20 --run-timeout-ms 3000 --tool-timeout-ms 1000 --deadline-ms 20000 --output bench/results/density-smoke-new.json
```

Omit `--output` to select a unique timestamped name under `bench/results/`. Repeat runs with new paths rather than replacing earlier reports.

## Read the output

The command writes one complete JSON report. Its final stdout line is a JSON object with `result`, `evidence_file` and `schema_version`. Compilation and logger messages can appear before that line; preserve the JSON file, not a redirected terminal transcript.

| Result | Meaning |
|---|---|
| `passed` | Every requested population finished and the recorded workload, admission and cleanup invariants passed. |
| `failed` | All populations produced reports, but one or more required checks failed. |
| `partial` | The benchmark did not finish all requested populations. Available observations and safe error codes remain in the report. |

Failed or partial runs exit nonzero. Missing or failed work is not assigned invented completion timings. Invalid options or an already-existing output path are rejected before the workload starts.

## Options and bounds

| Option | Default | Meaning and accepted bounds |
|---|---|---|
| `--populations` | `1,10,100,500` | Independent idle session populations; 1–16 unique integers, each 1–500. Each population is removed before the next. |
| `--active` | `8` | Model-run and process-lease ceilings; 1–64. |
| `--rounds` | `6` | Repetitions at each distinct offered concurrency; 1–1,000. |
| `--idle-ms` | `250` | Minimum idle observation window; 25–10,000 ms. |
| `--sample-ms` | `25` | Requested pressure-sample interval; 5–1,000 ms. Actual sampling cost is retained. |
| `--model-ms` | `120,240,180,300` | Simulated gateway delays, cycled over model turns; 1–16 integers, each 0–2,000 ms. |
| `--tool-ms` | `10,20,10` | Authorization delays for read, edit and exec respectively; exactly three integers, each 0–2,000 ms. |
| `--process-ms` | `80,160,120,240` | Actual shell sleep values selected deterministically per job; 1–16 integers, each 0–2,000 ms. |
| `--tool-timeout-ms` | `5000` | Tool/process budget; 500–60,000 ms. Must exceed every process sleep. |
| `--run-timeout-ms` | `15000` | Runtime deadline and public await bound; 1,000–120,000 ms. Must exceed the tool timeout. |
| `--deadline-ms` | `180000` | Benchmark-work deadline; 5,000–3,600,000 ms. Must exceed the run timeout. |
| `--output` | Timestamped file | Complete JSON report path. Existing files are refused. |

Mix startup/compilation and host metadata collection precede the benchmark-work deadline. Supervisor teardown has a separate 15,000 ms bound.

## What the workload does

For each population, the harness first samples an empty supervised runtime, then starts the requested number of actual idle sessions. The idle check compares coordinator and native agent supervisor counts with that population and requires zero active leases.

With population `N` and active ceiling `A`, the offered-concurrency sweep is the distinct values `1`, `min(A, N)` and `min(A + 1, N)`. Each wave releases its entire batch behind one start barrier. There is no driver backlog, implicit `async_stream` queue, retry or resubmission of rejected work.

Each admitted job runs this sequence through the installed Jido.AI model/tool loop and Jido Actions:

1. Read the exact contents of `input.txt` with `OhMyJido.Tools.Read`.
2. Create `output.txt` with `OhMyJido.Tools.Write`, using the snapshot guard `"missing"`.
3. Run `OhMyJido.Tools.Shell` to check the bytes, sleep in an actual subprocess and write receipt/cwd/environment observations. The child uses a nested working directory and one child-only environment override; stdout and stderr stay separate.
4. Return the scripted terminal answer through the normal model loop.

A terminal answer alone is not success. Checks cover the native event sequence, completed effect records, read content, returned snapshots, file bytes/digests, process exit and cleanup, separate output streams and actual receipt/cwd/environment files. The report includes durations, exit status, byte counts, hashes and requested/observed sleeps.

The benchmark transformer delegates to `OhMyJido.Models.Transformer`, then sleeps inside the native runner before returning its unchanged request override. This simulates a gateway delay without delaying telemetry handlers or adding a second model loop. Only trusted runtime configuration selects the transformer; per-task transformer overrides remain disallowed.

Each job starts with a fresh session at a fixed population slot. Afterward, its session is stopped, checkpoint and workspace are removed, and the slot is replenished outside measured run latency. Idle population stays fixed. Run latency ends at the public `await` result, before artifact checks. Wave time includes evidence collection; population time also includes slot replacement.

### How saturation is tested

`Runtime.reserve/3` uses bounded `Task.Supervisor` children. Exceeding the ceiling immediately rejects work; it does not queue it. The report separates offered, admitted, rejected and completed attempts and separates accepted-call latency from rejected-call latency.

Below the model ceiling, every offered run must be admitted and complete. An oversubscribed wave must admit exactly the configured capacity and reject its excess calls. The model saturation load comes from actual capacity refusals, not a predicted number. In-flight driver attempts, mailboxes and the VM runnable queue remain separate measurements.

The runtime session ceiling is the largest requested population. A final extra-session probe observes its refusal. Smaller populations cannot prove that ceiling and record `not_exercised` for the session-capacity probe.

### How temporary state is handled

Each population retains its exact runtime configuration: model label, test host, permissions, Action modules, ETS storage, resource/file/process/output budgets, timeouts, iteration/history/effect bounds, context policy and event/subscriber limits. Eval backends are disabled. The model label is local capability metadata, not provider access.

Dedicated ETS tables are created before idle baselines, owned by the controller task and removed with it. Retired sessions do not accumulate checkpoints between populations. Workspaces live under a randomly named disposable temporary root. Reports use string session/run IDs, not transient PID/Port handles.

The application VM's cwd and environment are unchanged. An in-memory environment fingerprint is compared before/after, but neither it nor environment values are retained. Reports exclude prompts, file contents, credentials, raw native error payloads and diagnostic stack traces.

## Report reference

[`density.schema.json`](density.schema.json) defines JSON Schema 2020-12. Reports use `schema: "oh_my_jido.density"` and `schema_version: 1`. Durations are observed monotonic milliseconds, memory is bytes and report time is UTC.

| JSON path | What it records |
|---|---|
| `host` | Kernel, architecture, CPU, physical memory, cgroup constraints when available, Elixir/OTP/ERTS build, schedulers/VM limits, application versions, executable paths and source/loaded-BEAM fingerprints. |
| `configuration` / `workload` | Requested options, exact runtime workload and measurement scope. |
| `populations[].baseline` | The empty supervised runtime immediately before that population. |
| `populations[].idle` | Idle samples/invariants, pressure distributions and resident/VM-memory/process deltas from the empty runtime. |
| `populations[].active[].admission` | Offered, admitted, rejected, model-capacity-rejected, completed and failed/unobserved counts. Queued is zero because this workload has no backlog. |
| `populations[].active[].latency_ms` | Separate distributions for admitted-run outcomes, successful runs, accepted/rejected calls and driver dispatch. |
| `populations[].active[].waves[].jobs[]` | Actual attempt timings, run identity/status, effect/process observations, checks, errors and delays. |
| `populations[].active[].waves[].samples[]` | VM memory/process/port/run-queue counts, OS RSS/descendants, leases, runtime/observer mailboxes and in-flight driver attempts. |
| `populations[].saturation` | Session-capacity probe, first observed model-rejection load, lease peak and admission/resource invariants. |
| `populations[].cleanup` / `cleanup` | Population removal, supervisor/runtime/driver termination, temporary-root removal, cwd/environment preservation and live OS descendant counts. |
| `errors` / population error alternative | Safe error codes/types; unavailable work is failed or partial. |

Distributions contain `count`, `min`, `max`, `p50`, `p95` and `p99`, using nearest rank without interpolation. Empty distributions have zero count and null values. One-sample and other small sets do not establish stable tails because a p99 field exists.

### Interpret memory and pressure carefully

| Measurement | Meaning |
|---|---|
| `os.beam_rss_bytes` (`VmRSS`) | Whole BEAM resident memory, including allocator arenas, code, stacks and native allocations. |
| `beam_memory_bytes` (`:erlang.memory/0`) | VM-accounted allocated memory, not RSS. |
| `VmHWM` | Process-lifetime high-water mark; not a resettable per-population peak. |
| Live descendant RSS | Separate sum; shared pages are not deduplicated. |

VM-wide counters include Mix, the application, benchmark driver and retained evidence. Runtime mailbox/process counts traverse the actual supervision tree. Baselines are population-specific: warmup, allocator retention and earlier observations can change absolute RSS. A whole-VM delta divided by session count is not calibrated per-agent memory.

Sampling has a measured cost and can miss short-lived peaks. Empty mailboxes do not prove zero scheduling latency. Zombies, vanished processes, missing RSS and supervisor read races are recorded separately. On this stable harness, before/after descendant equality compares counts, not identities; actual Shell cleanup receipts and stopped supervisors supply separate lifecycle checks.

## Limits

- This is a finite scripted workload, not live-provider transport, reasoning quality, optimal throughput or a cross-harness performance comparison.
- Fresh sessions do not measure growing conversation history, compaction over long sessions, Eval or subagents.
- A `passed` result covers only the requested workload and its recorded invariants, not every acceptance gate, platform, OS sandbox or guest deployment.
- Preserve fingerprints and compare like-for-like configuration and host conditions. Do not treat unrelated historical runs as controlled scaling comparisons.

## Related

- [Production operations](../docs/operations.md)
- [Project status and retained reports](../docs/project-status.md)
- [Verification and evidence record](../docs/oh-my-jido/OPERATIONS_AND_EVIDENCE.md)
- [T11 process-density acceptance](../docs/oh-my-jido/ACCEPTANCE.md#t11-process-density)
