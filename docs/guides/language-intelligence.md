# Navigate, refactor and debug code

Use language intelligence when you need more than text search: find a symbol's definition, preview a rename across files, replace a parsed Elixir expression, or stop a program at a breakpoint. Oh-My-Jido supplies structural Elixir editing and clients for language servers and debuggers. Your application chooses and starts any external server.

## Before you start

| Task | Tool | Permissions | External service |
|---|---|---|---|
| Search parsed Elixir syntax | `"ast"` | `:ast`, `:read` | None; uses ExAST |
| Replace parsed Elixir syntax | `"ast"` | `:ast`, `:read`, `:edit` | None; uses ExAST |
| Navigate or get diagnostics | `"lsp"` | `:lsp`; reading source also needs `:read` | An approved language server |
| Apply a rename | `"lsp"` | `:lsp`, `:read`, `:edit`, plus sensitive approval | An approved language server |
| Debug a program | `"debug"` | `:debug`; launch also needs sensitive approval | An approved Debug Adapter Protocol server |

The `:elixir` bundle makes AST, LSP and Debug available. It does not grant these permissions or launch a service. The examples below use explicit tool lists. See [tools](tools.md) and [permissions and approvals](permissions-and-approvals.md) for those independent choices.

**Tested with:** ElixirLS 0.31.1 and GDB 15.1. ElixirLS 0.31.1 does not provide standard `textDocument/rename`; select the Elixir rename backend below. Expert 0.1.11 also does not advertise `renameProvider`. Do not assume navigation support implies rename support.

## Connect a language server

LSP means Language Server Protocol. It lets a language-specific service answer questions about your project. Install and review the server and its launcher yourself; Oh-My-Jido does not install a server or project dependencies.

Put an ordinary `DynamicSupervisor` named `MyApp.Intelligence` alongside your `MyApp.Coding` runtime in your application's supervision tree:

```elixir
children = [
  {OhMyJido, name: MyApp.Coding},
  {DynamicSupervisor, name: MyApp.Intelligence, strategy: :one_for_one}
]
```

Prepare a stable session identity before starting the server. In this setup code, `workspace` is your approved existing project directory, `executable` is your approved installed server launcher, and `args` is its argument list:

```elixir
{:ok, root} = OhMyJido.Workspace.new(workspace)
id = Jido.Util.generate_id()
permissions = [:read, :lsp, :edit]

context = %OhMyJido.Context{
  runtime: MyApp.Coding,
  session_id: id,
  workspace: root,
  permissions: MapSet.new(permissions)
}

{:ok, server} =
  DynamicSupervisor.start_child(MyApp.Intelligence,
    {OhMyJido.Intelligence.LSP,
     context: context, executable: executable, args: args}
  )

{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    id: id,
    workspace: root,
    permissions: permissions,
    tools: [OhMyJido.Tools.Read, OhMyJido.Tools.LSP],
    adapters: %{lsp: {OhMyJido.Intelligence.LSP, server: server}}
  )
```

Omit `:edit` for a navigation-only session. For a session that will use ElixirLS renames, add `rename_backend: :elixir` to the LSP binding as shown below.

The Context is trusted setup data, not something the model constructs. The server belongs to this session ID and workspace; it cannot be rebound to another identity. If `start_session/2` fails, release the prepared server with `OhMyJido.Intelligence.LSP.close_session(context, server: server)`. Keep its owner alive: startup accepts a trusted `owner:` PID and otherwise uses the Context's coordinator or the process starting the adapter. Recreate per-session bindings when restoring a session or creating a child session; do not copy another session's protocol PID.

There is no public `get_context` or `set_adapter` function. If your application keeps services in a per-session registry, resolve that registry in your policy's `invoke/4` callback (see `OhMyJido.Host`) instead of saving a transient PID for reuse. See [adapter ownership](integrations.md#own-adapter-resources).

### Open source and navigate

```elixir
{:ok, initialized} =
  OhMyJido.execute_tool(session, "lsp", %{operation: "initialize"})

{:ok, opened} =
  OhMyJido.execute_tool(session, "lsp", %{
    operation: "open",
    path: "lib/my_app/counter.ex"
  })

{:ok, symbols} =
  OhMyJido.execute_tool(session, "lsp", %{
    operation: "symbols",
    path: opened.path
  })
```

Open and change send the actual confined file's full text, not model-supplied document contents. Versions increase; you may request a positive `version`, but stale versions are rejected. After an ordinary disk edit, call `"change"` before asking the server about that document. Diagnostics are actual `publishDiagnostics` notifications: a notification that has not arrived is unavailable, not a fabricated empty result.

| `operation` | Request fields | Result |
|---|---|---|
| `"initialize"` | None | Server `capabilities` and bound `identity` |
| `"open"`, `"change"` | `path`; optional `version` | `path`, whole-file `snapshot`, `version`, `identity` |
| `"close_document"` | `path` | `closed_document`, `identity` |
| `"diagnostics"` | `path` | `diagnostics`, `source: :server_notification`, `identity` |
| `"definition"` | `path`, `line`, `character` | The server's data in `result`, with `identity`, `trusted: false` |
| `"references"` | `path`, `line`, `character`; `include_declaration: true` by default | The server's data in `result`, with `identity`, `trusted: false` |
| `"symbols"` | `path` | Document symbols in `result`, with `identity`, `trusted: false` |
| `"rename"` | `path`, `line`, `character`, `new_name`; optional `apply`, `snapshot`, `snapshots` | Preview or changed-file result |
| `"shutdown"` | None | Server shutdown outcome and owned-process cleanup result |

LSP `line` and `character` are **zero-based UTF-16 code-unit positions**. The client rejects a server that negotiates a different encoding. `language_id` is a trusted adapter option, defaulting to `"elixir"`.

For a cold server, set `timeout_ms` in the adapter's start options and in the session's `adapters.lsp` binding, and raise the prepared Context's `limits.protocol_timeout_ms`. Each defaults to 10,000 ms and the smallest wins. `start_session/2` takes no per-session limits. The whole tool call is also limited to `tool_timeout_ms` plus `question_timeout_ms` (330 seconds by default); for longer waits, raise runtime `tool_timeout_ms` or pass `timeout:` to `execute_tool/4`. A server launcher may compile or provision its own dependencies, so review that launcher too.

## Preview and apply a rename

First choose the backend in application configuration, not in the tool request:

```elixir
adapters: %{
  lsp: {OhMyJido.Intelligence.LSP, server: server, rename_backend: :elixir}
}
```

| `rename_backend` | How it plans edits |
|---|---|
| `:server` (default) | Sends `textDocument/rename`; the server must support it |
| `:elixir` | Combines authored Elixir syntax with the bound server's definition/reference identity and supported ElixirLS-specific checks |

A failed or unsupported server rename never falls back automatically. The model cannot select a backend, executor or MFA.

For example, if `lib/my_app/counter.ex` contains the following code, `add` starts at LSP line `1`, character `6`:

```elixir
defmodule MyApp.Counter do
  def add(count), do: count + 1
end
```

Request a preview, inspect every proposed file and edit, then apply against those snapshots:

```elixir
rename = %{
  operation: "rename",
  path: "lib/my_app/counter.ex",
  line: 1,
  character: 6,
  new_name: "increment"
}

{:ok, preview} = OhMyJido.execute_tool(session, "lsp", rename)
# Review preview.files before authorizing the next call.

snapshots = Map.new(preview.files, &{&1.path, &1.snapshot})

{:ok, applied} =
  OhMyJido.execute_tool(session, "lsp",
    Map.merge(rename, %{
      apply: true,
      snapshot: Map.fetch!(snapshots, rename.path),
      snapshots: Map.delete(snapshots, rename.path)
    })
  )
```

This example expects a nonempty preview that edits the selected file. A no-op returns `applied: false, files: [], reason: :no_edits`; do not try to apply that as a rename. `apply` defaults to `false` and previews write no source files. Applying requires `:edit` and sensitive approval through your application's [approval flow](permissions-and-approvals.md).

### What a rename checks

| Check | Contract |
|---|---|
| File identity | `snapshot` covers the selected file; `snapshots` maps every other edited relative path to its whole-file SHA-256. All are required for application. |
| Document identity | Non-null versions from `documentChanges` must match bound open documents before any write. A null version remains unversioned. |
| Edit shape | Rejects workspace create/delete/rename operations, duplicate documents, ambiguous edit formats, surrogate splits, overlaps and out-of-range edits. |
| Insertions | Equal-position insertions preserve server order, including insertions before a replacement at the same position. |
| Size | General workspace edits allow at most 32 documents and 1,000 edits per document. The Elixir backend additionally caps the whole plan at 1,000 occurrences. |
| Publication | Writes use the ordinary snapshot-guarded file writer, then synchronize the owned language-server documents. |
| Result | Preview files contain `path`, `snapshot`, `edits`, `version`. Applied files contain `path`, resulting `snapshot`, `bytes`; success has `applied: true, effect: :completed`. Backend and planning metadata identify how the plan was made. |

Multi-file application is **not a transaction**. A `:workspace_edit_conflict` error reports `failed_path`, `applied` and `failure`. A `:lsp_rename_sync_failed` error reports completed writes in `applied`, with `effect: :completed` and `retry: false`. A partial write failure also retains its real written subset and forbids automatic retry. Inspect those paths and reconcile; do not rerun the whole rename as if nothing changed.

Before writing, the result budget must hold the complete compact changed-path/snapshot result. Optional `identity` and `rename_metadata` may be omitted if too large. A result-size failure must not erase completed writes or their effect certainty.

### Supported Elixir rename scope

The Elixir backend checks every nonignored `.ex` and `.exs` file, including hidden files, within the inventory limits below. It uses parsed source and the language server's definitions and references to identify the symbol. If the inventory is incomplete or the symbol cannot be identified safely, it returns an error rather than a partial rename.

| Symbol or construct | Supported boundary |
|---|---|
| Functions | Overlapping default-arity and multi-clause families, imports, captures and pipes, when symbol identity and destination collision checks succeed |
| Variables | Language-server binding identity, including rebindings and captures; spelling alone does not merge bindings |
| Modules | Same-namespace leaf renames and proved implicit aliases, including bare nested module declarations; explicit local alias names are retained |
| Direct-module `@spec` heads | Renames the structurally identified function head when the language server confirms its definition |
| Compiler-owned destinations | Rejects `module_info/0` and `module_info/1`, including overlap caused by default arguments. A distinct legal `module_info/2` is not rejected by spelling alone. |

Use the **ElixirLS 0.31.1 profile** for caller-environment, namespace and function-versus-macro checks. Other server profiles cannot use those ElixirLS-specific checks. The [identity reference](#elixir-rename-identity-reference) describes the required server responses.

Unsupported cases include namespace moves, module descendants or descendant references that cannot be preserved, qualified nested declaration aliases, grouped or dynamic aliases, generated or ambiguous identity, opaque macro/compiler/callback scopes, unproved type/spec/callback calls, unprovable import/alias capture and runtime symbol dependencies.

| Trusted option / Context limit | Hard ceiling | Meaning |
|---|---|---|
| `rename_max_files` | `128` | Nonignored Elixir source files |
| `rename_max_bytes` | `8_388_608` (8 MiB) | Total source bytes |
| `rename_max_file_bytes` | `1_048_576` (1 MiB) | Bytes per source file |
| `rename_max_candidates` | `2_000` | Language-server requests used to prove the plan |

Trusted options and Context limits can lower these ceilings, not raise them. Metadata records the inventory, backend, source fingerprints and language-server request counts. Typical reasons include `:elixir_rename_inventory_limit`, `:elixir_rename_incomplete_inventory`, `:elixir_rename_inventory_changed` and `:elixir_rename_server_documents_changed`; these mean the planner could not safely establish a complete plan.

## Search and replace parsed Elixir code

AST means abstract syntax tree: the parsed structure of code. Use `"ast"` for a known structural transformation in one explicit file, rather than semantic cross-file symbol identity. Elixir uses installed ExAST captures and Sourceror-compatible ranges.

```elixir
{:ok, ast_session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:ast, :read, :edit],
    tools: [OhMyJido.Tools.AST]
  )

{:ok, found} =
  OhMyJido.execute_tool(ast_session, "ast", %{
    operation: "search",
    path: "lib/my_app/counter.ex",
    pattern: "IO.inspect(value)"
  })

false = found.truncated
# Review found.matches before replacing the complete match set.

{:ok, replaced} =
  OhMyJido.execute_tool(ast_session, "ast", %{
    operation: "replace",
    path: found.path,
    pattern: "IO.inspect(value)",
    replacement: "Logger.debug(value)",
    snapshot: found.snapshot,
    expected_count: found.count
  })
```

The pattern matches code structure, not strings or comments containing that text. Only selected source fragments are spliced. Publication goes through `OhMyJido.Files.write/5`; it does not ask ExAST to write files or reformat unrelated code. You remain responsible for whether the replacement is appropriate, including required imports or `require` statements.

| Field or result | Contract |
|---|---|
| `operation` | `"search"` or `"replace"` |
| `path`, `pattern` | Required; one explicit confined file and structural pattern |
| `language` | Optional; inferred from the extension when absent |
| `max_results` | Defaults to `100`; request range `1..1_000`, further limited by `ast_max_results` |
| Replacement fields | `replacement`, `snapshot` and `expected_count` required; `expected_count` is `0..1_000` |
| `ranges` | Optional exact ranges from search, selecting a subset for replacement; mismatched, duplicate or overlapping selections fail |
| Coordinates | `%{start: %{line: 1, column: 1}, end: %{line: 1, column: 5}}`; one-based lines and **grapheme** columns, exclusive end |
| Search result | `path`, whole-file `snapshot`, `matches` (`range`, exact `source`, `captures`), `count`, `truncated`, `language`, `operation` |
| Replacement result | Previous/new snapshots, `count`, `changed`, and applied range/source/replacement entries |
| Defaults and bounds | `ast_file_bytes: 1_048_576` (hard maximum), `ast_result_bytes: 65_536`, `ast_max_results: 1_000`; pattern at most 8,192 bytes, replacement at most 16,384 bytes |
| Common reasons | `:ast_snapshot_required`, `:ast_expected_count_required`, `:stale_snapshot`, `:ast_match_limit`, `:ast_parse_error` |

AST failures return `{:error, %{reason: reason, message: text, ...}}` through the structural implementation. Other languages require a real approved `:ast` adapter. A search reply must carry the same `path`, `snapshot`, `matches` and `truncated`; a `:plan_replace` reply must carry the same identity and range/replacement plans. Adapters **plan only**: the core extracts original fragments locally, checks identity, ranges, count and overlap, then uses the guarded writer. Without a configured parser, the result is unavailable rather than a text fallback labeled AST.

## Debug a program

DAP means Debug Adapter Protocol. Your application starts an approved adapter and binds it under `:debug`, using the same session-identity setup as LSP. The program, working directory and breakpoint source must remain inside the workspace. Trusted adapter options select the executable, arguments, `adapter_id` (default `"host"`) and `launch` defaults.

### Choose the correct launch order

`"launch"` is asynchronous. It returns `%{status: :pending, request_id: id, ...}`, not proof that startup succeeded. The request ID is budgeted before dispatch and retained even when optional result data does not fit.

| Adapter behavior | Operation order |
|---|---|
| Defers launch until configuration, including the tested ElixirLS adapter | `initialize` → `launch` → `wait_initialized` → `breakpoints` → `configuration_done` → `await_launch` → `wait_stopped` |
| GDB 15.1, which starts the inferior immediately on launch | Preload the approved program in trusted adapter arguments, then `initialize` → `wait_initialized` → `breakpoints` → `configuration_done` → `launch` → `await_launch` → `wait_stopped` |

For GDB, prepare a Context with `:debug` and a matching session ID. Here `program` is a project-relative executable already built with debug information:

```elixir
{:ok, debug_context} =
  OhMyJido.Context.new(
    runtime: MyApp.Coding,
    workspace: workspace,
    permissions: [:debug],
    tools: [OhMyJido.Tools.Debug]
  )

{:ok, absolute_program} = OhMyJido.Workspace.resolve(debug_context, program)

{:ok, debugger} =
  DynamicSupervisor.start_child(MyApp.Intelligence,
    {OhMyJido.Intelligence.DAP,
     context: debug_context,
     executable: System.find_executable("gdb"),
     args: ["--interpreter=dap", "--quiet", absolute_program],
     adapter_id: "gdb"}
  )

{:ok, debug_session} =
  OhMyJido.start_session(MyApp.Coding,
    id: debug_context.session_id,
    workspace: debug_context.workspace,
    permissions: [:debug],
    tools: [OhMyJido.Tools.Debug],
    adapters: %{debug: {OhMyJido.Intelligence.DAP, server: debugger}}
  )
```

As with LSP, close the prepared adapter if session creation fails. Then use the GDB order; `source` and `breakpoint_line` are your approved project-relative source path and one-based breakpoint line:

```elixir
{:ok, _} = OhMyJido.execute_tool(debug_session, "debug", %{operation: "initialize"})
{:ok, _} = OhMyJido.execute_tool(debug_session, "debug", %{operation: "wait_initialized"})

{:ok, breakpoints} =
  OhMyJido.execute_tool(debug_session, "debug", %{
    operation: "breakpoints", path: source, lines: [breakpoint_line]
  })

true = Enum.any?(breakpoints.result["breakpoints"], &(&1["verified"] == true))
{:ok, _} = OhMyJido.execute_tool(debug_session, "debug", %{operation: "configuration_done"})

{:ok, pending} =
  OhMyJido.execute_tool(debug_session, "debug", %{operation: "launch", program: program})

{:ok, launched} =
  OhMyJido.execute_tool(debug_session, "debug", %{
    operation: "await_launch", request_id: pending.request_id
  })

{:ok, stopped} = OhMyJido.execute_tool(debug_session, "debug", %{operation: "wait_stopped"})
# Inspect the actual stopped event and use the operations below before terminating.
```

A finite await timeout removes that waiter, not the pending launch. Await the same request ID later; do not launch again. An unknown launch outcome is reported as `:debug_launch_outcome_unknown` with `effect: :uncertain`. State-changing DAP requests can similarly return `:debug_operation_outcome_unknown`.

### Inspect and control the stopped program

DAP lines and columns are **one-based**. Thread IDs, frame IDs and variable references must come from actual debugger replies, not guessed identifiers.

| `operation` | Fields / result |
|---|---|
| `"initialize"` | Returns the debugger's capabilities in `result` |
| `"launch"` | Required `program`; `cwd: "."`, `args: []` by default; sensitive approval |
| `"await_launch"` | Required `request_id`; returns actual launch reply in `result` |
| `"wait_initialized"`, `"wait_stopped"` | Returns the debugger's raw `event`; a stopped event may contain `body.threadId` |
| `"breakpoints"` | Required `path`; `lines: []` by default; at most 1,000 positive lines; inspect each debugger-supplied `verified` flag |
| `"configuration_done"` | Completes breakpoint/configuration setup |
| `"threads"` | Returns the debugger's thread records in `result` |
| `"stack_trace"` | Required `thread_id`; `start_frame: 0`, `levels: 20` by default; `levels` range `1..100` |
| `"scopes"` | Required `frame_id` from a returned stack frame |
| `"variables"` | Required positive `variables_reference` from a returned scope/variable; `start: 0`, `count: 100` by default; `count` range `1..1_000` |
| `"step_over"`, `"step_in"`, `"step_out"`, `"continue"`, `"pause"` | Required `thread_id`; wait for the next actual stopped event before inspecting stopped state |
| `"terminate"` | Reports terminate/disconnect outcomes, `debuggee_termination: :acknowledged | :unconfirmed`, and cleanup scoped to the adapter process group |

Finish with:

```elixir
{:ok, cleanup} = OhMyJido.execute_tool(debug_session, "debug", %{operation: "terminate"})
```

Valid DAP events with `body: null` retain their raw message and can satisfy selector-free waits; they do not supply a missing thread ID. A cleanup acknowledgement is not proof that an escaped debuggee has vanished. The Action does not expose attach, evaluate, arbitrary RPC or IEx. Reverse process launch and start-debugging requests are not advertised.

`OhMyJido.Intelligence.DAP.smoke/3` uses the deferred-launch order, so use explicit operations for GDB. Choose the intended Elixir/OTP toolchain explicitly in an ElixirLS launcher's child environment rather than relying on a version manager's ambient choice. Human-invoked helpers are listed in [integrations](integrations.md#exercise-a-real-integration).

## Trusted integration reference

These APIs are for application code that already owns a trusted Context, not unrestricted protocol tools for models. Use managed `execute_tool/4` when you need session effect journaling and approvals.

| Module | Interface |
|---|---|
| `OhMyJido.Intelligence.LSP`, `OhMyJido.Intelligence.DAP` | `start_link/1`, `child_spec/1`, `invoke/3`, `close_session/2` |
| `OhMyJido.Intelligence.AST` | `execute/2` |
| `OhMyJido.Intelligence.TextEdits` | `plan/3`, `apply/2,3`, `transform/2`, `uri/2`, `uri_path/2` |
| `OhMyJido.Intelligence.Stdio` | Shared process/session owner; startup, limits and trusted low-level calls are documented in [integrations](integrations.md#stdio-protocol-reference) |

### Elixir rename identity reference

| Check | Required evidence |
|---|---|
| Symbol identity | Source parsing finds authored tokens; language-server definitions and references establish which symbol they denote. Text matches and Reach dependency graphs do not establish symbol identity. |
| Direct-module `@spec` heads | Only the structurally identified function head is a signature occurrence. Definition identity from the language server is still required. Runtime caller-variable/import/capture checks apply to runtime calls, not to the signature itself. Spec argument/return types, constraints and callback heads have no blanket exemption from identity checks. |
| Whole-statement spec locations | For the supported profile, a language-server location spanning an entire `@spec` is anchored at the exact statement opener and signature, never at calls in its types. A self-resolving signature also needs an independently resolved authored implementation with matching module/name/arity. Circular or missing implementation evidence fails. |
| Missing module-declaration definition | The supported profile may corroborate it with `workspace/symbol`: exact canonical module name, module kind, same authored URI and enclosing declaration range, followed by normal syntax and reference checks. Empty, malformed, conflicting or foreign results cannot create identity. The index result is capped at 1,000 entries. |
| ElixirLS profile | Caller-environment, namespace and function-versus-macro checks use fixed internal `llmEnvironment`/`llmTypeInfo` requests and declaration metadata, not documentation bodies or model-selected commands. Server identity metadata selects a compatible profile; it is not authentication. An unaudited profile cannot borrow the ElixirLS-specific proofs. |
| Synchronized source | The planner synchronizes actual inventory text to its owned LSP buffers before resolving symbols. Successfully sent full text has independent fingerprints from `Stdio.document_sources/1`; a reserved version number alone does not prove current text. Matching text preserves its version, stale text uses ordinary open/change, and incremental or unknown text remains unverified. It rechecks source fingerprints, versions and disk snapshots before returning a plan. It never creates hypothetical renamed documents during preview. |

## Limits

- Search byte columns, AST grapheme columns, LSP UTF-16 positions and DAP positions are different coordinate systems. Do not pass one tool's columns to another unchanged.
- Protocol processes use the Linux stdio owner and its bounded requests/events. Missing executables, malformed/oversized frames, server exit and identity mismatches are real errors; no service or result is fabricated.
- A rename preview writes no source, but a trusted language server can compile or load project dependencies in its own VM. It is not an execution sandbox.
- Applied edits and debugger effects are not automatically retried after uncertain outcomes. Preserve results and reconcile partial changes.

## Related

- [Tool availability and core tools](tools.md)
- [Permissions and approvals](permissions-and-approvals.md)
- [Adapters, protocol limits and cleanup](integrations.md)
- [Inspect live applications](live-applications.md)
- [Isolated Eval](eval.md)
- [Configuration reference](../reference/configuration.md)
- [Public API reference](../reference/api.md)
- [Compatibility and verification status](../project-status.md)
