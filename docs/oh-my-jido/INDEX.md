# Project specification index

## Authority order

1. `OH_MY_JIDO_GOAL.md` — the user's intent and completion definition.
2. `OPERATING_RULES.md` — development conduct and architecture boundaries.
3. `ARCHITECTURE.md` — public library contracts.
4. `CAPABILITY_MATRIX.md` — required behavior and scope.
5. `ACCEPTANCE.md` — verification requirements.
6. `DELIVERY_PLAN.md` — default execution sequence.
7. Specialized specifications — `EVAL.md`, `AUTH_AND_MODELS.md`, `ELIXOS_INTEGRATION.md`, and `SECURITY.md`.
8. `RESEARCH.md` — external sources and reuse guidance.
9. `PROGRESS.md` — current evidence and next action.

`README.md` and `AGENTS.md` in the generated repository remain valid project instructions.
If they conflict with this mission, preserve them and ask the human about the conflict.
Never silently erase generated instructions or project metadata.

## Interpret the objective

"In spirit" means capability and outcome parity, not source-level or wire-level parity.
The benchmark is a capable coding agent with equivalent practical leverage over a repository.
A smaller set of well-designed Jido Actions can satisfy several Oh My Pi tool names.
A generic read/write/shell demo cannot satisfy advanced editing, debugger, memory, and delegation requirements.

## Operating mode

The human starts and steers Oh My Pi through its interactive TUI and `/goal` command.
This specification does not authorize a shell runner, a headless session, or unattended publication.
Autonomous work can continue across many interactive goal turns, with human approval at defined trust boundaries.

## Scope change

Record proposed changes in `PROGRESS.md` and explain their effect on acceptance.
Never narrow the canonical goal to match the features that already work.
If an external service blocks a requirement, retain its row as blocked with explicit evidence.
