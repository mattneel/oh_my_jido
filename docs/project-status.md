# Project status

Oh-My-Jido is an Elixir library for embedding a coding agent in your own application. This page helps you evaluate its release maturity, supported SDK tracks, verified capability areas and remaining limits. For installation and first use, start with [getting started](getting-started.md).

## Release and compatibility

The project declares version **0.1.0** and requires Elixir `~> 1.20`. It is pre-release software, installed from source; it is not published on Hex. The `master` branch uses stable Jido SDK versions, but that does not make Oh-My-Jido a stable release or a certified production deployment.

| Track | SDK versions | Important difference |
|---|---|---|
| `master` — this branch | Jido 2.4.0, Jido.AI 2.4.0, Jido Action 2.4.0, ReqLLM 1.28.0 | Uses `Jido.Storage`. Set an explicit active model or `model_roles` before inference; bare SDK aliases include a retired model. |
| `jido-v3-preview` | Jido 3.0.0-beta.1, Jido Action 3.0.0-beta.12, native V3 Jido.AI source, ReqLLM 1.28.0 | Uses `Jido.Persistence.Adapter` and valid built-in model inputs. Upstream Jido.AI still declares version 2.3.0; that metadata is not a V2 runtime or a relabelled V3 package. |

Both tracks retain patched SDK snapshots for private diagnostics. Use the branch's complete [installation recipe](getting-started.md), not independently selected replacements. Source pins and patch scope are recorded in [`vendor/jido/UPSTREAM.json`](../vendor/jido/UPSTREAM.json) and [`vendor/req_llm/UPSTREAM.json`](../vendor/req_llm/UPSTREAM.json); the preview also has Jido.AI and Jido Action provenance files. There is no automatic V2-to-V3 checkpoint conversion.

The exercised platform is Linux x86_64 with Elixir 1.20.2 / OTP 28. Optional tools have additional executables, compiled components and application-owned services; see [platform requirements](operations.md#platform-requirements).

## What has been verified

The [capability ledger](oh-my-jido/PROGRESS.md#capability-status) records 62 in-scope library rows as verified. It distinguishes current source-bound tests from dated live-provider and external-tool observations. A verified interface is not a promise that every provider, server version, operating system or application integration works.

| Capability area | Exercised behavior | Where to look |
|---|---|---|
| Embedding and lifecycle | Named runtimes, instance isolation, ordered events, questions/approvals and their time limits, steering/cancellation, checkpoints, restart recovery and explicit interrupted-execution reconciliation | [Core evidence](oh-my-jido/evidence/core-reconciliation-20261020.json), [documentation pass](oh-my-jido/evidence/docs-usability-20261022.json), [plain Mix example](../examples/plain_mix/README.md), [own-agent example](../examples/jido_agent/README.md) |
| Models and accounts | Six roles, explicit account selection, credential isolation, usage/error handling and durable context policy | [Capability ledger](oh-my-jido/PROGRESS.md), [models and accounts](guides/models-and-accounts.md) |
| Repository work | Exact/ranged/binary reads, ignore-aware discovery/search, snapshot-guarded writes/edits, real Linux processes, Git/worktrees and real test-driven repairs | [Core evidence](oh-my-jido/evidence/core-reconciliation-20261020.json), [actual AST/Edit/LSP/DAP tools](oh-my-jido/evidence/real-tools-current-20261020.json) |
| Language intelligence | Structural Elixir edits, actual ElixirLS navigation/diagnostics, explicit same-LSP function/spec and variable rename, and actual GDB breakpoint/inspection/stepping with cleanup | [Actual tools record](oh-my-jido/evidence/real-tools-current-20261020.json) |
| Live applications | Bounded headless Observer against local and separate-node OTP applications; real Tidewave docs/source/logs and explicitly approved evaluation/RPC against an owned target | [Observer](oh-my-jido/evidence/observer-current-20261020.json), [Tidewave](oh-my-jido/evidence/tidewave-current-20261020.json) |
| Cooperation and extensions | Narrowed subagents, isolated writable workspaces, parent control, memory/plans/checks/experiments, native skills, custom Actions and checked adapter contracts | [Capability ledger](oh-my-jido/PROGRESS.md), [tools](guides/tools.md), [subagents](guides/subagents.md) |
| Eval | Persistent Elixir and JavaScript in separate ERTS instances, exclusive Python workers, checked tool bridges, bounded output, cancellation/reset and no automatic replay after state loss | [Core opt-in gate](oh-my-jido/evidence/core-reconciliation-20261020.json), [Eval guide](guides/eval.md) |
| Source-first docs application | Real agent tool loop, operator controls, immutable checks/release preview, drift refusal, exact-digest approval, local publication/adoption and a new Read of adopted source | [Complete loop](oh-my-jido/evidence/editorial-complete-20261020.json), [capped public release](oh-my-jido/evidence/docs-site-production-capped-20261020.json), [cold restore](oh-my-jido/evidence/docs-site-cold-restore-20261020.json) |
| Capacity and observability | Immediate refusal at bounded capacity, typed events, metadata-only telemetry, idle populations, real file/process work and cleanup | [Density report](../bench/results/density-docs-stable-call-limits-20261022.json), [benchmark guide](../bench/README.md) |

Dated live-account evidence is separate: [OpenAI Sign in with ChatGPT](oh-my-jido/evidence/openai-subscription-20261018.json) exercised managed Read and a real coding repair; [official Claude Code delegation](oh-my-jido/evidence/claude-coding-20261019.json) exercised a separately approved Read/Edit-only repair. The ledger also retains authorized OpenRouter and semantic-image observations. These are observations for the recorded account, model and source, not current availability, subscription parity, future pricing or fresh V3 provider runs.

## Latest retained quality records

The following records are dated **22 October 2026** and bind the final source of the documentation pass, including the tool-call and approval time-limit fix. Each record names its source fingerprints; later source changes need their own gate. The other records linked on this page are dated 20 October 2026 or earlier and were not rerun. The docs-site gate below reran that application's test suite, not its browser loop, capped release or cold-restore observations.

| Gate on `master` | Recorded result | Record |
|---|---|---|
| Full library `mix ci`, with Python opt-in | 533 tests; strict Credo: 0 issues; Dialyzer: 0 errors/0 skips; ExDNA: 0 clones; Reach: OK | [Documentation pass](oh-my-jido/evidence/docs-usability-20261022.json) |
| Independent consumers | Plain Mix: 3 cases; own-agent integration: 4 cases; no inherited repository configuration | [Documentation pass](oh-my-jido/evidence/docs-usability-20261022.json) |
| Docs-site `mix ci` | 150 tests and strict static gates | [Documentation pass](oh-my-jido/evidence/docs-usability-20261022.json) |
| Newcomer path | README quick start, getting-started steps 4–8, the stricter host policy and the event inbox example, run from a new Mix project | [Documentation pass](oh-my-jido/evidence/docs-usability-20261022.json) |
| Required density workload | Populations 1/10/100/500, active capacity 8, six rounds; cleanup invariants passed; JSON Schema 2020-12 with enforced RFC 3339 date-time: 0 errors | [Density report](../bench/results/density-docs-stable-call-limits-20261022.json), [schema](../bench/density.schema.json) |

The density run uses scripted model responses and simulated gateway delays with real filesystem/process effects. It is not provider throughput, a comparison with another harness, an optimal-concurrency recommendation or calibrated per-agent RSS. The public docs release record measures a local capped process scope, not an entire Fly guest; the disposable cold-restore archive is not a production encrypted backup or credential-vault recovery test.

Full dated results, source fingerprints and historical milestones remain in the [verification and evidence record](oh-my-jido/OPERATIONS_AND_EVIDENCE.md) and [PROGRESS.md](oh-my-jido/PROGRESS.md). [ACCEPTANCE.md](oh-my-jido/ACCEPTANCE.md) defines the gates. Older records remain useful history, not certification of a later source revision.

## Run the quality gates

Follow the repository's [AGENTS.md](../AGENTS.md) guidance. From the project root:

```sh
mix deps.get
mix ci
```

The root `ci` alias uses the test environment and runs warnings-as-errors compilation, formatter checking, tests, strict Credo, Dialyzer, ExDNA with a zero-clone budget and Reach architecture/smell checks. A focused test or smoke run does not replace that gate. Normal tests need no paid model credentials.

To exercise the real Python cases, provision the approved Python environment and Snakepit's infrastructure first. For example, substituting your actual executable:

```sh
OH_MY_JIDO_PYTHON_EVAL=1 SNAKEPIT_PYTHON=/srv/my_app/python/bin/python MIX_ENV=test mix test test/eval_python_test.exs
```

Use the same opt-in environment when running `mix ci` for full Python-inclusive acceptance. Snakepit configuration can select the executable instead of the environment override. A skipped opt-in test is not Python integration verification; this command does not install Python or change the VM environment per session.

The independent [plain Mix consumer](../examples/plain_mix/README.md) has its own dependency graph, lockfile and build directory. From `examples/plain_mix`, with the pinned sources already installed:

```sh
HEX_OFFLINE=1 MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

Run the [own-agent consumer](../examples/jido_agent/README.md) separately, and use [the density harness](../bench/README.md) for its own acceptance command. Native scripted responses are enabled only in explicitly trusted test runtimes; production `allow_test_scripts` defaults to `false`. None of these commands is run automatically by embedding the library.

Run `mix docs` to build the API reference, guides and examples into `doc/`. No Hex or HexDocs publication is claimed.

## Known limits

- **Not an OS sandbox.** Workspace paths, permissions, process ownership and separate interpreters are library boundaries. Your application owns untrusted execution, network policy, secret separation, resource isolation and deployment.
- **Bounded work, not a job queue.** Capacity saturation rejects work. Run/effect history is finite, recent events can expire and slow subscribers are detached. Your application owns archival retention and any backlog.
- **No blind replay or rollback.** Interrupted effects stay uncertain until explicitly reconciled. Checkpoints do not snapshot repository files or restore live Eval/server/browser processes. ContextPolicy v2 rejects old policy checkpoints; SDK-track changes require a clean cutover.
- **External integrations are opt-in.** Configuring MCP, browser, research, LSP/DAP, Tidewave or Eval does not provision its service. Unsupported operations remain unavailable. Default artifact/image metadata handling does not promise pixel decoding or every media format.
- **Language-server support is scoped.** Tested with ElixirLS 0.31.1 and GDB 15.1. ElixirLS does not advertise server rename; the explicitly selected Elixir backend handles supported identities without silent fallback. Optional module rename refuses an unproved Mix.Project inventory. DAP is not live-node RPC/IEx access.
- **Observer is metadata inspection.** Snapshots are bounded and non-atomic, need explicit targets/permissions and do not provide a GUI or arbitrary evaluation. Tidewave's separately approved live evaluation is not a substitute for isolated Eval.
- **Model access is account-specific.** On `master`, configure an active model explicitly. OpenAI subscription eligibility remains account/model-specific. Official Claude Code is a delegated agent, not Claude credential brokerage or native third-party subscription inference. Failed subscription calls do not fall back to separately billed API use.
- **Platform evidence is Linux x86_64.** macOS, Windows, Linux aarch64, musl/guest packaging and new compiled-library ABI combinations are not verified by these records.

## Out of scope: Elixos guest work

The library delivery excludes capability rows F06/F07 and guest scenario T10 by explicit scope decision. Elixos owns its adapter, target/OS image packaging, guest boot/health, generation provenance, promotion, COMMIT and fallback. These are external work, not passed library capabilities or remaining Oh-My-Jido tasks. Historical [Elixos examples](../examples/elixos/README.md) do not prove guest delivery or authorize external changes.

The generic `OhMyJido.Host` contract and independent Elixir application embedding remain part of the library. External Fly provisioning, secret installation and deployment are also separate approval-controlled effects, not a consequence of local release evidence. Publishing repository branches did not publish a package or deploy an application.

## Related

- [Getting started](getting-started.md)
- [Production operations](operations.md)
- [Verification and evidence record](oh-my-jido/OPERATIONS_AND_EVIDENCE.md)
- [Detailed capability ledger](oh-my-jido/PROGRESS.md)
