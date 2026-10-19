# Operations, evidence and Elixos ownership

This document separates implemented interfaces, exercised observations and pending gates. It does **not** certify the capability matrix, a release, subscription parity or an OS generation. [PROGRESS.md](PROGRESS.md) remains the integration owner's exact current-revision ledger; [ACCEPTANCE.md](ACCEPTANCE.md) defines required gates. Evidence recorded before a source change is not a green check of that changed source.

## Host operating responsibilities

Before admitting work:

- Supervise explicit named runtimes; choose finite session/run/effect/resource ceilings and a private durable store.
- Give each session an existing canonical workspace, minimal registered Actions and grants. Choose actual OS containment before shell/Eval/candidate/native execution over untrusted code.
- Supervise account brokerage and approval presentation outside the model; keep vault keys/tokens out of repo, argv, model input and generation images.
- Keep native ReqLLM debug off and use the approved Jido/ReqLLM diagnostic snapshots, plus licensed Snakepit private diagnostics when Python is enabled. Export metadata, not raw native state.
- Provision optional native libraries/executables/servers deliberately, with target/ABI/licensing checks. An entry in `adapters`/`eval.backends` is not proof the service exists.
- Own adapter cancellation/teardown and identity rebuilding after host restart. Journal uncertainty instead of automatically replaying effects.
- Archive run/effect/session histories according to host policy; capacity refusal is deliberate, not an undocumented infinite queue.

No session changes the host VM cwd/environment. Check external packages' host-startup behavior too: the curated Python infrastructure path avoids upstream Snakepit application's global-environment/installer bootstrap. Scrub inherited secret environment/mount/code access through the actual worker isolation policy; never rely on a bridge API to hide secrets from arbitrary code running under the same OS user.

## Events and telemetry

The stable host envelope is documented in [the API reference](PUBLIC_API.md#events). Keep question handling responsive while another caller awaits completion. Track event cursors and re-subscribe explicitly if a consumer was detached; a bounded event ring is not a guaranteed audit log. Host-only inspections include an intentional native PID and private conversation/evidence; do not serialize/export the whole map.

The harness emits:

```elixir
[:oh_my_jido, :event]
# measurements: %{seq: integer, at_ms: integer}
# metadata: %{session_id: binary, kind: atom}
```

Installed native telemetry supplies Jido command/signal/directive/queue-overflow events, `[:jido, :ai, :request, ...]`, `[:jido, :ai, :llm, ...]`, `[:jido, :ai, :tool, ...]`, and ReqLLM request/reasoning/usage events. AI normalized measures include `duration_ms`, token counters, retry count and queue_ms where observed. ReqLLM `duration` is native monotonic time, not milliseconds; convert with `System.convert_time_unit/3`. Missing usage/queue measurements are not synthetic zero-latency evidence.

A metadata-only collector can use the actual Telemetry API without logging payloads:

```elixir
:telemetry.attach(
  "my-app-coding-event-count",
  [:oh_my_jido, :event],
  fn _event, measurements, metadata, collector ->
    send(collector, {:coding_event_metric, metadata.kind, measurements.seq, measurements.at_ms})
  end,
  self()
)
```

Use a supervised host collector in production and detach the handler at its lifecycle boundary. Do not perform slow synchronous work inside a telemetry handler. Credential-bearing native turns force ReqLLM `payloads: :none`; never turn on raw payload capture to debug live tokens. Redaction and native diagnostic patches have a documented scope, not a promise that arbitrary host/native crash logs are safe.

Monitor actual counts/latency/errors, active admission, mailbox pressure, port/OS descendants, resource cleanup, pending questions, usage/plan errors and uncertain effects. The core has immediate admission refusal, **not** a generic model queue. Distinguish native queue/scheduler pressure, client mailbox delays and host-added backlog. UI output/plan status is not proof the repository test suite passed.

## Density harness: commands for the integration owner

[`bench/density.exs`](../../bench/density.exs), [its operational reference](../../bench/README.md) and [schema](../../bench/density.schema.json) implement a human-invoked credential-free native workload. Nothing in `bench/` is loaded by the library application. Use these only after integration edits have stopped; no command below was run by this documentation task.

Full required populations, selecting a new output file:

```sh
MIX_ENV=test mix run bench/density.exs -- --output bench/results/density-full.json
```

Default populations are **1, 10, 100, 500**, active ceiling 8, six repetitions per distinct offered concurrency, idle observation 250 ms and sample interval 25 ms. Simulated gateway delays are 120/240/180/300 ms; authorized read/edit/exec delays are 10/20/10 ms; actual subprocess sleeps are 80/160/120/240 ms. Tool/run/workload deadlines default to 5,000/15,000/180,000 ms, with separate bounded teardown. The offered sweep includes one excess offered task where the population permits it, and a final session-capacity probe.

The smaller source-backed smoke command is:

```sh
MIX_ENV=test mix run bench/density.exs -- --populations 1,3 --active 1 --rounds 1 --idle-ms 25 --model-ms 10,15,10,15 --tool-ms 1,2,1 --process-ms 10,20 --run-timeout-ms 3000 --tool-timeout-ms 1000 --deadline-ms 20000 --output bench/results/density-smoke-new.json
```

Linux procfs and `sh`, `setsid`, `mkfifo`, `cat`, `kill`, `sleep` are required. Existing evidence files are refused rather than overwritten; choose a new path or omit output to get a unique timestamped path. Preserve the emitted JSON artifact and schema/fingerprints, not only a terminal summary.

The installed Jido.AI scripted loop calls real Read, snapshot-guarded Write and Shell. The harness checks actual bytes/digests/process exit/cleanup, separate output streams, receipts and child-only cwd/env observations. Gateway delays are simulated inside the native transformer, **not provider RTTs**. Each job's fixture slot is replaced outside measured run latency; this is not growing-history, Eval, subagent or live-provider throughput.

Reports distinguish offered/admitted/rejected/completed outcomes, accepted/rejected call latency, run latency, driver dispatch, actual leases/mailboxes/VM run queues and cleanup. Rejected runs are not automatically queued/retried. Small nearest-rank p50/p95/p99 sets do not establish stable tails. OS RSS (`VmRSS`), VM-allocated memory (`:erlang.memory`), process-lifetime `VmHWM` and descendant RSS sums are different measurements. Per-population empty-runtime baselines include Mix/driver/native code and allocator effects; do not divide a changing whole-VM delta by N and present it as proven per-agent memory.

## Final-source library acceptance (2026-10-19)

The [safe final acceptance record](evidence/library-acceptance-20261019.json) reconciles all62 in-scope capability rows, the explicitly excluded external Elixos gates and the independent reviews' repaired findings. No publication or production/OS-sandbox certification is implied.

| Gate | Actual final-source result | Retained evidence |
|---|---|---|
| Full opt-in`mix ci` |462 tests including12 actual Python cases; strict Credo0, Dialyzer0/0, ExDNA0/0, Reach OK |`artifact://546` |
| Independent plain-Mix host | WAE compile and2 actual repair/control/restore scenarios pass | bg_115;`examples/plain_mix` |
| Required native density |1/10/100/500 populations, active8;330 offered,312 completed,18 capacity refusals,0 report errors | [final report](../../bench/results/density-native-tools-20261019.json);`artifact://548` |
| Evidence schema | Draft2020-12 plus date-time formats:0 errors; every population/resource/admission/teardown invariant passes | Actual validator and final JSON |

The density report's literal UTC time is`2026-10-19T12:01:17.041908Z`, elapsed work76,497.176ms, on4 schedulers. Library fingerprint`ef8367d8dc4730caf403bfa6afa59a657039230c9b6499bd2e49b9ddb1fb0e7d`; benchmark fingerprint`fd2315bf483bca51fb295d38b5247ab7193a9769e7e3d04bbf5c60bea5f38448`. Runtime/driver/supervisor stop, disposable-root removal, unchanged cwd/environment and live descendants1→1 are confirmed. This is native scripted filesystem/process work with simulated gateway latency, not provider RTT/throughput or calibrated per-agent memory.

## Actual recorded Linux x86_64 full density run

The retained [`bench/results/density.json`](../../bench/results/density.json) reports the required **1/10/100/500** populations, active capacity **8**, six rounds and `result: "passed"` with no report errors. Its literal UTC timestamp is `2026-10-14T02:39:26.907752Z`; elapsed benchmark work is **83,927.167 ms** (not command startup/compilation wall time). It records the same Linux x86_64/32-scheduler/Elixir 1.20.2/OTP 28/ERTS 16.4.0.2 host as the earlier smoke.

The historical report retains exact configuration, samples and fingerprints: source`b0fa63e41547ddabb5aabc84017f3f89b74b64b9eaa7c5291eca8ba6b3ed4b83`, benchmark`fd2315bf483bca51fb295d38b5247ab7193a9769e7e3d04bbf5c60bea5f38448`. Its Draft2020-12 validation returned0 errors.

The retained pre-rename/live-tool [`density-final-20261018.json`](../../bench/results/density-final-20261018.json) passed all required populations with312 completed jobs,0 errors and confirmed cleanup, at`2026-10-18T18:43:25.309855Z`. Benchmark work was78,155.147ms on4 schedulers; source fingerprint`8d4f12a22d7b6970a2d16091e090ca5d95db10c5c4c407c1ba73bfa331177c70`, unchanged benchmark fingerprint. Actual Draft2020-12 plus date-time validation returned0 errors. It is historical; the separate19Oct final-source report above covers subsequent features. The following historical32-scheduler table is not a calibrated comparison or per-agent memory claim.

| Population | Empty-runtime RSS | Idle RSS | Observed RSS delta | Observed VM-allocated delta | BEAM process delta |
|---|---:|---:|---:|---:|---:|
| 1 | 380,948,480 B | 653,639,680 B | 272,691,200 B | 68,307,992 B | 3 |
| 10 | 426,655,744 B | 427,417,600 B | 761,856 B | 1,555,504 B | 30 |
| 100 | 527,183,872 B | 526,626,816 B | −557,056 B | 14,041,904 B | 300 |
| 500 | 551,456,768 B | 594,206,720 B | 42,749,952 B | 70,930,072 B | 1,500 |

Every population's recorded idle invariant passed. The largest population had 500 actual coordinators/native agent roots; admission refused session 501 in **0.109 ms**. Differing baselines, observed code/allocator activity and a negative RSS delta still prevent interpreting these deltas as calibrated per-agent RSS.

Representative bounded active workloads, with all six waves included:

| Population / offered concurrency | Admitted / rejected / completed | Completed samples | Completed-run p50 / p95 / p99 |
|---|---|---:|---|
| 1 / 1 | 6 / 0 / 6 | 6 | 1,121.899 / 1,889.459 / 1,889.459 ms |
| 10 / 8 | 48 / 0 / 48 | 48 | 1,262.901 / 1,314.979 / 1,325.322 ms |
| 100 / 8 | 48 / 0 / 48 | 48 | 1,262.806 / 1,314.267 / 1,332.781 ms |
| 500 / 8 | 48 / 0 / 48 | 48 | 1,255.572 / 1,317.267 / 1,321.266 ms |

Each 10/100/500 population also offered concurrency 9: 54 attempts admitted/completed 48 and rejected 6 at model capacity, with no failed/unobserved admitted jobs and no queue/retry. Sampled model leases peaked at 8; first observed model rejection was 9. Runtime/supervisor/driver teardown, disposable-root removal and host cwd/env preservation are recorded true; live OS descendant counts returned from 1 to 1. Population removal was confirmed for each population.

This is a real finite native scripted-workload result, **not** a provider-latency benchmark, comparison against another harness, optimal-throughput claim, OS sandbox proof or aarch64/guest result. The full required populations are now measured; broader acceptance/platform/live evidence and the complete quality gate remain separate.

## Actual recorded Linux x86_64 density smoke

The retained [`bench/results/density-smoke.json`](../../bench/results/density-smoke.json) reports `schema: "oh_my_jido.density"`, `schema_version: 1`, `result: "passed"`, no report errors and elapsed **5,051.450 ms**. Its literal recorded UTC timestamp is `2026-10-14T01:24:42.860908Z`.

Host recorded in that artifact: Linux x86_64 (`x86_64-pc-linux-gnu`), kernel `7.2.6-locietta-WSL2-xanmod1`, AMD Ryzen 9 9955HX3D, 32 online schedulers/logical processors, Elixir 1.20.2 / OTP 28 / ERTS 16.4.0.2. The report retains memory/cgroup limits, source fingerprints and loaded BEAM hashes; these observations belong to that measured source/workload, not later worktree changes.

| Population | Empty-runtime RSS | Idle RSS | Observed idle RSS delta | Observed VM-allocated delta | BEAM process delta |
|---|---:|---:|---:|---:|---:|
| 1 | 404,193,280 B | 714,403,840 B | 310,210,560 B | 71,513,624 B | 3 |
| 3 | 650,551,296 B | 651,485,184 B | 933,888 B | −197,672 B | 9 |

The differing baselines and negative second VM delta make a per-agent scaling claim inappropriate. This finite smoke's admission/results are:

| Population / offered concurrency | Admitted / rejected / completed | Completed-run p50/p95/p99 |
|---|---|---|
| 1 / 1 | 1 / 0 / 1 | 706.388 / 706.388 / 706.388 ms (one sample) |
| 3 / 1 | 1 / 0 / 1 | 295.910 / 295.910 / 295.910 ms (one sample) |
| 3 / 2 | 1 / 1 / 1 | 235.264 / 235.264 / 235.264 ms (one admitted sample) |

With active capacity 1, concurrency 2 produced the observed model-capacity rejection. The three-session probe admitted 3/refused the fourth in 3.085 ms. No queue was used. Supervisor/runtime/driver teardown and disposable-root removal were reported true; host cwd/env remained unchanged and live descendant counts returned from 1 to 1. Count equality is not a process-identity proof; the report separately checks real process/group cleanup.

This earlier artifact is **only 1/3 smoke evidence** and cannot alone establish the required populations or a density improvement. The separate full 1/10/100/500 observation above now records those populations; neither report claims comparable platform/live throughput or complete acceptance.

## Other exercised observations and limits

These results were exercised by the integration owner, not by this documentation task. Retained output identifiers and dated details belong in [PROGRESS.md](PROGRESS.md).

| Observation | Evidence actually observed | What it does not establish |
|---|---|---|
| Cold root warnings-as-errors/Boundary compilation | Clean cold compiler boundary output recorded | Complete `mix ci`, deliberate forbidden-reference gate or all post-edit checks |
| Separate Elixir + QuickBEAM kernels | 27 actual native backend scenarios passed in the recorded focused run | OS sandbox, aarch64/guest packaging or generic native memory safety |
| Independent plain-Mix consumer | Final source WAE compile and2 actual repair/control/restore scenarios pass (bg_115), with independently resolved dependencies and no optional backends | Every provider's eligibility, OS sandbox or guest integration |
| Model transformer/subscription regressions | Recorded focused set **43 passed** | Live SIWC enrollment, eligibility or subscription request success |
| Python + host continuation privacy | Earlier13-test combined run covered10 Python +3 host-privacy cases. Current licensed native Python suite passes all12 cases, including actual worker exit, sys-debug/queued-request and callback faults (`artifact://218`) | Target musl/aarch64 execution, arbitrary raw BEAM message privacy or isolation from trusted host introspection |
| Context continuity | Native terminal-context/uncertain-effect/manager/lease recovery fixes pass54 focused session/runtime/Eval/context/process/model tests (`artifact://256`); version2 JSON restore and independent host question follow-up are exercised | A safe version1 migration, unbounded history or automatic effect replay |
| Authorized OpenRouter base request | Real native Jido/ReAct → ReqLLM → `openai/gpt-6-luna`, low reasoning; 552 input/9 output tokens; native pricing reported total 0.000060 | SIWC/Claude subscription, general coding/task completion or future pricing |
| Authorized semantic PNG request | Actual blue/yellow PNG image tool part through the selected native model was interpreted | Default header-only adapter pixel decoding, other formats or every image-capable model |
| Authorized OpenRouter coding repair | Actual Luna Low native repair passed: three Read calls, failing-before native Shell exit 2, guarded one-operation Edit, passing-after native Shell exit 0 and independent final Mix test exit 0; completed native checkpoint/restored run and ordered tool/progress events observed | Subscription access, arbitrary repository repair coverage, complete CI/privacy/platform/guest gates or future pricing |
| Official Claude subscription delegation | Actual unmodified2.1.282, native claude.ai login, separately approved Read+Edit-only coding repair with exact scoped native permission allowlist; unpredictable file challenge, independent test exit2→0, tests/config unchanged, existing login preserved and owned cleanup; [safe report](evidence/claude-coding-20261019.json) | Native Jido Claude subscription inference, token brokerage, Bash/MCP/network-tool authorization, OS sandbox or future eligibility/pricing |
| Native OpenAI subscription | Actual validated SIWC grant, authenticated HTTP200 `models` catalog, unpredictable real Read and native Read/Edit/Shell code repair on `gpt-6-luna`; independent failing-before2/passing-after0, exact source change, tests/config untouched, final local logout/remote revocation; safe [report](evidence/openai-subscription-20261018.json) | Every account/model's eligibility, future availability, pricing or unexercised repository coverage |
| Actual Elixir coding tools | Native AST/Edit280 and real same-LSP function/variable/module/spec workflow541 pass independent child tests.59 planner cases,4 actual native conflicts545 and final462-case quality gate546 pass; compiler-owned/spec findings reproduced before repair | Server-advertised rename support, unknown native profiles or unsupported/dynamic source identity |
| Actual debugger | GDB and ElixirLS DAP breakpoint/stack/scopes/variables/step counter1→3 and owned cleanup (`artifact://259`) | Live-node attach/evaluate/RPC/IEx capability |
| Headless live Observer | Registered local Action496 and separate-node actual OTP app500 pass; bounded5,000-process/typed-timeout probes,11 behavior cases and final full gate546 pass. Private-state exclusion, target preservation and owned teardown; [reviewed report](evidence/observer-reviewed-20261018.json) | GUI, arbitrary RPC/live evaluation, OS sandbox or unconfigured user-app access |
| Actual live runtime tools | Native Tidewave0.9.1/Bandit1.13.1 approved docs/source/logs/live-state/RPC pass in distinct app VM427. Denied source lookups cause0 atom growth/no loading; native uncertainty/teardown and final full gate546 pass; [reviewed report](evidence/tidewave-runtime-reviewed-20261018.json) | OS sandbox, arbitrary user-app authorization or distributed-node RPC coverage from this smoke |
| Unified three-language Eval | Same real Jido Action ran retained cells to42, read an unpredictable actual file, denied its narrowed grant, bounded128-byte output, reported errors/timeouts, explicitly reset state and confirmed cleanup/host cwd/env preservation for Elixir/QuickBEAM/Python (`artifact://281`) | OS sandbox, target ABI/guest execution or rollback of prior effects |
| Core durability repairs | Six native storage-fault/opaque-ID regressions, actual JSON goal/check/effect-retention workflow and final462-case full gate546 pass without replay | Automatic storage recovery or rollback |
| Actual host Research | Native checked Actions made exactly2 successful fixed Hex catalog HTTPS reads, identified QuickBEAM0.11.3 and respected256-byte untrusted output; denials caused no additional requests (`artifact://355`) | General web search or unknown-field schema-rejection proof |

The continuation regression was real: a signed native checkpoint token appeared in typed native Thread event data despite clearing the separate checkpoint token field. Structured checkpoint sanitization and the focused after-fix run passed. This does not authorize logging native tokens or treating signed/encoded values as harmless. The licensed optional Snakepit boundary additionally protects supported native worker diagnostics and opaque SDK envelopes; arbitrary trusted-host raw messages/introspection are not hidden or isolated.

The current passing authorized coding scenario changed only `unit_price + quantity` to `unit_price * quantity`; tests, configuration and shipping behavior were unchanged. Native canonical aggregate usage was **21,299 input / 427 output tokens**, with reported price **USD 0.002873**. The `input`/`output` usage aliases represent the last turn, not that aggregate. Evidence collection uses the actual API shapes: `events/2` returns a list, and journal `effects[id].result` can retain native `{:ok, payload, directives}` tuples. The completed native checkpoint restored a completed run; the supplied key was absent from public/restored views and removed from the child environment. Disposable roots were cleaned. This is the current passing real-tool/live-provider observation; it does not replay uncertain work or declare a goal gate complete.

The historical pre-feature367-case gate367 and independent consumer366 are retained separately from final-source462-case gate546, independent host bg_115 and new full density/schema above. Focused native proofs are not substituted for those integrated gates. Optional unavailable branches are not native execution proof. Linux aarch64/Elixos guest packaging/promotion remains explicitly external, not passed.

## Quality and independent-host commands

After all slices land, the main integration owner runs the repository's generated instructions:

```sh
mix deps.get
mix ci
```

The actual `ci` alias uses test environment and runs warnings-as-errors compilation, formatter check, tests, strict Credo, Dialyzer, ExDNA zero-clone check and Reach architecture/smells. All rows remain subject to the required acceptance evidence; documentation or a focused passing subset does not make that alias green.

The independent plain host has its own project/lock/build. From `examples/plain_mix`:

```sh
HEX_OFFLINE=1 MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

It reuses already installed sources and pinned native overrides, not a published package. Its tests authorize native scripts only in test-owned runtimes and still execute real tools. Production `allow_test_scripts` remains false. The example README includes its formatter/operator guidance; those commands are not auto-invoked by the library.

The real native Python suite is separately opt-in after the approved environment/native components are available:

```sh
OH_MY_JIDO_PYTHON_EVAL=1 SNAKEPIT_PYTHON=/srv/my_app/python/bin/python MIX_ENV=test mix test test/eval_python_test.exs
```

Use a real preprovisioned executable instead of that illustrative host path; native config can select it instead of an environment override. This is not an installer, a credentials command or an instruction to alter the VM per session. Default skipped opt-in tests must not be reported as native backend success.

## Elixos: host-owned integration and operational workflow

The separately owned [Elixos example and guest workflow](../../examples/elixos/README.md) is the executable integration reference. It compiles selected **actual current Elixos service source** into an independent host application; core Oh-My-Jido has no Elixos imports/dependency or OS boot callback. Source compilation/fixtures are not the complete OS baseline or a guest boot.

Host service mapping:

- `Elixos.Session` captures the requester's group-leader-specific cwd **before** crossing Agents/Runtime; no VM-global cwd/env changes.
- `Elixos.Agents` owns the adapter's lifecycle and identity-only snapshots. Oh-My-Jido/Jido storage owns coding conversations/checkpoints; native PIDs/account credentials are not Elixos lifecycle snapshots.
- `Elixos.Ask` supplies real confirmations/clarifications. Only the host's explicit boolean consent grants sensitive effects; defaults/dismissals/timeouts/late replies do not.
- `Elixos.Browser`/CDP stays host-owned. The example's singleton lease requires exclusive routing and enforced network/script boundaries; release does not close the shared native page or isolate cookies/storage. Core close/click/fill remain unavailable on that native API.
- `Elixos.Candidate`, Health, Image and control/shim services own builds, suites, provenance, NEXT, reboot/health/COMMIT and fallback. `Elixos.Privileges`/fixed helpers remain independent host capability grants; the library does not provide host-root helpers or arbitrary UID/argv escalation.

The source-backed operator flow is:

1. Create/check out an isolated candidate workspace through actual `Elixos.Candidate.checkout/1` and bind the requester's root with `Elixos.Session.cd/1`.
2. Open `ElixosHost` under host supervision; grant only the needed core Actions/account. Receive coding/Ask evidence through the existing UI.
3. If separately approved, grant `:candidate` and register `ElixosHost.Tools.Candidate` through `OhMyJido.register_tool/2`. Its exact tool name is `"elixos_candidate"`; operations are build/test/evidence/provenance/propose.
4. Supply trusted build options: actual system source/dependency location, target/tool suites/timeouts and generation parent. The adapter records durable library identity, selected model and hashes of actual registered tool BEAMs. Models cannot supply provenance, service PIDs, host MFAs or build policy.
5. Build/test in non-distributed data-only child ERTS, inspect immutable evidence and actual Health outcomes. Those VMs are not filesystem/network sandboxes: authored execution needs the approved host boundary.
6. Proposal requires all of `:deploy`, trusted `deployment_enabled: true` and fresh human confirmation. Defaults disable deployment. A successful proposal reports NEXT written, **not promotion acknowledged**, and never implicitly reboots or COMMITs.
7. The operator/Elixos established boot flow owns normal NEXT → reboot → health → COMMIT and defective-candidate fallback. Protected factory/OTP/Elixir modules cannot be overwritten through a candidate overlay, bypassed or unstuck.

**Current human scope override:** Elixos integration belongs on the Elixos side and is excluded from this library delivery. Historical source/build approvals and observations do not authorize more external work. No further external repository changes, images, QEMU or guest effects are scheduled here; existing external work is left untouched. The generic Host contract and independent plain-Mix demonstration remain library requirements.

Factory packaging is pinned to OTP **29.1.1** / Elixir **1.20.4**, distinct from the measured host OTP 28 / Elixir 1.20.2. Compile/build/test candidate/factory code in the approved child/factory toolchain, not by loading authored OS modules or running its build inside host ERTS. New Elixos runtime dependencies require its own ADR/packaging/lock approval. The independent example does not prove the live OS already ships this integration or its optional native backends.

This section is a historical ownership reference, not a remaining library action plan. No Elixos packaging, promotion, COMMIT/fallback or provider gate is declared complete by these documents.
