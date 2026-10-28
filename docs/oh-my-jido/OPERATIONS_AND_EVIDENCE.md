# Verification and evidence record

This record separates implemented interfaces, exercised observations and pending gates. It does **not** certify a release, subscription parity or an OS generation. [PROGRESS.md](PROGRESS.md) is the detailed capability and source-revision ledger; [ACCEPTANCE.md](ACCEPTANCE.md) defines the required gates. Evidence recorded before a source change is not a green check of that changed source. For an evaluator's summary, read [project status](../project-status.md).

## Host operating responsibilities

Production setup, storage, private-data protection, backup, capacity, platform requirements and upgrade procedures now live in [Run Oh-My-Jido in production](../operations.md). The dated observations below remain verification history, not operating instructions.

## Events and telemetry

The telemetry contract and collector example moved to [Collect telemetry without logging payloads](../operations.md#collect-telemetry-without-logging-payloads). Public event kinds and payloads are documented in the [API reference](../reference/api.md).

## Density harness: commands for the integration owner

Commands moved to [Run the density benchmark](../operations.md#run-the-density-benchmark). The [benchmark guide](../../bench/README.md) explains options, outputs, workload boundaries and interpretation. Retained measurements and their historical limits remain below.

## Current stable core and documentation pass (2026-10-22)

The [documentation pass record](evidence/docs-usability-20261022.json) covers the
rewritten user documentation and the explicitly approved fix for tool-call and
approval time limits. It binds library fingerprint
`2960370eec7a740b3abbab75179b7fcc52228a8c0d82fcd37b46e4abcdeea2fa`. The
20 October application, live-runtime and tool observations below were not rerun.

| Gate | Observed result |
|---|---|
| Full opt-in `mix ci` | 533 tests; Credo 0, Dialyzer 0/0, ExDNA 0/0 and Reach OK (`artifact://2066`) |
| Independent consumers | Plain Mix 3/3 and own-agent plugin 4/4 with `--warnings-as-errors`, after the final library change |
| Docs-site `mix ci` | 150 tests and all strict static gates (`artifact://2112`) |
| Tool-call and approval limits | Reproduced first: an agent question answered after 20 s was killed at Jido.AI 2.4's fixed 15,000 ms tool deadline. Four public-API regressions pass; three failed before the fix |
| Newcomer path | A new Mix project ran the README quick start, getting-started steps 4–8, the stricter host policy and the event inbox example against the working tree |
| Documentation | `mix docs`: 0 warnings; Markdown links and anchors: 0 problems; every generated HTML link resolves, including 4 cross-branch links checked against the `jido-v3-preview` worktree |
| [Required density](../../bench/results/density-docs-stable-call-limits-20261022.json) | 1/10/100/500, active 8/six rounds; 80,210.598 ms work; all cleanup invariants and exact OS baseline 1→1 pass |
| Density schema | Draft 2020-12 with an enforced RFC 3339 date-time checker: 0 errors |

Earlier records that report date-time validation used a format checker that did
not enforce `date-time`. A strict re-check finds 0 errors in the 2026-10-20
density report as well.

## Stable core (2026-10-20)

The [core record](evidence/core-reconciliation-20261020.json) covers stable
Jido2.4 explicit interrupted-execution reconciliation and fail-closed journals.
The [earlier stop milestone](evidence/native-stop-stable-20261020.json) separately
retains its actual Shell leader/child/Session closure proof. Those core records do
not replace the separate [complete CMS loop](evidence/editorial-complete-20261020.json),
[capped public release](evidence/docs-site-production-capped-20261020.json) or
[cold restore](evidence/docs-site-cold-restore-20261020.json) observations. External
Fly provisioning, secrets and deployment still require explicit approval.

| Gate | Observed result |
|---|---|
| Full opt-in `mix ci` |529 tests; Credo0, Dialyzer0/0, ExDNA0/0 and Reach OK after repository startup alias4.6 correction (`artifact://1672`) |
| Independent consumers | Plain Mix3/3, including a minimal no-inherited-config/no-credentials direct Read plus actual repair/control/restore; own-agent plugin4/4 |
| Explicit reconciliation | Actual native Read/Edit after host reconciliation, no model call during import, prior outcome remains uncertain; current core regressions pass |
| Malformed journal | Real corrupt checkpoint blocks overall stop even when native owner closure is confirmed; no operator eligibility for unknown records |
| Required density |1/10/100/500, active8/six rounds;80,806.87ms work; all cleanup invariants and exact OS baseline1→1 pass |
| Density schema | Draft2020-12:0 errors. The date-time check was not enforced then; a strict RFC 3339 re-check during the documentation pass also finds 0 errors |
| [Actual source/language/debug tools](evidence/real-tools-current-20261020.json) | Real AST/Edit child compile/run; ElixirLS0.31.1 navigation/diagnostics and same-LSP function/spec9 + variable2 rename; GDB15.1 counter1→3 and confirmed owned cleanup. Optional module rename refuses unproved Mix.Project; no server renameProvider/fallback claim |
| [Actual local/separate-node Observer](evidence/observer-current-20261020.json) | Registered SDK2 Action against genuine owned OTP apps; bounded/truncated metadata, unchanged private state, typed timeout/target loss, grants/root denial, unchanged Observer distribution/cookies; owned nodes/EPMD/fixtures removed. SDK2 tuple-denial message projection retained |
| [Actual real Tidewave](evidence/tidewave-current-20261020.json) | Upstream0.9.1/Bandit1.13.1 in distinct client/proxy/app VMs; exact docs/source/log/approved state and RPC/ERPC,0 denied atom growth/no on_load, timeout effect exactlyonce/no retry;0 remaining owned processes/listeners |

The [2026-10-20 density artifact](../../bench/results/density-docs-stable-reconciled-20261020.json)
records library fingerprint
`50ac2c60b770a18f6175ec3f1adf6137f92617a0e67436eae6bb8801cd3076d9`.
These are scripted native model turns and real filesystem/process effects, not
provider throughput, a scaling improvement or proof of an OS sandbox.

## Historical final-source library acceptance (2026-10-19)

The [safe final acceptance record](evidence/library-acceptance-20261019.json) reconciles 62 verified capability rows and the independent reviews' repaired findings. No publication or production/OS-sandbox certification is implied.

| Gate | Actual historical19Oct source result | Retained evidence |
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
| Independent plain-Mix consumer | Historical19Oct WAE compile and2 actual repair/control/restore scenarios (bg_115); current independent3-case result is in the current core record above | Every provider's eligibility, OS sandbox or guest integration |
| Model transformer/subscription regressions | Recorded focused set **43 passed** | Live SIWC enrollment, eligibility or subscription request success |
| Python + host continuation privacy | Dated13-test combined run covered10 Python +3 host-privacy cases; later18Oct licensed native12-case privacy/callback smoke is retained as`artifact://218`. Current opt-in529-case gate repeats the real native scenarios | Target musl/aarch64 execution, arbitrary raw BEAM message privacy or isolation from trusted host introspection |
| Context continuity | Native terminal-context/uncertain-effect/manager/lease recovery fixes pass54 focused session/runtime/Eval/context/process/model tests (`artifact://256`); version2 JSON restore and independent host question follow-up are exercised | A safe version1 migration, unbounded history or automatic effect replay |
| Authorized OpenRouter base request | Real native Jido/ReAct → ReqLLM → `openai/gpt-6-luna`, low reasoning; 552 input/9 output tokens; native pricing reported total 0.000060 | SIWC/Claude subscription, general coding/task completion or future pricing |
| Authorized semantic PNG request | Actual blue/yellow PNG image tool part through the selected native model was interpreted | Default header-only adapter pixel decoding, other formats or every image-capable model |
| Authorized OpenRouter coding repair | Actual Luna Low native repair passed: three Read calls, failing-before native Shell exit 2, guarded one-operation Edit, passing-after native Shell exit 0 and independent final Mix test exit 0; completed native checkpoint/restored run and ordered tool/progress events observed | Subscription access, arbitrary repository repair coverage, complete CI/privacy/platform/guest gates or future pricing |
| Official Claude subscription delegation | Actual unmodified2.1.282, native claude.ai login, separately approved Read+Edit-only coding repair with exact scoped native permission allowlist; unpredictable file challenge, independent test exit2→0, tests/config unchanged, existing login preserved and owned cleanup; [safe report](evidence/claude-coding-20261019.json) | Native Jido Claude subscription inference, token brokerage, Bash/MCP/network-tool authorization, OS sandbox or future eligibility/pricing |
| Native OpenAI subscription | Actual validated SIWC grant, authenticated HTTP200 `models` catalog, unpredictable real Read and native Read/Edit/Shell code repair on `gpt-6-luna`; independent failing-before2/passing-after0, exact source change, tests/config untouched, final local logout/remote revocation; safe [report](evidence/openai-subscription-20261018.json) | Every account/model's eligibility, future availability, pricing or unexercised repository coverage |
| Actual Elixir coding tools | Dated AST/Edit280 and real same-LSP function/variable/module/spec541,59 planner cases/conflicts545 and that wave's462-case gate546; not current-revision language-server proof | Server-advertised rename support, unknown native profiles or unsupported/dynamic source identity |
| Actual debugger | Dated18Oct GDB/ElixirLS breakpoint/stack/scopes/variables/step counter1→3 and owned cleanup259; current protocol baseline is separate | Live-node attach/evaluate/RPC/IEx capability or a newly repeated installed-server revision |
| Headless live Observer | Dated18Oct registered local Action496/separate-node app500 retained in[historical report](evidence/observer-reviewed-20261018.json); fresh current-source local/separate-node registered-SDK proof is linked in the current table above | GUI, arbitrary RPC/live evaluation, OS sandbox or unconfigured user-app access |
| Actual live runtime tools | Dated18Oct real Tidewave0.9.1/Bandit1.13.1 distinct-app427 retained in[historical report](evidence/tidewave-runtime-reviewed-20261018.json); fresh current-source actual service/RPC evidence is linked above, never supplied by the protocol fixture | OS sandbox, arbitrary user-app authorization or distributed-node RPC coverage from that smoke |
| Unified three-language Eval | Dated18Oct real Jido Action281 ran retained cells to42, unpredictable file Read/narrowed denial, bounded128-byte output, errors/timeouts/reset/cleanup and host cwd/env preservation across Elixir/QuickBEAM/Python. Current opt-in529-case backend gate is separate | OS sandbox, target ABI/guest execution or rollback of prior effects |
| Core durability repairs | Dated six storage-fault/opaque-ID regressions, JSON goal/check/effect retention and that wave's462-case gate546. Current529-case reconciliation/fault result is in the current core record above | Automatic storage recovery or rollback |
| Actual host Research | Dated18Oct checked Research Actions355 made exactly2 fixed Hex catalog HTTPS reads, identified QuickBEAM0.11.3 and respected256-byte untrusted output; denials made no extra request. Current authority tests are separate | General web search, fresh service availability or unknown-field schema-rejection proof |

The continuation regression was real: a signed native checkpoint token appeared in typed native Thread event data despite clearing the separate checkpoint token field. Structured checkpoint sanitization and the focused after-fix run passed. This does not authorize logging native tokens or treating signed/encoded values as harmless. The licensed optional Snakepit boundary additionally protects supported native worker diagnostics and opaque SDK envelopes; arbitrary trusted-host raw messages/introspection are not hidden or isolated.

The dated stable18Oct authorized coding scenario changed only `unit_price + quantity` to `unit_price * quantity`; tests, configuration and shipping behavior were unchanged. Native canonical aggregate usage was **21,299 input / 427 output tokens**, with reported price **USD 0.002873**. The `input`/`output` aliases describe the last turn, not that aggregate. That observation used actual `events/2` and durable native Action result tuples, restored its completed checkpoint, excluded the supplied key from public/restored views and child environment, and cleaned disposable roots. It is a dated real-provider observation, not a current native V3 run or permission to replay uncertain work.

Historical367-case gate367/consumer366 and19Oct462-case gate546/consumer bg_115 remain dated milestones, not current-source certification. Current529-case/native588-case gates, truly independent consumers and source-bound density are separate records. Optional unavailable branches never count as native execution.

## Quality and independent-host commands

The current gate definitions, Python opt-in and independent-consumer commands moved to [Run the quality gates](../project-status.md#run-the-quality-gates). A focused result is not a substitute for a full source-bound gate. Dated results above remain unchanged.
