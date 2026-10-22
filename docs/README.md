# Oh-My-Jido documentation

Oh-My-Jido embeds a coding agent in your Elixir application. These pages explain how to install it, how it works, and how to use each capability safely. They describe the `jido-v3-preview` branch, which runs on the Jido 3.0 beta stack; the [`master` documentation](https://github.com/mattneel/oh_my_jido/blob/master/docs/README.md) covers the stable Jido 2.4 stack.

## Start here

| Page | Read it to |
|---|---|
| [Getting started](getting-started.md) | Install the library, call a tool, run a first AI task, follow events, approve actions and keep sessions across restarts |
| [Concepts](concepts.md) | Understand runtimes, sessions, runs, tools, permissions, host policy, events and the effect journal |

## Guides

| Guide | Read it when you want to |
|---|---|
| [Run coding tasks](guides/running-tasks.md) | Submit tasks, handle events in a GenServer or LiveView, answer questions, steer or cancel work, track goals |
| [Keep sessions and recover interrupted work](guides/sessions-and-recovery.md) | Choose storage, checkpoint and restore sessions, read the effect journal, handle uncertain effects |
| [Give your agent tools](guides/tools.md) | Choose tools, read and edit files, run commands, use Git, add your own Jido Actions and skills |
| [Choose permissions and require approvals](guides/permissions-and-approvals.md) | Decide what a session may do and which actions need a human decision; write your own host policy |
| [Choose models and accounts](guides/models-and-accounts.md) | Configure credentials, pick models per role, use OpenAI Sign in with ChatGPT or delegate to Claude Code |
| [Delegate focused tasks](guides/subagents.md) | Start sub-agents for investigation, review or isolated changes |
| [Navigate, refactor and debug code](guides/language-intelligence.md) | Use structural Elixir edits, language servers and debuggers |
| [Inspect a running application](guides/live-applications.md) | Let the agent inspect a live BEAM node with Observer or Tidewave tools |
| [Evaluate persistent code cells](guides/eval.md) | Enable Elixir, JavaScript or Python Eval |
| [Connect external tools and artifacts](guides/integrations.md) | Bind MCP servers, browsers, research services, artifact readers and review services |
| [Add coding tools to your Jido agents](guides/jido-agents.md) | Use the tools without a managed session, or add them to agents you already have |
| [Protect your application and session data](guides/security.md) | Understand what the library protects, what it does not, and how to isolate untrusted work |

## Reference

| Page | Contents |
|---|---|
| [Public API reference](reference/api.md) | Every public function, type, event and error |
| [Configuration reference](reference/configuration.md) | Runtime and session options, defaults and limits |

## Operations

| Page | Contents |
|---|---|
| [Run Oh-My-Jido in production](operations.md) | Storage and backups, telemetry, capacity, the density benchmark, platform requirements and upgrades |
| [Project status](project-status.md) | Release status, supported branches, what is verified and where the evidence lives |
| [Measure session density and capacity](../bench/README.md) | The credential-free density benchmark |

## Examples

| Example | Shows |
|---|---|
| [Plain Mix application](../examples/plain_mix/README.md) | Supervision, coding tasks, events, controls and restoring a session after a restart |
| [Your own Jido agents](../examples/jido_agent/README.md) | Coding tools on a plain Jido agent and a Jido.AI agent |
| [Docs site and studio](../examples/docs_site/README.md) | A Phoenix application whose agent edits its own docs and source behind review, checks and approval |

## Project records

The [`oh-my-jido/`](oh-my-jido/README.md) folder holds the project's specification, delivery ledger and verification evidence. You do not need it to use the library. The [Elixos integration record](../examples/elixos/README.md) is a historical example that needs an Elixos checkout. The [changelog](../CHANGELOG.md) lists unreleased changes.
