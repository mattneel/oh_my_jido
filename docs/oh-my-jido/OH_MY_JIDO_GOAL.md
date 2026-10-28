# Canonical goal: deliver Oh-My-Jido

## Outcome

Build and verify **Oh-My-Jido**, a reusable Mix library that embeds Oh My Pi-class coding-agent capability in ordinary Elixir and Jido applications.

Jido and Jido.AI own the agent runtime. OTP owns processes, lifecycle, supervision, recovery, and concurrency.
Oh My Pi supplies a behavioral reference for coding-agent potency, not an implementation blueprint.

## Required result

A host application can supervise the library and start an agent. The host can submit coding tasks, consume typed events, steer execution, and resume durable sessions.
The host can also suspend or cancel work.
The agent can understand a repository, perform accurate edits, run tests, use language intelligence, delegate subtasks, recover from failures, and deliver verified code changes.
Host applications can supply workspaces, storage, approvals, tools, browsers, model credentials, and operating-system capabilities.

The package must provide native `import Config` settings and task-specific model roles.
It must support authorized subscription authentication for ChatGPT/Codex and an approved Claude/Claude Code path.
It must support API credentials without silent subscription-to-metered fallback.

The Eval tool must treat Elixir as a first-class language.
JavaScript Eval can use QuickBEAM with injected host APIs. Python Eval can use Snakepit and optional SnakeBridge.
These language runtimes must not implement the agent loop or the rest of the toolset.

Keep a small development harness for tests and interactive inspection if useful.
Do not produce a standalone CLI product as the core deliverable.

## Non-negotiable implementation boundaries

- Use existing Jido, Jido.AI, Jido Action, and ReqLLM behavior before writing equivalents.
- Do not run Oh My Pi TypeScript as the coding harness.
- Do not create a Bun compatibility runtime to host Oh My Pi tools.
- Do not implement a second LLM transport, generic agent loop, generic event bus, or generic process supervisor.
- Do not reproduce every upstream schema or JSON byte sequence merely for port fidelity.
- Do not use QuickBEAM outside JavaScript Eval.
- Do not use Python outside Python Eval or an explicitly approved Python-only capability.
- Do not introduce Rustler, Zigler, Rust helper processes, or Zig helper processes without measured or documented need.
- Do not execute arbitrary Elixir Eval code in the host application's BEAM.
- Do not modify global VM working directories or environment variables per agent.
- Do not disable tests, weaken acceptance checks, or present stub behavior as completion.

## Delivery contract

Read `docs/oh-my-jido/INDEX.md` and follow its reading order.
Use the capability matrix to define the complete work scope.
Follow the milestones and run their quality gates.
Maintain `docs/oh-my-jido/PROGRESS.md` with tested results and unresolved risks.
Continue past the first demonstration until all required capabilities pass the acceptance matrix.

You have permission to implement, test, refactor, document, and commit code within this new repository.
Keep each change reviewable and reversible. Do not change other repositories without explicit human approval.
Request human approval for destructive actions, external publishing, credential access, or policy-sensitive provider integration.

## Completion criteria

Only report full goal completion when all required capability rows reach `verified` with direct test evidence.
Require a host integration demonstration and measurable concurrency results before declaring the library complete.
If a provider restriction prevents a particular subscription workflow, keep an explicit blocker and request a human decision.
Do not disguise a legal or provider-policy blocker as a technical success.

Goal-mode budget exhaustion, partial feature delivery, and a green placeholder test do not count as completion.
