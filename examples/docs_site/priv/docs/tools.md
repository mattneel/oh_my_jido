# Tools and authority

Native Jido Actions supply the coding tools. Availability and permission grants are separate decisions.

| Bundle | Actions |
| --- | --- |
| `:read_only` | Read, Search, List |
| `:editing` | Write, Edit |
| `:elixir` | AST, LSP, Debug |
| `:process` | Shell, Git |
| `:live_inspection` | Structured Observer |

## Guarded edits

Read the file first. An edit supplies that whole-file snapshot digest and exact replacements. Stale snapshots, ambiguous matches and overlapping edits are conflicts—not reasons to overwrite a newer change.

## Explicit execution

Shell takes an executable and argument vector, not an implicitly interpreted command string. The docs studio asks a human before process execution. A workspace root is a file policy, not an operating-system sandbox: trusted editor access grants meaningful authority.

Language servers, debuggers, browser services and live targets require explicit host bindings. Observer is structured metadata inspection, not arbitrary live evaluation.

## Your own native agent

Attach `OhMyJido.Plugin` through a native `plugins:` declaration and a trusted `OhMyJido.Plugin.ContextProvider`. Resolve authority by native module/agent identity. The agent must enable private diagnostics and configure zero tool retries. Lightweight attachment does not imply the managed runtime's journal, approval UI or recovery coordinator.
