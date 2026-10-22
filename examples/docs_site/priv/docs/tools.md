# Choose tools and permissions

Choose what an agent can do before giving it a task. Tools are Jido Actions: operations such as Read, Edit or Shell. Registering a tool makes it available; granting a permission allows its operations. Your application's host policy can still refuse an operation or require human approval.

## Select a tool set

Pass `bundles:` to a runtime or `start_session/2`. A session selection replaces the runtime's tool selection; it does not add permissions. Use `tools: [ActionModule, ...]` instead when you need an explicit list, not both options together.

| Bundle | Tools |
|---|---|
| `:read_only` | Read, Search, List |
| `:editing` | Write, Edit |
| `:elixir` | AST, LSP, Debug |
| `:process` | Shell, Git |
| `:live_inspection` | Observer |

A bundle can be an atom or a list of atoms. `bundles: []` selects no tools. Sessions start with no permissions. For example, reading needs `:read`, file mutation needs `:edit`, Shell needs `:exec`, and Git needs `:git`.

## Make a guarded edit

This example creates `docs-example.txt` in an existing workspace, reads it, then edits the exact bytes it read. Use a workspace where that file does not already exist:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: [:read_only, :editing],
    permissions: [:read, :edit]
  )

{:ok, _written} =
  OhMyJido.execute_tool(session, "write", %{
    path: "docs-example.txt",
    content: "hello\n",
    snapshot: "missing"
  })

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "docs-example.txt"})

{:ok, _edited} =
  OhMyJido.execute_tool(session, "edit", %{
    path: "docs-example.txt",
    snapshot: file.snapshot,
    edits: [%{old: "hello\n", new: "Hello from Oh-My-Jido.\n"}]
  })
```

The snapshot is a digest of the whole file, even when Read returns a line range. A stale snapshot, overlapping edits or an ambiguous target is a conflict, not permission to overwrite newer text. Repeated targets need an explicit one-based `occurrence`. Unrelated text, newline bytes and file permissions are preserved. External writers are rechecked, not OS-locked.

## Run a command deliberately

Register Shell and grant `:exec` only when your application intends to allow process execution:

```elixir
{:ok, commands} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: :process,
    permissions: [:exec]
  )

OhMyJido.execute_tool(commands, "shell", %{
  executable: "mix",
  args: ["test"]
})
```

Shell takes an executable and argument vector, not an implicitly interpreted command string. Use an explicit `sh` executable and `-c` arguments only when you intend shell interpretation. Working directory and environment overrides apply to the child, not the application's VM.

## Decide which effects need approval

The default `OhMyJido.Host.Local` policy asks about effects marked sensitive, such as Git commits, applied renames, debugger launches or external adapter calls. It does not ask about every Shell command. The docs studio uses a stricter policy: every agent-launched subprocess, including Git and ripgrep, needs a fresh human approval.

Subscribe for `:approval_requested` events and answer with `OhMyJido.answer(session, question_id, value)`. Effect consent is accepted only for `true`, `:approve` or `"approve"`. Availability, permissions and approval are separate checks; none substitutes for the others.

## Add services or use your own agent

Language servers, debuggers, browser services and live targets require explicit application bindings. Registering their tools does not start or configure the services. Observer returns structured metadata, not arbitrary live evaluation.

If you already own a Jido/Jido.AI agent, attach `OhMyJido.Plugin` in its `plugins:` declaration and supply an `OhMyJido.Plugin.ContextProvider`. Resolve private authority from the native agent's module/ID, not model arguments or agent state. Enable `private_diagnostics?/0`; AI agents also require `tool_max_retries: 0`. This lightweight integration supplies no managed session journal, approval UI or recovery coordinator. See the complete [Jido agents guide](https://github.com/mattneel/oh_my_jido/blob/master/docs/guides/jido-agents.md).

## Limits

- Workspace confinement and permissions are library policy, **not an OS sandbox**. Use OS/user/container and network/resource isolation for untrusted work.
- Cancellation cannot undo bytes written or network requests already sent.
- Interrupted or uncertain effects are never automatically retried. Inspect the effect journal and reconcile real state before starting new work.

## Related

- [Getting started](/docs/getting-started)
- [Runtime and sessions](/docs/runtime)
- [Complete tool catalog](https://github.com/mattneel/oh_my_jido/blob/master/docs/guides/tools.md)
- [Permissions and approvals](https://github.com/mattneel/oh_my_jido/blob/master/docs/guides/permissions-and-approvals.md)
- [Language intelligence](https://github.com/mattneel/oh_my_jido/blob/master/docs/guides/language-intelligence.md)
- [Security](https://github.com/mattneel/oh_my_jido/blob/master/docs/guides/security.md)
