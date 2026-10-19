# Capability matrix: what full delivery means

This matrix defines practical capabilities, not Oh My Pi implementation parity.
Each row requires a public test or host integration proof before the status becomes `verified`.
Update row status in `PROGRESS.md`. Preserve a blocker if access or provider policy prevents verification.

## A. Embedding and agent lifecycle

| ID | Required capability | Observable behavior |
|---|---|---|
| A01 | Embeddable package | A plain Elixir app starts the harness under its supervisor without a CLI process |
| A02 | Jido agent runtime | Model turns and Jido Actions run through current Jido/Jido.AI APIs |
| A03 | Multi-instance isolation | Independent host instances separate sessions, credentials, and tool policies |
| A04 | Typed events | Caller sees ordered model, tool, approval, error, and subagent events |
| A05 | Control | Caller can steer, stop, cancel, inspect, and resume sessions |
| A06 | Durable sessions | Conversation, checkpoints, and state survive deliberate worker restart |
| A07 | Fault recovery | Worker failure does not terminate the host app or replay uncertain effects |
| A08 | Bounded concurrency | Sessions, subagents, Eval, and model calls respect configurable budgets |

## B. Models, authentication, and prompt intelligence

| ID | Required capability | Observable behavior |
|---|---|---|
| B01 | Provider transport | Jido.AI and ReqLLM handle streaming, tool calls, errors, and usage data |
| B02 | Model roles | Host config chooses coding, planning, exploration, review, advisor, and compaction roles |
| B03 | Account switching | Sessions choose credential references without sharing tokens or account state |
| B04 | Codex subscription | Approved ChatGPT/Codex login, refresh, logout, and live agent smoke test |
| B05 | Claude authorization | Approved Claude subscription path when authorized, with explicit blocker otherwise |
| B06 | API credentials | Optional API-key use never silently replaces subscription use |
| B07 | Model guidance | Prompt profiles adapt to model/tool capabilities without upstream byte-for-byte cloning |
| B08 | Usage and limits | Events report usage and rate or plan limits without secret exposure |
| B09 | Context policy | Session context compacts, summarizes, and preserves task-critical information |
| B10 | Project instructions | Host and repository instructions affect the agent with defined precedence and trust |
| B11 | Role-aware tool guidance | Model and task profiles choose effective prompts, tools, and safe delegation rules |

## C. Coding tools and repository intelligence

| ID | Required capability | Observable behavior |
|---|---|---|
| C01 | File reading | Exact text, ranges, binary detection, encoding, and large-file limits |
| C02 | Safe writing | Root confinement, atomic updates, and clear conflict results |
| C03 | Precision editing | Guarded targeted edits reject stale content and preserve unrelated text |
| C04 | Search | Fast glob, text search, ignore rules, bounded output, and stable paths |
| C05 | Shell/process | Scoped commands, stdout/stderr, exit status, deadlines, kill and cancellation |
| C06 | Git workflows | Status, diff, commits, worktrees, and patch context under host policy |
| C07 | Structural code work | Syntax-aware search and edits through suitable parsers or existing tools |
| C08 | LSP | Diagnostics, definitions, references, symbols, and rename workflows |
| C09 | DAP | Debug sessions, breakpoints, stepping, variables, and termination |
| C10 | Test-driven edits | Agent executes and interprets tests, repairs failures, and reports evidence |
| C11 | Image/artifact inputs | Agent can inspect relevant image or generated artifacts through approved host tools |
| C12 | Security and review | Agent reviews diffs, identifies risk, and requests approval for sensitive operations |
| C13 | Headless live Observer | Explicitly granted target exposes bounded OTP/system, application, process, supervision and ETS metadata without GUI, state/dictionaries/messages or table contents |
| C14 | Live runtime tools | Approved actual-app docs, source locations and logs; explicitly authorized last-resort live evaluation/RPC stays distinct from isolated Eval, with target binding, denial and uncertain-effect evidence |

## D. Delegation, memory, and extensions

| ID | Required capability | Observable behavior |
|---|---|---|
| D01 | Subagents | Jido-supervised agents execute distinct tasks with bounded privileges |
| D02 | Parallel exploration | Multiple readers work concurrently without conflicting mutations |
| D03 | Worktree isolation | Mutating subagents use isolated worktrees or explicit workspace policies |
| D04 | Parent control | Parent can monitor, steer, cancel, wait for, and collect structured results |
| D05 | Checkpoints | Sessions expose explicit safe checkpoints and resume semantics |
| D06 | Task memory | Relevant retained context survives compaction and session restart |
| D07 | Skills and rules | Discover documented skills and project instructions with trust boundaries |
| D08 | Custom tools | Host registers Jido Actions without modifying the core library |
| D09 | MCP integration | Host can enable external MCP tools and resources with permissions |
| D10 | Browser integration | Host browser adapter supports research and web workflows |
| D11 | Human questions | Agent pauses for structured approval or clarification through host callbacks |
| D12 | Review and advisor | Optional helper agents review plans, code, and safety without hijacking control |
| D13 | Goal and plan workflows | Agents track task goals, TODO progress, yield conditions, and verification before completion |
| D14 | Iterative experiments | Agents can run bounded research or benchmark iterations and record artifacts and results |
| D15 | Research and external search | An approved host adapter exposes web research without unbounded network privileges |

## E. Eval: first-class three-language capability

| ID | Required capability | Observable behavior |
|---|---|---|
| E01 | Unified Eval | One Jido Action selects a configured language and returns structured results |
| E02 | Elixir Eval | A separate ERTS preserves per-session bindings and cannot corrupt the host VM |
| E03 | JavaScript Eval | QuickBEAM contexts run only Eval cells, with injected, scoped host APIs |
| E04 | Python Eval | Snakepit workers preserve session state; SnakeBridge is optional |
| E05 | Eval output | Streams, display values, errors, artifacts, and bounded output are available |
| E06 | Eval safety | Cancellation, timeouts, permission checks, and limits work across runtimes |
| E07 | Host tools in Eval | Each language calls explicitly granted Jido tools through a narrow bridge |

## F. Operating quality and Elixos

| ID | Required capability | Observable behavior |
|---|---|---|
| F01 | Standard Elixir configuration | `import Config` and Jido model aliases select runtime behavior |
| F02 | Testability | Normal tests run without network credentials or external paid providers |
| F03 | Observability | Telemetry reports agent health, tool errors, time, and queue pressure |
| F04 | Density benchmark | Benchmarks report memory and latency for idle and active agent populations |
| F05 | Platform support | Runtime contracts work on Elixos Linux targets with optional backend packaging |
| F06 | Elixos host adapter | Existing Elixos services supply questions, workspaces, browser, and lifecycle |
| F07 | Generation safety | The agent submits a candidate, while Elixos owns validation, promotion, and fallback |
| F08 | End-to-end coding task | Embedded agent completes a nontrivial repository fix with passing tests |
| F09 | Documentation | API, architecture, configuration, permissions, operations, and examples are usable |

## Coverage rule

Every row above belongs to the full delivery scope.
An optional backend can remain disabled in a minimal host, but its adapter contract and tests remain required.
Run opt-in live smoke tests on systems that supply the necessary external service.
Do not substitute a stub-only test for a claim about a live external provider.

Keep the original Oh My Pi inventory as a research aid.
Compare missing coding workflows against upstream tools and update the matrix when a material gap appears.
Do not automatically treat every upstream hidden tool name as a required public API.
