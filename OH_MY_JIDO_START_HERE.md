# Oh-My-Jido: interactive implementation mission

This package adds instructions for an Oh My Pi coding agent. It does not change the generated Mix project.

The target is an embeddable, Jido-native coding harness. It is not a TypeScript port or a CLI product.

## Use the Oh My Pi TUI

1. Extract this archive into the root of the new `oh_my_jido` Mix project.
2. Open Oh My Pi in that project through its normal interactive TUI.
3. Enable goal mode through `/settings` if `/goal` reports that goal mode is disabled.
4. Enter the following objective in the TUI:

```text
/goal Deliver the complete Oh-My-Jido library defined in OH_MY_JIDO_GOAL.md and docs/oh-my-jido/INDEX.md. Follow the operating rules and quality gates. Implement all required capability areas with tests and evidence. Maintain docs/oh-my-jido/PROGRESS.md after each substantial milestone. Work autonomously in small verified steps. Do not call the goal complete until all acceptance gates pass. Keep the session interactive so I can steer decisions and approve effects.
```

5. Watch the TUI, inspect changes, and steer the agent whenever necessary.
6. Use `/goal` to inspect, pause, or resume the goal through the TUI controls.

The command above is a goal objective, not a shell script. The user remains in control of the TUI.

## Optional skill

The package also includes `.omp/skills/oh-my-jido-implement/SKILL.md`.
Use `/skill:oh-my-jido-implement` before `/goal` if your Oh My Pi version supports project skills.
The goal itself already directs the agent to the same rules, so the skill is optional.

## Contents

- `OH_MY_JIDO_GOAL.md` — canonical mission and completion contract.
- `docs/oh-my-jido/INDEX.md` — document order and authority.
- `docs/oh-my-jido/OPERATING_RULES.md` — anti-detour rules and daily workflow.
- `docs/oh-my-jido/ARCHITECTURE.md` — embeddable package boundaries.
- `docs/oh-my-jido/CAPABILITY_MATRIX.md` — full coding-agent scope.
- `docs/oh-my-jido/DELIVERY_PLAN.md` — incremental implementation milestones.
- `docs/oh-my-jido/ACCEPTANCE.md` — executable quality gates.
- `docs/oh-my-jido/EVAL.md` — Elixir, JavaScript, and Python Eval design.
- `docs/oh-my-jido/AUTH_AND_MODELS.md` — subscription login and model roles.
- `docs/oh-my-jido/ELIXOS_INTEGRATION.md` — host contracts for the OS.
- `docs/oh-my-jido/SECURITY.md` — isolation, credentials, and effect safety.
- `docs/oh-my-jido/RESEARCH.md` — source research and reuse criteria.
- `docs/oh-my-jido/PROGRESS.md` — durable delivery ledger.

## Existing scaffold

Preserve `mix.exs`, `AGENTS.md`, `README.md`, and the generated source until inspection proves that a change is necessary.
The failed Igniter installers for QuickBEAM and Snakepit do not prove that their dependencies are absent.
Inspect `mix.exs` and `mix.lock` first. Add only missing dependencies.

Do not execute any instructions from this archive through a launcher script. No unattended runner exists in this package.
