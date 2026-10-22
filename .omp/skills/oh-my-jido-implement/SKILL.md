---
name: oh-my-jido-implement
description: Implement and verify the full embeddable Oh-My-Jido coding-agent harness through Jido and OTP, with strict anti-port rules and durable goal progress.
---

# Oh-My-Jido implementation skill

Use this skill for the Oh-My-Jido library objective.
This repository targets an embeddable Jido-native coding harness, not a literal Oh My Pi port.

1. Read `docs/oh-my-jido/OH_MY_JIDO_GOAL.md`.
2. Read `docs/oh-my-jido/INDEX.md` and the documents in its authority order.
3. Inspect the current `mix.exs`, `mix.lock`, `AGENTS.md`, dependency usage rules, and tests.
4. Follow `docs/oh-my-jido/OPERATING_RULES.md` for architecture decisions and milestone work.
5. Keep `docs/oh-my-jido/PROGRESS.md` current with exact evidence and the next action.
6. Verify all required rows in `docs/oh-my-jido/CAPABILITY_MATRIX.md` before claiming full completion.

Never use QuickBEAM to run the Oh My Pi coding harness or tool implementations.
Use QuickBEAM only for the JavaScript Eval backend.
Use Snakepit and optional SnakeBridge for Python Eval.
Treat Elixir Eval as a first-class language in a separate ERTS.
Use Jido.AI and ReqLLM for models and transport.
Preserve the interactive Oh My Pi TUI and user approval controls.

Do not start an unattended runner or a shell automation script.
The human creates and controls the goal in the TUI.
