# Rules for the implementing agent

## Before any implementation

1. Inspect `mix.exs`, `mix.lock`, `lib/`, `test/`, `AGENTS.md`, and the generated configuration.
2. Read the installed package usage rules and public module documentation for Jido, Jido.AI, and ReqLLM.
3. Inspect the actual dependency source before referencing a specific API in production code.
4. Run the existing tests and record their result in `PROGRESS.md`.
5. Compare the required capability against existing Jido and Elixir packages.
6. Propose the smallest native Elixir design that passes a meaningful black-box test.

## Do not repeat the previous detour

The previous attempt built redundant LLM transports, agent loops, JavaScript compatibility layers, native tool services, and session infrastructure.
This project exists to avoid that design.

- Never use QuickBEAM as a substitute runtime for Oh My Pi coding-agent tools.
- Never translate TypeScript source one module at a time.
- Never clone Oh My Pi package topology into the Elixir repository.
- Never create a second framework for concepts that Jido or OTP already owns.
- Never write a Bun/Node emulator outside the narrow JavaScript Eval capability.
- Never make a particular Oh My Pi schema, error string, or JSON encoding a mandatory contract without a functional reason.
- Never start a separate daemon to run the coding agent.
- Never center the design on a CLI or TUI that consumers must use.
- Never spend a milestone on optimization before a measurable baseline exists.
- Never use Rustler, Zigler, Snakepit, or QuickBEAM merely because those packages are available.

## Reuse test

For each new subsystem, record a concise answer to these questions:

1. What required coding-agent behavior does this subsystem deliver?
2. Which installed Jido or Elixir package already supports the behavior?
3. What verified gap remains after reuse?
4. Why is the proposed code the smallest correct solution?
5. How will a test prove the behavior at the public library boundary?

If an existing package covers the requirement, use it through a thin adapter.
If that package lacks a needed feature, add the smallest extension or upstream contribution.

## Development loop

1. Select the next unmet capability from `CAPABILITY_MATRIX.md`.
2. Write a public behavior test before broad implementation.
3. Implement through the established architecture.
4. Run focused tests, then all existing tests.
5. Check formatter output and compiler warnings.
6. Record the commands, results, risks, and next action in `PROGRESS.md`.
7. Commit a reviewable milestone after its acceptance checks pass.
8. Continue toward the next unmet capability without redefining the goal.

Use local test doubles for providers, browsers, LSP servers, and system services.
Do not make the normal test suite depend on paid credentials, public networks, or provider availability.
Provide separately documented, human-initiated live smoke tests for account access.

## Human control

The human operates an interactive Oh My Pi TUI and can steer the goal at any point.
Do not disable approval prompts, change approval modes, or create a detached runner.
Request approval before irreversible external effects, publishing, billing changes, destructive repository actions, or new provider credential grants.
Avoid broad file deletion, history rewriting, and destructive Git operations.

## Completion honesty

Keep a distinction between `implemented`, `tested`, `verified`, and `blocked`.
A function signature, module stub, skipped test, or simulator alone is not a completed capability.
Do not mark the goal complete while any required capability lacks direct evidence.
Do not silently omit capabilities because the implementation seems expensive.

## Architecture decision notes

Record material decisions in `PROGRESS.md` under `Decisions` or create a short ADR in this directory.
Use this format: behavior, existing package, gap, selected design, rejected designs, test evidence, operational impact.
For native code, also record benchmarks, scheduler impact, target support, and crash isolation.
