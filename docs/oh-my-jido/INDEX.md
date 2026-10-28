# Project specification index

## Authority order

1. `OH_MY_JIDO_GOAL.md` — the user's intent and completion definition.
2. `OPERATING_RULES.md` — development conduct and architecture boundaries.
3. `ARCHITECTURE.md` — public library contracts.
4. `CAPABILITY_MATRIX.md` — required behavior and scope.
5. `ACCEPTANCE.md` — verification requirements.
6. `DELIVERY_PLAN.md` — default execution sequence.
7. Specialized specifications — `EVAL.md`, `AUTH_AND_MODELS.md`, and `SECURITY.md`.
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

On 2026-10-28 the human removed OS-level integration from the project: hosts integrate Oh-My-Jido, not the other way around.

The human subsequently added structured, headless live OTP/application inspection (explicitly not the wxWidgets Observer app), and retained live IEx-style evaluation/RPC as an explicitly authorized last resort, citing Tidewave MCP runtime tools. These are tracked as C13/C14 and T12/T13. They do not replace isolated Eval or authorize connecting to real user applications without the host's target/grant/approval policy.

The human additionally approved ordinary-Elixir onboarding, native plugin attachment to their own Jido/Jido.AI agents, composable availability bundles, source-installation ergonomics and an independent own-agent example. Deliver these on the stable dependency contract first, then create a dedicated Jido V3 preview branch from the verified result. This request does not itself authorize a stable dependency upgrade or publication.

The human then approved a substantive source-first Phoenix CMS example on both
stable Jido and the actual native V3 preview, and identified that app as the future
Oh-My-Jido docs site. The agent edits Git-backed Markdown and Phoenix source in an
isolated workspace; durable questions, approvals and controls lead to an immutable
review, actual child-process checks/preview, digest-bound approval and conflict-safe
adoption/publication. There is no separate database page-body CMS or live loading of
authored code into the editor VM. The approved deployment split is a trusted editor
and a tiny public-only Fly renderer. Local production evidence and both-version
quality gates are required; external provisioning, secrets and deployment still
require explicit approval. See the [reference application](../../examples/docs_site/README.md)
and current progress ledger; source implementation alone is not acceptance.

On2026-10-20 the human explicitly approved one narrow Python exception: the private
CMS editor's fixed standard-library Linux pidfd/child-subreaper/waitpid helper may
prove owned process cleanup. It does not implement the agent loop, evaluate authored
code in the editor VM, weaken cleanup receipts or select an automatic fallback.
The public renderer has no Python prerequisite; broader Python use remains governed
by the canonical goal.

Never narrow the canonical goal to match the features that already work.
If an external service blocks a requirement, retain its row as blocked with explicit evidence.
