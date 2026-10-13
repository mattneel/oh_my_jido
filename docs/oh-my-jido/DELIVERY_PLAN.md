# Delivery plan and milestone gates

Implement the full capability matrix through small, independently verifiable milestones.
Do not treat this plan as permission to omit advanced features after the first coding demonstration.
The agent can refine the order as evidence emerges, but it must preserve the completion contract.

## Milestone 0: inspect and constrain the architecture

1. Inspect the Igniter scaffold and all resolved dependency versions.
2. Read installed Jido, Jido.AI, ReqLLM, QuickBEAM, Snakepit, and VibeKit usage rules where applicable.
3. Identify the APIs that already provide agent turns, supervision, model calls, tools, and streaming.
4. Confirm whether QuickBEAM and Snakepit exist in `mix.exs` despite missing Igniter installers.
5. Record a dependency decision for every new direct dependency.
6. Establish the baseline compile, format, and test results.
7. Create the initial module boundaries without duplicate generic infrastructure.

**Gate:** Baseline tests pass. The design declares host-owned capabilities and a Jido-native runtime.

## Milestone 1: embeddable Jido agent and host contracts

1. Implement a host-supervised runtime with independent named instances.
2. Start real Jido agents through the installed Jido lifecycle API.
3. Use a scripted model transport to exercise model turns and tool requests.
4. Expose a stable session API, typed events, cancellation, and explicit errors.
5. Add host callbacks for workspace, authorization, approvals, credentials, and persistence.
6. Test instance isolation and failures under multiple concurrent sessions.

**Gate:** A separate toy Mix application embeds the harness without starting an external daemon.

## Milestone 2: model roles and subscription authentication

1. Use `import Config` and Jido.AI model aliases.
2. Implement task-specific model role selection and session overrides.
3. Implement an opaque account vault interface and secure credential lifecycle.
4. Implement authorized ChatGPT/Codex sign-in, token renewal, account choice, and logout.
5. Define the approved Claude/Claude Code subscription integration route.
6. Keep an explicit policy blocker if Anthropic does not authorize the requested route.
7. Test provider streaming, tool requests, usage, limits, cancellation, and redaction.
8. Document separate human-initiated live provider smoke tests.

**Gate:** Provider integration uses Jido.AI/ReqLLM, not a new HTTP/SSE stack.

## Milestone 3: dependable coding tools

1. Implement scoped file read, write, list, and search through Jido Actions.
2. Implement content-guarded edits with stale snapshot detection.
3. Implement shell and process execution with cancellation, output caps, and host permissions.
4. Add Git status, diffs, worktrees, and review operations.
5. Test symlinks, path traversal, Unicode, binary files, concurrent edits, and large outputs.
6. Deliver a real agent fix of a failing test in a disposable repository.

**Gate:** The agent makes a precise repair and proves its effect through actual tests.

## Milestone 4: agent intelligence and session quality

1. Compose code-aware prompts with project instructions and enabled tool descriptions.
2. Add context compaction and retention of active task constraints.
3. Add durable sessions, checkpoints, and replay-safe recovery.
4. Implement planning, review, advisor, and exploration model roles.
5. Add intervention paths for human questions, steering, and tool approval.
6. Verify resume, cancellation, and task continuity across a process restart.

**Gate:** A long coding task preserves relevant context and survives a supervised worker restart.

## Milestone 5: subagents, memory, and extension points

1. Use Jido supervision for independent subagents with bounded resource budgets.
2. Add task submission, progress, wait, cancellation, structured results, and parent steering.
3. Add workspace or Git worktree isolation for mutating subagents.
4. Implement task memory and explicit retained notes through existing storage interfaces.
5. Support host-registered Jido Actions, documented skills, and trusted project instructions.
6. Add permission-scoped MCP integration without a second tool framework.

**Gate:** Parent and child agents cooperate without duplicate effects or shared writable state leaks.

## Milestone 6: advanced code intelligence and external tools

1. Expose syntax-aware search and edit operations.
2. Integrate LSP diagnostics, definition, references, symbols, and rename behavior.
3. Integrate DAP breakpoints, step control, variables, and debug cleanup.
4. Integrate an optional browser adapter and approved web-research capabilities.
5. Add code review, security inspection, and useful artifact inspection.
6. Exercise real supported server processes in optional host smoke tests.

**Gate:** Integration fixtures prove useful language and debugger workflows, not mere protocol connectivity.

## Milestone 7: three-language Eval

1. Implement one Jido Eval Action and a backend behavior.
2. Implement Elixir Eval in a separate, supervised ERTS.
3. Add persistent Elixir Eval session bindings, output, and allowed host tool calls.
4. Implement QuickBEAM JavaScript Eval and inject only needed host APIs.
5. Implement Snakepit Python Eval with optional SnakeBridge support.
6. Verify timeouts, cancellation, resource quotas, crash isolation, and output limits.
7. Verify unavailable optional backends produce clear capability errors.

**Gate:** Each language completes multi-cell stateful tests with bounded and authorized effects.

## Milestone 8: prove Elixos integration

1. Build an Elixos adapter without importing Elixos modules into the core library.
2. Connect existing Elixos Ask, Session, Browser, Agents, and Image services through host contracts.
3. Submit candidate changes through Elixos generation validation, not direct live code replacement.
4. Verify isolated builds, health checks, provenance, and rollback through the established Elixos interfaces.
5. Keep every change to the Elixos repository subject to explicit human approval.

**Gate:** The same core library works in a conventional Mix host and an Elixos host.

## Milestone 9: density, operational quality, and release

1. Measure idle agent memory and active agent memory at several session counts.
2. Measure tool latency, concurrency, event delivery, cancellation, and recovery.
3. Compare observed capacity against equivalent baseline workloads when practical.
4. Optimize proven hot paths only after profiling and correctness tests.
5. Verify native backend packaging constraints on x86_64 and aarch64 targets.
6. Document public APIs, supervision, configuration, OAuth, security, and host adapters.
7. Run all unit, integration, fault, and acceptance tests.
8. Audit the complete capability matrix and record every direct evidence link.

**Gate:** All required capability rows are verified or carry an explicit human-reviewed external blocker.
An unresolved required blocker prevents a claim of unconditional full completion.

## Across all milestones

Update `PROGRESS.md` after every substantive milestone and before ending a session.
Record test commands and results, not only confidence statements.
Do not stop after the first green end-to-end demonstration.
Preserve the human's approval controls throughout the goal.
