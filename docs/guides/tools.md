# Give your agent tools

Tools let the coding agent inspect a repository, change files and run commands. Each tool is a Jido Action: an Elixir module with a name, an input schema and a `run/2` function. Your application chooses which Actions a session can see and which permissions it receives.

## Before you start

You need a managed session bound to an existing workspace directory. See [getting started](../getting-started.md) for runtime setup. Calling file tools does not require model credentials; asking the agent to choose tools does.

List and Search need ripgrep (`rg`). Shell, Git and ripgrep discovery use the Linux process runner, which needs `setsid`, `sh`, `mkfifo`, `cat`, `kill` and procfs. Git also needs the `git` executable. Optional services have their own setup guides in the catalog below.

## Let the agent choose, or call a tool yourself

When you submit a task with `OhMyJido.prompt/3`, Jido.AI runs the model/tool loop. The model receives the registered tool schemas filtered by the session's permissions and the request's tool selection. It can choose a tool, use its result and continue working. See [running tasks](running-tasks.md).

You can also call a registered tool directly. This uses the session's workspace and permissions without making a model request:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: [:read_only, :editing],
    permissions: [:read, :edit]
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

Both managed paths validate inputs, apply authorization and record tool effects in the session journal. They never automatically retry an effect. Tool names are exact strings, such as `"read"`, not atoms derived from input.

| `execute_tool/4` option | Default | Use |
|---|---|---|
| `timeout` | The session's call limit: `tool_timeout_ms` plus `question_timeout_ms`, normally `330_000` milliseconds | Whole-call limit, including approval waits inside the Action; distinct from a subprocess's `timeout_ms` parameter. The `:custom` approval for an Action without `capability/0` is asked before the call starts and is limited by `question_timeout_ms`. A context without a session uses `tool_timeout_ms`. |
| `effect_id` | Generated ID | Trusted application code can correlate a known operation with its journal entry. Reusing a recorded ID returns `{:error, :effect_already_recorded}` before execution. This is not a model-facing parameter. |

If the operation returns but its result cannot be safely recorded, the call returns `{:error, %{reason: :effect_recording_failed, cause: cause, effect: :uncertain, effect_id: id, result: sanitized_result}}`. Inspect and reconcile that result instead of executing again. See [sessions and recovery](sessions-and-recovery.md).

## Select available tools

A bundle selects tool availability. It does not grant permissions, start servers or install external software.

| Bundle | Actions, in order |
|---|---|
| `:read_only` | `Read`, `Search`, `List` |
| `:editing` | `Write`, `Edit` |
| `:elixir` | `AST`, `LSP`, `Debug` |
| `:process` | `Shell`, `Git` |
| `:live_inspection` | `Observer` |

Pass `bundles:` when configuring a runtime or starting a session. A session selection replaces the runtime's selection. Alternatively, pass `tools:` with an explicit list of Action modules. Supplying both options at the same level is an error.

Managed sessions use the full `OhMyJido.Tools.default/0` catalog unless you select a narrower registry. A standalone `OhMyJido.Context.new/1` defaults to `[:read_only]` availability. Both start with **no permissions** unless you supply them. The `:elixir` bundle does not launch a language server or debugger; Observer does not grant live code execution; `:process` does not grant `:exec` or `:git`.

| Registry API | Behavior |
|---|---|
| `OhMyJido.Tools.bundles/0` | Returns the fixed bundle map above |
| `OhMyJido.Tools.select(:read_only)` | Returns `{:ok, action_modules}` |
| `OhMyJido.Tools.select([:read_only, :editing])` | Combines bundles in caller order and removes duplicate Actions, keeping the first occurrence |
| `OhMyJido.Tools.select([])` | Returns `{:ok, []}` |
| `OhMyJido.Tools.select!/1` | Returns the modules or raises `ArgumentError` for an invalid selection |

Selection errors are `{:unknown_bundle, name}`, `{:invalid_bundle, value}` or `{:invalid_bundle_selection, :expected_atom_or_list}`, inside `{:error, reason}`. String names are never converted to atoms. See [permissions and approvals](permissions-and-approvals.md) for authorization policy, and [Jido agents](jido-agents.md) for standalone Actions and plugin attachment.

## Tool catalog

This is the complete `OhMyJido.Tools.default/0` registry, in registry order. Module names below are under `OhMyJido.Tools`. The permission column shows each Action's declared `capability/0`; individual operations can require additional permissions or approval.

| Exact name | Module | Permission | Purpose | Details |
|---|---|---|---|---|
| `"read"` | `Read` | `:read` | Read exact text or bounded binary data and get a whole-file snapshot | [Files](#read-create-and-edit-files) |
| `"write"` | `Write` | `:edit` | Create or replace a UTF-8 file with a snapshot guard | [Files](#read-create-and-edit-files) |
| `"edit"` | `Edit` | `:edit` | Apply exact, nonoverlapping replacements | [Files](#read-create-and-edit-files) |
| `"search"` | `Search` | `:read` | Find literal or regex matches with source locations | [Search](#find-files-and-text) |
| `"list"` | `List` | `:read` | Discover confined, ignore-aware file paths | [Search](#find-files-and-text) |
| `"shell"` | `Shell` | `:exec` | Run an executable with explicit arguments and bounded output | [Commands](#run-a-test-command) |
| `"git"` | `Git` | `:git` | Inspect changes, commit selected files and manage worktrees; mutations also need `:edit` | [Git](#inspect-and-change-git-state) |
| `"ast"` | `AST` | `:ast` | Search and replace structural code patterns; input reads need `:read`, writes need `:edit` | [Language intelligence](language-intelligence.md) |
| `"lsp"` | `LSP` | `:lsp` | Use a configured language server for navigation, diagnostics and guarded rename | [Language intelligence](language-intelligence.md) |
| `"debug"` | `Debug` | `:debug` | Use a configured Debug Adapter Protocol debugger | [Language intelligence](language-intelligence.md) |
| `"observer"` | `Observer` | `:observe` | Inspect a configured live Elixir application's OTP metadata | [Live applications](live-applications.md) |
| `"mcp"` | `MCP` | `:mcp` | Call application-allowlisted MCP tools and resources | [Integrations](integrations.md) |
| `"browser"` | `Browser` | `:browser` | Navigate and interact with an application-owned browser page | [Integrations](integrations.md) |
| `"research"` | `Research` | `:research` | Search or read through an approved research adapter | [Integrations](integrations.md) |
| `"artifact"` | `Artifact` | `:artifact` | Inspect confined artifacts, extract text and supply approved image inputs | [Integrations](integrations.md) |
| `"review"` | `Review` | `:review` | Get bounded risk hints from actual tracked changes | [Integrations](integrations.md) |
| `"eval"` | `Eval` | `:eval` | Run persistent Elixir, JavaScript or Python cells | [Eval](eval.md) |
| `"skill"` | `Skill` | `:skills` | Discover and load explicitly trusted skill guidance | [Skills](#reuse-approved-skills) |
| `"claude_code"` | `ClaudeCode` | `:claude_code` | Delegate a separately approved task to official Claude Code, not a native model | [Models and accounts](models-and-accounts.md) |
| `"goal"` | `Goal` | `:planning` | Inspect or set a goal, update its plan and complete it with check effect IDs | [Running tasks](running-tasks.md) |
| `"memory"` | `Memory` | `:memory` | Retain task-critical facts | [Running tasks](running-tasks.md) |
| `"question"` | `Question` | `:ask` | Ask a structured clarification through your application | [Running tasks](running-tasks.md) |
| `"experiment"` | `Experiment` | `:experiments` | Run bounded registered-tool trials and retain timings and results | [Running tasks](running-tasks.md) |
| `"subagent"` | `Subagent` | `:delegate` | Start, wait for, steer or cancel a narrowed child task | [Subagents](subagents.md) |

Goal, memory, questions, experiments and child-task coordination depend on managed session integration. Registering their modules on an otherwise standalone Context does not create that integration. Available service Actions still need configured adapters. A role name, skill or tool result grants no permission.

## Read, create and edit files

Read before replacing an existing file. Keep the returned `snapshot`: it is the lowercase SHA-256 of the **entire original file**, including its newline bytes, even when you request only a slice.

```elixir
{:ok, slice} =
  OhMyJido.execute_tool(session, "read", %{
    path: "mix.exs",
    start_line: 1,
    end_line: 20
  })
```

Line numbers are one-based and inclusive. Text retains its original LF or CRLF bytes. A ranged or truncated result is not the complete file contents, even though its snapshot identifies the whole file.

To create a file without overwriting anything, use `snapshot: "missing"`. This example chooses a new path in the workspace root; if it already exists, creation fails with a stale-snapshot conflict.

```elixir
{:ok, _created} =
  OhMyJido.execute_tool(session, "write", %{
    path: "agent-note.txt",
    content: "Inspect existing code.\n",
    snapshot: "missing"
  })

{:ok, note} =
  OhMyJido.execute_tool(session, "read", %{path: "agent-note.txt"})

{:ok, updated} =
  OhMyJido.execute_tool(session, "edit", %{
    path: "agent-note.txt",
    snapshot: note.snapshot,
    edits: [%{old: "Inspect existing code.", new: "Inspect code before editing."}]
  })
```

To replace the whole file, call `"write"` with the new `content` and the latest read or mutation's `snapshot`, such as `updated.snapshot`. Parent directories must already exist. There is no unguarded overwrite option or newline normalization.

An edit resolves every target against the same original snapshot, not the result of earlier replacements in the list. `old` must be nonempty exact text; `new` can be empty to delete it. If `old` occurs more than once, set `occurrence: 1` for the first occurrence, `2` for the second, and so on. Targets may not overlap.

| Operation | Parameters and defaults |
|---|---|
| `read` | Required `path`; optional `start_line` (default `1`), `end_line` (through end of file), `max_bytes` (session `max_read_bytes`, default `262_144`) |
| `write` | Required `path`, UTF-8 `content`, and `snapshot` (64 lowercase hex characters, or `"missing"`) |
| `edit` | Required `path`, `snapshot` and `edits`; 1–100 replacements; optional per-edit `occurrence` is 1–10,000 |
| Whole-file bound | Session `max_file_bytes`, default `8_388_608` bytes; applies even to ranged reads and to the new content of writes/edits |

Read results include `path`, `content`, `snapshot`, `bytes`, `bytes_returned`, `encoding`, `binary`, `line_count`, `newline`, `truncated` and `truncation.output`. Text reads also include `start_line` and `end_line`. Binary reads have `content: nil`, `encoding: "binary"` and bounded `base64`; selecting lines from binary data is rejected.

Write/edit results include `path`, `snapshot`, `previous_snapshot`, `bytes_written`, `created` and `changed`. Edit also reports `replacements`. An unchanged write reports `changed: false` and `bytes_written: 0`.

| File conflict/rejection reason | What to do |
|---|---|
| `:stale_snapshot` | Read the current file and decide on a new edit; the error includes expected and actual snapshots |
| `:ambiguous_match` | Read the relevant text and select an explicit occurrence |
| `:target_not_found` | Re-read; do not guess a broader replacement |
| `:overlapping_edits` | Choose nonoverlapping targets in the original file |
| `:concurrent_change` | Another writer changed file identity or confinement during the operation; inspect before trying a new operation |
| `:binary_range` / `:binary_file` | Binary reads cannot select lines; exact text edits reject binary files |
| `:file_too_large` | Narrow the task or deliberately change your application's file budget |

Direct `OhMyJido.Files` failures return `{:error, %{reason: reason, message: text, ...}}`. Action execution can wrap these details in a `Jido.Action.Error` exception. See the [API reference](../reference/api.md) for error envelopes and [configuration](../reference/configuration.md) for budgets.

## Find files and text

Use `"list"` to discover paths, then `"search"` to find source lines:

```elixir
{:ok, files} =
  OhMyJido.execute_tool(session, "list", %{path: "lib", glob: "**/*.ex"})

{:ok, matches} =
  OhMyJido.execute_tool(session, "search", %{
    path: "lib",
    glob: "**/*.ex",
    pattern: "defmodule",
    mode: "literal"
  })
```

Ripgrep supplies file discovery and ignore behavior; GlobEx filters relative glob results without overriding those ignore rules. Globs are relative to `path`; the preview rejects absolute globs and any glob containing `..`. Discovery excludes Git internals, does not follow symlinks, and does not load global or parent ignore configuration. The model supplies neither a discovery executable nor a shell command. Missing ripgrep is reported as `{:capability_unavailable, :ripgrep}` in the error details.

| Parameter | Applies to | Default / meaning |
|---|---|---|
| `path` | Both | `"."`; confined file or directory |
| `glob` | Both | `"**/*"`; relative glob, for example `"**/*.{ex,exs}"` |
| `hidden` | Both | `false`; `true` includes hidden paths, never Git internals |
| `ignore` | Both | `true`; respect workspace `.gitignore`, `.ignore` and `.rgignore` rules |
| `max_results` | Both | `200`, capped by session `search_max_results` |
| `max_bytes` | Both | `131_072` JSON bytes of retained entries, capped by `search_max_output_bytes` |
| `pattern` | Search | Required, nonempty; default pattern ceiling is `4096` bytes |
| `mode` | Search | `"literal"`; use `"regex"` explicitly for regular expressions |
| `case_sensitive` | Search | `true` |
| `max_line_bytes` | Search | `2048`, capped by `search_max_line_bytes` |

List returns `paths`, `count`, `path`, `skipped`, `truncated` and `truncation`. Paths are sorted and workspace-relative. Search returns `matches`, `count`, `path`, `scanned_files`, `scanned_bytes`, `skipped`, `truncated` and `truncation`. Each matching line reports `path`, `line`, `column`, `text`, `text_truncated` and its whole-file `snapshot`. Search returns the first match position per matching line; its text excludes only the line terminator.

Search lines and columns are one-based; columns count **bytes**, not LSP UTF-16 units or AST graphemes. Inspect `skipped` counts (`binary`, `large`, `denied`, `changed`, `unsafe`) and the `truncation` flags (`results`, `output`, `enumeration`, `files`, `lines`, `deadline`) before treating a result as complete.

Default discovery/scan ceilings are 10,000 files, 1,048,576 discovery-output bytes, 33,554,432 scanned bytes and a 10,000-millisecond deadline. Ignore-rule traversal is bounded to 100,000 entries and depth 64. These are application-configured limits, not additional model-facing Action parameters; see [configuration](../reference/configuration.md).

## Run a test command

Shell launches an executable with an argument vector. It does not parse a command string or change the BEAM's working directory or environment.

This example explicitly enables process tools and grants execution permission. It also needs `mix` on the application's executable search path:

```elixir
{:ok, process_session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: :process,
    permissions: [:exec]
  )

{:ok, process} =
  OhMyJido.execute_tool(
    process_session,
    "shell",
    %{
      executable: "mix",
      args: ["test"],
      cwd: ".",
      env: %{"MIX_ENV" => "test"},
      timeout_ms: 20_000
    },
    timeout: 30_000
  )
```

Running a repository's tests, build scripts or configuration executes that repository's code.

| Shell parameter | Default / meaning |
|---|---|
| `executable` | Required nonempty executable name or path; names resolve through `System.find_executable/1`, relative executable paths resolve from `cwd` |
| `args` | `[]`; explicit list of strings |
| `cwd` | `"."`; existing directory within the workspace |
| `env` | `%{}`; child-only overrides of the inherited environment; `nil` unsets a variable |
| `timeout_ms` | Session `process_timeout_ms`, falling back to `tool_timeout_ms` and then `30_000`; a positive value can narrow, not increase, the ceiling |
| `max_output_bytes` | Session `max_output_bytes`, default `1_048_576` **per stream**; `0` retains no output; a request cannot raise the ceiling |

For shell syntax such as pipes, explicitly choose `executable: "sh"` and `args: ["-c", expression]`. Your Host policy decides which commands need approval. The default `OhMyJido.Host.Local` asks for effects marked sensitive; it does **not** ask for every Shell command. See [permissions and approvals](permissions-and-approvals.md) to require additional consent.

A successful API return means a process result was collected, not that the command passed. Check `status`, `exit_status`, `effect` and any truncation:

| Result field | Meaning |
|---|---|
| `stdout`, `stderr` | Separately retained stream bytes; not a merged or necessarily UTF-8 transcript |
| `output_bytes` | `%{stdout: total_bytes, stderr: total_bytes}` before retention limits |
| `truncated` | At least one stream exceeded its retained-output cap; excess bytes were drained |
| `status` | `:exited`, `:timed_out`, `:cancelled`, `:owner_down` or `:failed` |
| `exit_status` | Observed exit code, or `nil` when unavailable; nonzero is not a passing check |
| `duration_ms`, `os_pid` | Elapsed time and transient OS process identity |
| `cleanup` | `:confirmed` or `:uncertain`; confirmed means no live member of the owned process group remains |
| `cancellation` | `:not_requested`, `:confirmed` or `:uncertain` |
| `effect` | `:completed`, `:not_started` or `:uncertain`; cleanup cannot undo earlier writes |

Managed streaming output reaches subscribers as `:tool_output` events with `stream` and `text` payload fields. See [running tasks](running-tasks.md) for event handling. Keep the Action execution budget long enough for the command and cleanup; increasing a call's `timeout` does not increase the session's subprocess ceiling.

## Inspect and change Git state

Git provides fixed workflows rather than arbitrary Git arguments. Inspection needs `:git`, not `:exec`. Commit and worktree mutation also need `:edit`.

```elixir
{:ok, git_session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: :process,
    permissions: [:git]
  )

{:ok, status} = OhMyJido.execute_tool(git_session, "git", %{operation: "status"})

{:ok, diff} =
  OhMyJido.execute_tool(git_session, "git", %{
    operation: "diff",
    paths: ["lib/demo.ex"],
    context_lines: 5
  })
```

Add `:edit` only when the session must also commit or manage worktrees.

| `operation` | Inputs beyond `repo` | Result |
|---|---|---|
| `"status"` | None | Process result plus parsed porcelain `entries` and `clean` |
| `"diff"` | `paths`, optional `base`, `cached`, `context_lines` | Bounded diff in `stdout`, with process status and truncation |
| `"log"` | Optional `revision`, `limit` | Bounded commit log in `stdout` |
| `"patch_context"` | Diff selectors | `head`, `status`, `diff`, `stderr`, `truncated` and the diff `process` result |
| `"commit"` | Nonempty explicit `paths` and `message` | Process result plus observed `commit` identity and `paths` |
| `"worktree_add"` | Absent target `path`; optional `revision` (default `"HEAD"`) | Detached worktree pinned to a commit; result adds `path` and `head` |
| `"worktree_remove"` | Registered, clean target `path` | Process result plus removed `path` |

| Git parameter | Default / bound |
|---|---|
| `repo` | `"."`; confined repository directory |
| `paths` | `[]`; all paths for diff, but rejected for commit; commit paths must name explicit files, not directories |
| `base`, `revision` | Optional revision strings; at most 512 bytes, no leading `-`, NUL or newline |
| `cached` | `false`; `true` selects staged diff |
| `context_lines` | `3`; 0–100 |
| `limit` | `20`; 1–100 log entries |
| `message` | Required for commit; nonblank, at most 16,384 bytes, no NUL |
| `path` | Required for worktree add/remove |
| `timeout_ms`, `max_output_bytes` | Same subprocess ceilings as Shell; timeout must be positive and output cap can be `0` |

A commit stages and commits only the explicit paths, preserving unrelated staged work. Staging and committing are separate sensitive phases, each authorized before execution. A later failure does not roll back an earlier phase. Git failures retain process evidence: `{:git_failed, process_result}` for a nonzero exit, `{:uncertain_git_effect, process_result}` for an interrupted/uncertain operation, and `{:git_output_truncated, process_result}` where complete output was required.

Trusted `metadata.git_worktree_roots` controls where worktrees may be created or removed. Roots must already exist and default to the workspace. Creation requires an absent target. Removal refuses dirty, unregistered and source worktrees; there is no force flag. `OhMyJido.Git.isolate/3` additionally requires a clean source repository and returns a real detached worktree and narrowed-workspace Context. Changed child worktrees stay available for your application's review, merge or archive policy; see [subagents](subagents.md).

There are no push, remote, force, reset or history-rewrite operations. Git children disable hooks, external diff/text conversion, fsmonitor and signing, and remove ambient Git override variables. These changes apply to the child process, not globally.

## Register a custom Jido Action

A custom Action lets your application expose a focused operation without giving the model arbitrary module or function execution. This Action reuses the confined, permission-checked file API:

```elixir
defmodule MyApp.FileIdentity do
  use Jido.Action,
    name: "file_identity",
    description: "Return a file's byte count and whole-file snapshot",
    schema: Zoi.object(%{path: Zoi.string()})

  def capability, do: :read

  @impl true
  def run(%{path: path}, execution_context) do
    with {:ok, file} <- OhMyJido.Files.read(execution_context, path) do
      {:ok, Map.take(file, [:path, :bytes, :snapshot])}
    end
  end
end

:ok = OhMyJido.register_tool(session, MyApp.FileIdentity)
{:ok, identity} = OhMyJido.execute_tool(session, "file_identity", %{path: "mix.exs"})
:ok = OhMyJido.unregister_tool(session, "file_identity")
```

Registration and unregistration use native Jido.AI APIs and require an idle session; an active run returns `{:error, :run_active}`. Unregistration removes future tool exposure. It does not undo prior effects.

`capability/0` declares which permission filters the Action. It is **not** an authorization implementation. Your `run/2` must call `OhMyJido.Tool.authorize/3` at the effect boundary or use a library operation that does, as `Files.read/3` does above. An Action without `capability/0` requires `:custom` permission before execution.

Keep Action modules, function names, MFAs, executors and privileged adapter options under your application's control, not model input. If your Action invokes an external service, its real result must preserve deadlines, cleanup status and uncertainty rather than inventing a successful fallback.

## Reuse approved skills

A skill is reusable guidance, not an executable extension or a permission grant. The Skill Action uses Jido.AI's discovery, specification, resource-policy, loading and session activation support. It scans only explicitly approved roots or configured skills, never ambient home directories or the global skill registry.

To discover filesystem skills, supply trusted session metadata for an existing workspace directory:

```elixir
metadata = %{
  skill_roots: [%{path: ".agents/skills", approved: true}]
}
```

An outside-workspace skill root needs an absolute path and `scope: :host` as well as `approved: true`. That is a trusted application decision. Model or repository text cannot approve its own root.

You can also provide an approved inline skill without a filesystem scan:

```elixir
spec = %Jido.AI.Skill.Spec{
  name: "host-review",
  description: "Application review guidance",
  source: nil,
  body_ref: {:inline, "Preserve approvals and distinguish findings from proposals."},
  allowed_tools: ["read"]
}

{:ok, skill_session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    tools: [OhMyJido.Tools.Skill],
    permissions: [:skills],
    metadata: %{skills: [%{skill: spec, approved: true}]}
  )

{:ok, catalog} =
  OhMyJido.execute_tool(skill_session, "skill", %{operation: "discover"})

{:ok, guidance} =
  OhMyJido.execute_tool(skill_session, "skill", %{operation: "load", name: "host-review"})
```

| Skill setting / operation | Behavior |
|---|---|
| `operation: "discover"` | Returns approved names/descriptions in `skills`, with `authority: :guidance_only` |
| `operation: "load", name: name` | Strictly activates that approved skill and returns guidance with `authority: :guidance_only` |
| `metadata.skills` | Approved `%{skill: spec, approved: true}` entries or approved application-authored skill modules resolved through Jido.AI |
| Discovery bounds | Depth 6 and 2,000 directories |
| Loaded guidance bound | Session `skill_bytes`, default `262_144` bytes |
| Activation scope | Runtime, workspace and session; cleared at teardown |

Native `allowed-tools` metadata is advisory. Loading never executes scripts, grants tools or bypasses approval. Malformed frontmatter or activation produces a structured error. A successfully loaded skill's call/result guidance remains a complete, lower-priority exchange across compaction.

## Approve project instructions

Configure instruction authority in your application, not in task metadata or repository code. For example, this runtime configuration trusts your application's own instructions and an explicitly approved project instruction envelope:

```elixir
{OhMyJido,
 name: MyApp.Coding,
 instructions: "Preserve unrelated user changes.",
 project_instructions: %{
   approved: true,
   instructions: "Use the project's existing module layout."
 }}
```

| Precedence, highest first | Source |
|---|---|
| Trusted application instructions | Runtime `instructions` and `system_prompt` |
| Approved project instructions | `project_instructions: %{approved: true, instructions: text}`; an approved envelope may also use `body`. Non-envelope text/list input requires trusted `project_approved: true`. |
| Approved skill guidance | Explicitly approved configured skills and loaded skill guidance |

Task metadata and repository, tool or page content are quoted data, not instruction authority. The prompt composer does not evaluate repository Elixir configuration. Lower-priority guidance applies only when consistent with higher-priority instructions and the task. `OhMyJido.Prompt.compose/3` returns `{:ok, text}` or an explicit configuration error.

## Call operation APIs from trusted code

If you already hold a trusted `OhMyJido.Context`, the operation modules expose the same workspace and permission boundaries. For example:

```elixir
{:ok, file} = OhMyJido.Files.read(context, "mix.exs", start_line: 1, end_line: 20)
```

A hand-built Context does not create a session journal. Prefer `execute_tool/4` or managed agent Actions when you need effect recording and recovery. See [Jido agents](jido-agents.md) for Context construction and standalone Action execution. Native V3 execution has no retry loop and does not accept the Jido 2-only `max_retries` option on `Jido.Exec.run/4`.

| Module under `OhMyJido` | Direct operations |
|---|---|
| `Workspace` | `new(root)`, `resolve(context, path, options \\ [])`, `relative(context, path)`; roots must exist; `allow_missing: true` is only for explicitly permitted missing targets |
| `Files` | `read(context, path, options \\ [])`, `write(context, path, content, snapshot, options \\ [])`, `edit(context, path, snapshot, edits, options \\ [])`, `snapshot(bytes)` |
| `Search` | `files(context, path \\ ".", options \\ [])`, `text(context, pattern, options \\ [])` |
| `Process` | `run(context, executable, args, options \\ [])`, `start(context, executable, args, options \\ [])`, owner-only `await(handle, timeout \\ :infinity)`, `cancel(handle)` |
| `Git` | `status`, `diff`, `log`, `patch_context` with `(context, options \\ [])`; `commit(context, message, options \\ [])`, `create_worktree(context, path, options \\ [])`, `remove_worktree(context, path, options \\ [])`, `isolate(context, child_id, options \\ [])` |
| `Tool` | `authorize(context, capability, effect \\ %{})`, `find(context, exact_name)`, `execute(context, exact_name, params, options \\ [])` |
| `Tools` | `default/0`, `bundles/0`, `select/1`, `select!/1` |
| `Prompt` | `compose(context, task_metadata, runtime_config)` |

Direct Process/Git options use `timeout`, not the Action parameter `timeout_ms`. `OhMyJido.Process.start/4` returns an opaque caller-owned handle; only its owner may `await/2`, and an await timeout neither cancels nor replays the command. Owner death triggers cancellation. Direct Process callers can also supply `on_output` (a recipient PID or two-argument stream/data callback), an `observer` PID, and `kill_grace_ms` (default `100`, allowed 0–5,000). Streaming and retained output share the same per-stream cap. Function callbacks run in the owner during `await/2`.

Trusted, already-authorized Port integrations additionally have `OhMyJido.Process.capture_identity/1` and `OhMyJido.Process.terminate_group/2`. They are not model-facing operations. See the [API reference](../reference/api.md) for these functions and the `Models`, `ContextPolicy` and `Redact` APIs.

## Limits

- Permissions and workspace confinement are library policy, not an OS sandbox. Isolate untrusted commands with an OS user, container, cgroups and network policy; see [security](security.md).
- In-process file writers serialize by canonical path. External writers are rechecked but not OS-locked.
- Output limits can hide relevant content. A result with truncation or skipped files is not complete evidence.
- Process-group cleanup cannot undo writes and does not prevent deliberate daemonization or group escape. Interrupted effects can remain uncertain even after confirmed cleanup.
- Optional services fail explicitly when unavailable. A tool registry or bundle does not provide a service, a permission or an approval.

## Related

- [Permissions and approvals](permissions-and-approvals.md)
- [Delegate focused tasks](subagents.md)
- [Language intelligence](language-intelligence.md)
- [Live applications](live-applications.md)
- [External integrations](integrations.md)
- [Eval](eval.md)
- [Configuration reference](../reference/configuration.md)
- [Public API reference](../reference/api.md)
