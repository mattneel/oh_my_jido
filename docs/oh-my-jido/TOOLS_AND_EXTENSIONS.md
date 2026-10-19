# Coding tools, delegation and extensions

Tools are native `Jido.Action` modules with Zoi schemas. Use the public `execute_tool/4` or the native coding agent for authorization, validation, effect journaling and zero automatic effect retries. `OhMyJido.Tools.default/0` is the registry, **not** an implicit capability grant or installation of external services.

## Select availability without granting authority

| Bundle | Native Actions |
|---|---|
| `:read_only` | Read, Search, List |
| `:editing` | Write, Edit |
| `:elixir` | AST, LSP, Debug |
| `:process` | Shell, Git |
| `:live_inspection` | Observer |

`Tools.bundles/0` returns this fixed registry. `Tools.select/1` accepts one bundle or an ordered list and returns `{:ok, modules}` or an explicit selection error; `select!/1` raises on invalid names. Composition keeps first occurrence order and removes duplicate Actions; `[]` selects none. It never creates atoms from input.

Use `bundles:` in `Context.new/1`, Runtime configuration or `start_session/2`; use `tools:` for an explicit replacement Action list. Supplying both at one level is an error. Session selection replaces Runtime availability; it does not add grants. An ordinary standalone Context defaults to read-only availability and **empty permissions**. The managed Runtime retains its full legacy registry unless the host selects a narrower one. Available service Actions still need configured host bindings.

Observer does not grant RPC/evaluation. The Elixir bundle does not launch a server at configuration time. The process bundle does not grant `:exec`, `:git` or approval. Managed-only lifecycle tools remain in the full Runtime/session integration rather than pretending that attaching standalone Actions creates a session.

## Action inventory

Every module below is under `OhMyJido.Tools`.

| Module / exact name | Primary grant | Surface |
|---|---|---|
| `Read` / `"read"` | `:read` | UTF-8/ranged or bounded binary read, whole-file snapshot |
| `List` / `"list"` | `:read` | Confined, ignore-aware file discovery |
| `Search` / `"search"` | `:read` | Literal/regex search, relative locations and explicit bounds |
| `Write` / `"write"` | `:edit` | Atomic guarded UTF-8 create/replace |
| `Edit` / `"edit"` | `:edit` | Exact nonoverlapping replacements against one original snapshot |
| `Shell` / `"shell"` | `:exec` | Approved executable/argv, scoped cwd/env, real streams/status/cleanup |
| `Git` / `"git"` | `:git` | Status/diff/log/patch context; mutations also require `:edit` |
| `AST` / `"ast"` | `:ast` | Native Elixir structural search/replacement; input reads need `:read`, writes need `:edit` |
| `LSP` / `"lsp"` | `:lsp` | Configured server navigation/diagnostics/guarded rename |
| `Debug` / `"debug"` | `:debug` | Configured DAP workflows |
| `MCP` / `"mcp"` | `:mcp` | Host-allowlisted external tools/resources |
| `Browser` / `"browser"` | `:browser` | Host page navigation/snapshot/click/fill/close contract |
| `Research` / `"research"` | `:research` | Host-approved search/read contract |
| `Artifact` / `"artifact"` | `:artifact` | Confined artifact inspection/text and approved native image inputs |
| `Review` / `"review"` | `:review` | Bounded risk hints from actual tracked Git changes |
| `Eval` / `"eval"` | `:eval` | Configured Elixir/JavaScript/Python cells and lifecycle |
| `Skill` / `"skill"` | `:skills` | Discover/load explicitly trusted native Jido skill guidance |
| `ClaudeCode` / `"claude_code"` | `:claude_code` | Separate official-agent delegation, not a native subscription model |
| `Goal` / `"goal"` | `:planning` | Inspect/set/plan/complete with real check effect IDs |
| `Memory` / `"memory"` | `:memory` | Retain task-critical data |
| `Question` / `"question"` | `:ask` | Structured clarification through host questions |
| `Experiment` / `"experiment"` | `:experiments` | Explicit bounded registered-tool trials, timings and retained results |
| `Subagent` / `"subagent"` | `:delegate` | Start/wait/steer/cancel narrowed child tasks |

Task/goal/memory/question/experiment APIs are also available on the [public facade](PUBLIC_API.md). A role name, loaded skill or tool result does not grant an Action in this table.

## Exact reads and stale-safe edits

```elixir
{:ok, file} =
  OhMyJido.execute_tool(session, "read", %{
    path: "lib/demo.ex",
    start_line: 1,
    end_line: 80
  })
```

Ranges are one-based and inclusive. Returned text retains original LF/CRLF bytes; the lowercase SHA-256 covers **the entire original file**, not the slice. A binary read returns bounded base64 and `content: nil`; line selection on binary data is rejected. Reads report bytes, bytes returned, encoding/newlines, line bounds and truncation. Truncated content is not complete-file evidence.

Writes require `snapshot` and existing parent directories: a read's digest for replacement, or `"missing"` for create-only behavior. Files are UTF-8 text; no line-ending normalization or unguarded overwrite option is supplied. An edit contains a list such as `%{old: exact_nonempty_bytes, new: replacement_bytes}`. If a target repeats, supply an explicit one-based `occurrence`; all targets are resolved against the same original snapshot, then checked for overlap. A stale digest, ambiguous match or missing target is an explicit conflict, not a reason to widen/guess an edit.

Whole-file/file-slice limits are in [configuration](RUNTIME_CONFIGURATION.md#contextpolicy-and-common-tool-ceilings). In-process writers serialize; external writers are rechecked but not OS-locked. See [the threat model](PERMISSIONS_AND_RECOVERY.md).

## Discovery, search, Shell and Git

List/Search require installed `rg` (ripgrep) for discovery, and use installed GlobEx to filter relative glob results without overriding native ignore behavior. Defaults are `path: "."`, `glob: "**/*"`, `hidden: false`, `ignore: true`; Search defaults to `mode: "literal"`, `case_sensitive: true`. Regex mode is explicit. Git internals and symlink escapes are excluded. Discovery does not follow symlinks, load global/parent ignore configuration, or accept a model-supplied executable/shell command. Search locations are one-based **byte** columns, not LSP UTF-16 or AST grapheme positions. Inspect `skipped`, `truncated` and detailed truncation flags.

Shell takes `executable`, explicit `args` (default `[]`), `cwd` (default `"."`), child `env` (default `%{}`, `nil` unsets a variable), optional `timeout_ms` and `max_output_bytes`. No implicit shell parses a command string. For a shell expression, explicitly select `sh` with `args: ["-c", expression]` and obtain host approval. Linux `setsid`, `sh`, `mkfifo`, `cat`, `kill` and procfs are required. Results carry separate raw stdout/stderr, byte counts/truncation, duration, exit status, status, cleanup and effect outcome. A nonzero exit is evidence to interpret, not a successful check.

A test command has the actual shape:

```elixir
{:ok, process} =
  OhMyJido.execute_tool(session, "shell", %{
    executable: System.find_executable("mix"),
    args: ["test"],
    cwd: ".",
    env: %{"MIX_ENV" => "test"},
    timeout_ms: 30_000
  })
```

This is an operator-invoked example, not a command executed by this documentation task. It requires a real Mix executable, permitted project execution and a host able to respond to any approval. Executing a repository's tests/config/build code is execution of that repository, not a read-only inspection or sandbox.

Git operations are `status`, `diff`, `log`, `patch_context`, `commit`, `worktree_add`, `worktree_remove`. Common selectors are `repo: "."`, explicit `paths`, optional base/revision, staged `cached`, diff context and log limit. The adapter uses fixed argument vectors; no remote/push/force/reset/history-rewrite API exists. Inspection needs `:git`, not arbitrary `:exec`; commit/worktree mutation also needs `:edit`. Commit stages/commits only explicit paths, preserves unrelated staged work and requests sensitive approval for both phases. Hooks, external diff/text conversion, fsmonitor/signing and ambient Git override variables are disabled in children, not globally.

`Git.isolate/3` requires a clean source and returns a real detached worktree pinned to a commit. Trusted `metadata.git_worktree_roots` must be existing directories (default workspace). Creation targets must be absent. Removal refuses dirty/unknown/source worktrees, with no force flag. A changed worktree is retained for host review/merge/archive; do not delete it merely because the child ended.

## Subagents, review and advisor roles

Read-only children share the parent's workspace with the intersection of read-class grants. They cannot add a grant; `:delegate` is removed. Explicit requested grants outside the parent's set fail. Writable children require parent `:edit` plus a different host-granted workspace in `metadata.delegation_roots`, or a real clean Git-isolated worktree. `:exec`/`:custom` work also requires an isolated child root because it can mutate.

```elixir
{:ok, child} =
  OhMyJido.delegate(session, "Trace the counter API and report concrete callers",
    tag: "counter-readers",
    role: :exploration,
    permissions: [:read],
    writable: false
  )

result = OhMyJido.await_child(session, child.tag, timeout: 60_000)
```

Several such submissions may run concurrently within session/model/subagent limits; each is a native Jido child adopted by the parent. The parent can inspect `children`, receive `:subagent_started`/`:subagent_completed`, steer a child and cancel it. The Action's actual operation enum is **start/wait/steer/cancel**; there is no invented `"monitor"` request. Host inspection/events supply monitoring. Read-only review/advisor tasks use the corresponding native model role without transferring primary control.

Native adoption rejects a duplicate active tag without replacing its existing owner. Cancellation reaches registered process/Eval resources; a dead owned process can still leave an uncertain effect receipt. Arbitrary synchronous host Actions/callbacks use native cooperative cancellation and must honor their deadlines and cleanup contracts. `:cancellation_requested` is not transaction rollback or proof that every host callback has already stopped.

Children inherit the parent's opaque account/host/adapters and available Actions, with narrowed grants. Protocol adapters remain bound to their own session identity: do not blindly share a parent's LSP/DAP/MCP PID with a child. The host must provide safe per-identity service dispatch or accept an explicit unavailable/identity-mismatch result. Child/task results are structured terminal records, not an automatic merge. Completed child sessions/worktrees may consume retained session/storage capacity until the host stops/archives them.

## Register a real custom Jido Action

This complete host-authored Action reuses the existing file/authorization boundary:

```elixir
defmodule MyApp.FileIdentity do
  use Jido.Action,
    name: "file_identity",
    description: "Return the complete confined file's byte count and snapshot",
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
```

Registration/unregistration require an idle session and use native Jido.AI APIs. The Action's `capability/0` must be enforced in its implementation (`Files.read/3` does so here); a declaration alone is not an effect check. Actions without that function require `:custom`. Never accept a model-selected module, function, MFA, executor or privileged adapter option. If an Action delegates to an external host service, preserve deadline/cleanup/uncertainty in its real result.

## Native skills and project instructions

Skill discovery/loading reuses Jido.AI Discovery, Spec, ResourcePolicy, LoadSkill and session-scoped Activation. It scans only explicitly approved roots/configured skills, not ambient home directories or the global skill registry. Roots normally resolve inside the workspace:

```elixir
metadata: %{
  skill_roots: [%{path: ".agents/skills", approved: true}]
}
```

A host-owned outside-workspace root additionally needs an absolute path and `scope: :host`; that is a trusted host choice. Discovery defaults to depth 6 and 2,000 directories; loaded guidance defaults to a 262,144-byte bound. `"discover"` returns names/descriptions; `"load"` strictly activates a named approved skill and returns `authority: :guidance_only`. Native `allowed-tools` metadata remains advisory and loading does not execute scripts or grant tools. Malformed native frontmatter/activation remains a structured error, not permissive normalization.

An approved inline runtime skill has the source-backed shape:

```elixir
spec = %Jido.AI.Skill.Spec{
  name: "host-review",
  description: "Host review guidance",
  source: nil,
  body_ref: {:inline, "Preserve approvals and distinguish evidence from proposals."},
  allowed_tools: ["read"]
}

metadata = %{skills: [%{skill: spec, approved: true}]}
```

Host-authored skill modules can also be wrapped with `approved: true` and resolved through native Jido.AI. Activation is scoped by runtime, workspace and session, and cleared at teardown. Successful `skill` call/result guidance is retained as a complete lower-authority exchange across compaction; native module-specific tags are not assumed for the host wrapper.

Prompt precedence is trusted host instructions → approved project instructions → approved skill guidance. Task metadata and repository/tool/page content are quoted data. Runtime `project_instructions` can be an approved envelope `%{approved: true, instructions: text}` or be approved by trusted `project_approved: true`; the composer never evaluates repository Elixir configuration. Model/project text cannot approve itself.

## Host adapters and resource ownership

Bind optional services with `adapters: %{capability => {module, trusted_options}}`. `Host.Local.invoke/4` dispatches only this map. Models supply the Action request, not the module/options. Missing services return `{:error, {:capability_unavailable, capability}}`.

A callback-based adapter must enforce actual service/session ownership, authority, deadlines and cleanup. Optional `close_session(context, options)` hooks are called for configured AST/LSP/debug/MCP/browser/research/artifact/review bindings on teardown. A hook is not a replacement for cancellation of in-flight resources; callback adapters still own resources created before an interrupted/invalid response.

### Native stdio LSP, DAP and MCP

The supplied reference adapters are `Intelligence.LSP`, `Intelligence.DAP` and `Extensions.MCP`. They use the session-bound `Intelligence.Stdio` owner and installed JSON codec. Executable/arguments are trusted host startup options; no remote transport or model-selected executable is opened. Linux process identity/group cleanup and a watchdog keep ordinary owner loss separate from the host application.

A host can prepare a stable ID/context before opening a session. For example, with a host-supervised `DynamicSupervisor` named `MyApp.Intelligence` and caller-supplied approved `workspace`, `executable` and `args`:

```elixir
{:ok, root} = OhMyJido.Workspace.new(workspace)
id = Jido.Util.generate_id()
grants = [:read, :lsp]
context = %OhMyJido.Context{
  runtime: MyApp.Coding,
  session_id: id,
  workspace: root,
  permissions: MapSet.new(grants)
}

{:ok, server} =
  DynamicSupervisor.start_child(MyApp.Intelligence,
    {OhMyJido.Intelligence.LSP, context: context, executable: executable, args: args}
  )

{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    id: id,
    workspace: root,
    permissions: grants,
    tools: [OhMyJido.Tools.Read, OhMyJido.Tools.LSP],
    adapters: %{lsp: {OhMyJido.Intelligence.LSP, server: server}}
  )
```

This is host setup code; the Context is the host's grant, not a model-created value. Place the DynamicSupervisor under ordinary host supervision. If subsequent session setup fails, the host must close the prepared server/child with the same context; do not leave it orphaned. Use a live host owner (the adapter accepts trusted `owner`) and rebuild per-identity bindings on restore. There is no public `get_context`/`set_adapter` facade to invent; a custom host can resolve its own per-session service registry in `invoke/4` instead of retaining a PID in session options.

Stdio defaults are a 1 MiB frame, 10-second normal request and 300-second pending asynchronous request; 8 pending requests and 64 retained events. Malformed/oversized frames, unavailable executables, identity mismatch or server exit return actual errors. One server cannot be rebound to a different session/workspace. Events/diagnostics that have not arrived are unavailable, not invented empty success. See `Intelligence.Stdio` for trusted lower-level calls, not for a model-facing unrestricted RPC surface.

### Structural code work

Elixir AST uses installed ExAST captures and Sourceror-compatible source ranges. Requests are `operation: "search" | "replace"`, explicit path, structural pattern, optional language, bounded max results. Replace additionally requires replacement source, whole-file snapshot and `expected_count`, with optional exact returned ranges. Ranges are `%{start: %{line: one_based, column: one_based}, end: ...}` with **grapheme** columns and exclusive end. Only selected fragments are spliced; publication goes through `Files.write/5`, not ExAST filesystem mutation or unrelated whole-file formatting.

Other languages require a real approved `:ast` adapter. Its search response supplies the same path/snapshot, matches and truncation; its `:plan_replace` supplies same identity and range/replacement plans. Adapters **plan only**, not write. The core extracts original fragments locally, checks identity/ranges/count/overlap and applies through the same guarded writer. No configured parser means unavailable, not a textual fallback called AST.

### LSP workflow

Operations are initialize, open, change, close_document, diagnostics, definition, references, symbols, rename, shutdown. Open/change read actual confined text and track increasing document versions. Navigation positions are zero-based **UTF-16**; a server negotiating another encoding is rejected. Definition/references/rename require path/line/character. Diagnostics come from real `publishDiagnostics` notifications. `language_id` is trusted adapter configuration (default `"elixir"`).

Rename defaults to `apply: false`: it returns a preview without granting edits. Application additionally needs `:edit`, sensitive approval, the target `snapshot` and snapshots for **every** other edited relative path. Versioned `documentChanges` retain their server versions; all non-null versions must match the bound open documents before **any** write. Null versions are unversioned, not fabricated current versions. Workspace create/delete/rename commands, duplicate documents, surrogate splits and overlapping/out-of-range text edits are rejected. Equal-position insertions preserve server order, including insertions preceding a same-position replacement. Multi-file application is not transactional: a conflict explicitly reports already-applied paths; a post-write server-sync failure reports completed writes. Do not replay an entire rename as though nothing changed.

For a cold ElixirLS start, trusted `timeout_ms` controls initialize's wait, bounded again by `context.limits.protocol_timeout_ms`; both default to10,000ms. Increase both explicitly for a reviewed cold server. This does not enable dependency installation in the library; a supplied server launcher may have its own provisioning behavior.

Server capabilities still matter: installed ElixirLS0.31.1 rejected `textDocument/rename`, and installed Expert0.1.11 advertised no `renameProvider` and did not answer the rename request before its deadline. These are not successful Elixir semantic-renames. Actual Elixir diagnostics/symbol/definition/reference navigation and structural/guarded editing are recorded separately; the client does not disguise a text replacement as an LSP refactor.

Trusted adapter configuration can select the alternate Elixir planner through the **same** `lsp` rename operation:

```elixir
adapters: %{
  lsp: {OhMyJido.Intelligence.LSP, server: server, rename_backend: :elixir}
}
```

The default remains `rename_backend: :server`; a failed or unsupported server rename never triggers an automatic fallback. Models cannot choose a backend, executor or MFA. The alternate planner combines confined authored AST tokens with native definition/reference identity, rather than publishing textual matches or treating Reach's dependence graph as symbol authority. Preview publishes no source changes; both backends share snapshot/version checks, sensitive edit approval, guarded writes and document synchronization.

Planning has hard ceilings of128 nonignored `.ex`/`.exs` files,8MiB total source,1MiB per file and2,000 native requests; trusted `rename_max_files`, `rename_max_bytes`, `rename_max_file_bytes` and `rename_max_candidates` options can lower them. Incomplete inventories, generated/ambiguous identity, unsupported macro scopes or unprovable collisions fail explicitly rather than yielding a partial edit. Metadata states the bounded inventory, native evidence and backend. Native server identity metadata is compatibility evidence, not authentication. Actual alternate-backend native and full integration gates pass; [PROGRESS](PROGRESS.md) and the [safe native report](evidence/elixir-rename-20261018.json) retain exact scope and proof.

Caller-environment, namespace and SDK callee-kind proofs currently support the audited ElixirLS0.31.1 profile. They use fixed internal native `llmEnvironment`/`llmTypeInfo` requests and declaration metadata, not model-selected commands. Functions include overlapping default-arity/multiclause families, imports, captures and pipes; variables preserve native binding versions; modules support same-namespace leaf renames and proved implicit aliases. Namespace moves, qualified nested declaration aliases, grouped/dynamic aliases, opaque macro/compiler scopes and unprovable runtime symbol dependencies are explicit unsupported boundaries, not partial “successful” refactors.

Only structurally identified direct-module `@spec` function heads can be signature occurrences: native definition identity remains required, while runtime caller-variable/import/capture evidence is reserved for actual runtime calls. Spec argument/return types, constraints and callback heads receive no blanket exemption. Compiler-owned `module_info/0,/1` destinations, including overlapping default-generated arities, are rejected; the distinct legal `/2` name is not rejected merely by spelling.

The audited server can navigate a spec head to its entire `@spec` statement. That native range is anchored only to the structurally identified signature at the exact statement opener, never its type calls. A self-resolving signature additionally requires its same-module/name/arity authored implementation to be independently resolved through native definition evidence; circular or unavailable implementation evidence and unaudited profiles fail explicitly. This does not infer function identity from an unproved source spelling.

For that audited profile, a missing definition at an authored module declaration may be corroborated by the native `workspace/symbol` index. This requires the exact canonical module, module kind, same authored URI and an enclosing declaration range, followed by the ordinary AST identity and reference checks. Empty, malformed, conflicting or foreign index results never create identity; index results are bounded to1,000 and request counts remain in rename metadata.

Applied results retain the complete changed-path/snapshot receipt and effect certainty if optional planning metadata exceeds the result ceiling. A ceiling too small for that complete compact receipt is rejected before publication. Partial write and post-write synchronization failures retain their real affected subset and disable automatic retry; a size error must not erase already completed writes.

The alternate planner synchronizes actual inventory text into its owned native LSP buffers before resolving symbols; it does not create hypothetical renamed documents. Stdio's `document_sources/1` fingerprints successfully sent full text independently of reserved version counters, and incremental/unknown text remains explicitly unverified. Matching sources preserve versions; stale sources use ordinary open/change and are checked again before the plan returns. This prevents a same-length disk edit from borrowing semantic locations from an old buffer. Source publication still requires the normal guarded edit path. A trusted language server can compile/load project dependencies in its own VM; “read-only preview” does not make that external service an execution sandbox.

### Debugger workflow

The DAP Action supports initialize; launch/await_launch; wait_initialized; breakpoints; configuration_done; threads/wait_stopped; stack_trace/scopes/variables; step_over/step_in/step_out/continue/pause; terminate. Program/cwd/source paths are confined; launch defaults and `adapter_id` belong to trusted adapter options. Reverse process launches and start-debugging requests are not advertised.

Launch is **asynchronous** and returns `status: :pending, request_id: id`. Real adapters can defer its response until configuration is done. Configure/wait for initialized, set breakpoints and configuration_done, then use await_launch to observe actual startup. A finite await that expires removes its waiter, not the pending launch; a later await observes the retained outcome without launching again. The generated request-ID receipt is budgeted before dispatch and preserved after dispatch even when the rest of the result is truncated. DAP lines/columns are one-based; frames/variable references come from real responses. Terminate reports adapter group cleanup and separately whether debuggee termination was acknowledged; it does not prove an escaped debuggee vanished.

Launch/configuration ordering is adapter-specific. The real installed GDB DAP starts the inferior immediately on launch. Its verified workflow preloads the approved executable with trusted `args: ["--interpreter=dap", "--quiet", absolute_program]`, then invokes initialize → wait_initialized → breakpoints → configuration_done → launch → await_launch → wait_stopped. Actual stack/scopes/variables returned `counter = 1`; step_over and the next stopped event returned `counter = 3`, followed by acknowledged terminate/disconnect and confirmed owned-group cleanup. The convenience `DAP.smoke/3` implements deferred-launch adapters; use the explicit public operations for GDB rather than treating an early stop as the requested breakpoint.

The actual installed ElixirLS0.31.1 debug adapter also passed the deferred-launch smoke in a disposable Mix project: real breakpoint, counter1→3, stack/scopes/variables and owned-group cleanup. Its launcher selected a different mise Elixir until the child explicitly selected the reviewed1.20.2/OTP28 toolchain. Valid DAP events with `body: null` now retain their raw message and can satisfy selector-free event waits; missing fields never become invented matches. The Action has no attach or evaluate operation and is not a live-node RPC/IEx tool.

### Headless live Observer

`Tools.Observer` is a structured OTP inspection Action, not `:observer.start/0`, wxWidgets, IEx or arbitrary RPC. Grant `:observe` and explicitly bind a trusted target:

```elixir
adapters: %{
  observer: {
    OhMyJido.Intelligence.Observer,
    [target: :local, supervisors: %{"app" => MyApp.Supervisor}]
  }
}
```

Operations are `overview`, `applications`, `processes`, `process` (a returned PID string), `supervision` (an approved root label), `ets` and `table` (a returned table ID). Inventories have `limit`1–200, `offset`0–100,000; supervision has depth1–5 and one total node budget. Results identify the actual target, counts/truncation and `atomic: false`: processes and tables can disappear between observations. ETS memory is in words, with VM word size available in overview; system memory is bytes.
Process inventory uses OTP28+'s native process iterator and stops after the requested page plus lookahead, rather than materializing the full process table. Earlier targets report `:observer_process_iterator_unavailable` for that operation. `observed_total` is the target VM's non-atomic process-count sample, not a count obtained by enumerating every process.


System counters/memory, started app names/versions, process status/heap/reductions/mailbox length, approved supervision children and ETS metadata are collected through fixed native APIs. Process state, messages, dictionaries, application environment and table contents are not read. Unknown supervisor labels fail; partial/depth-limited/unavailable traversal is explicit. Snapshots do not reset cumulative statistics or enable scheduler tracing.
Native collection timeouts return `:observer_timeout`; unsupported/unavailable native observations return `:observer_observation_unavailable` on both local and remote targets. A missing/disconnected remote target remains a distinct transport failure. Partial supervision traversal keeps its explicit per-root error/truncation instead of inventing an empty tree.


To observe another already configured distributed node, replace `:local` with its trusted node atom; install the library module on that target and use target-local registered supervisor names. Native `:erpc` invokes only the fixed collector. The model cannot choose a node, cookie, module/function, arbitrary introspection field or executor. The adapter never starts distribution, sets authentication or injects code. This is authorized VM metadata access, not an OS sandbox or arbitrary secret detector.

Actual post-review local registered Action and separate-node OTP application smokes passed, including private-data exclusion, bounded inventory, target-state preservation, permission denial and owned cleanup. A5,000-process fixture returned1 entry; native controller timeout returned a tagged failure without exiting the caller. See [reviewed safe evidence](evidence/observer-reviewed-20261018.json); full integrated verification remains separately tracked in PROGRESS.


### Scoped MCP

Core MCP is a reference **stdio** adapter, not a universal transport/tool framework. Supported versions are `2025-06-18` (default), `2025-03-26`, `2024-11-05`. Initialize uses empty advertised client capabilities. Sampling, elicitation, reverse tool execution and implicit roots are not advertised.

Trusted adapter options include `server`, exact `tools` and `resources` allowlists, optional protocol version. List responses are filtered; announcements do not grant access. Operations are initialize, list_tools, call_tool, list_resources, read_resource, close, with bounded cursor/arguments/results. Calls are sensitive effects. A lost tool response reports uncertainty; an oversized completed response can report `effect: :completed, result: :unavailable`. Neither is grounds to retry. Returned content remains `trusted: false`; it is not automatically registered as host Jido Actions.

MCP timeouts use its native `notifications/cancelled` request-ID notification, not LSP's `$/cancelRequest`. Initialization is never cancelled through that mechanism. Losing a response still leaves effect completion uncertain.

### Tidewave-style live application tools

Live runtime access is separate from isolated Eval and DAP. The optional `Extensions.Tidewave` binding reuses the released native [Tidewave0.9.1 stdio proxy](https://github.com/tidewave-ai/tidewave_phoenix/blob/7134830165baa9c760797dfcb535bf3a9a098270/lib/mix/tasks/tidewave.proxy.ex) and the existing `mcp` Action. It does not add a transport, evaluator, GUI or core Tidewave dependency.

Install Tidewave in the approved development application using its documented native installer/manual integration. Start only its reviewed `mix tidewave.proxy --no-browser-tools` command through the existing session-bound MCP/Stdio owner. Bind that owner and one trusted loopback application port:

```elixir
adapters: %{
  mcp: {
    OhMyJido.Extensions.Tidewave,
    [
      server: proxy,
      port: 4000,
      tools: ["get_docs", "get_source_location", "get_logs", "project_eval"]
    ]
  }
}
```

`get_docs`, `get_source_location` and `get_logs` query actual application dependencies, source locations and logs. Prefer structured queries and Observer over arbitrary code execution, but do not confuse structure with safety: native Tidewave0.9.1 source lookups parse references into permanent atoms and can load modules/run`@on_load`. Only logs are exempt from the extra runtime authority. The allowlist is mandatory; native announcements and `readOnlyHint` values do not grant authority. Initialization and `list_tools` are scoped to effective grants; runtime-authorized methods are presented with`readOnlyHint: false`. The proxy's `port` property/requirement is removed and injected from trusted configuration. Model-supplied port/target/node/cookie selectors are rejected.

All calls retain `:mcp` and sensitive host authorization. Native source/docs lookups, `project_eval` and every other tool except `get_logs` additionally require `:live_eval` and sensitive authorization naming the exact target/tool, argument SHA-256 and code SHA-256 when supplied. Approval effects contain bounded intent/digests, not raw code/arguments; the host must match them to privately reviewed request data. These methods are hidden without the extra grant. `project_eval` can explicitly invoke `:rpc`/`:erpc` as the last-resort escape hatch. Neither runtime authority nor a pinned port makes approved code a sandbox.

The host must bind a separately configured live application VM, not the library host's own evaluator. No endpoint, package install, distribution, cookie change or fallback is started implicitly. Timeouts/cancellation/transport loss do not prove rollback or that target code stopped: preserve uncertain outcomes and reconcile instead of retrying. Closing the owned proxy does not kill the target app. `close_session/2` still releases the correct owner after grants are revoked.

Actual post-review Tidewave0.9.1/Bandit1.13.1 proof passed explicitly approved docs/source, log challenge, target/grant/approval denials, exact approved live-state access and native RPC/ERPC in a distinct external VM, then owned proxy/target cleanup. The native authority regression now denies24 unique source references with0 atom growth/no module loading. [Reviewed safe evidence](evidence/tidewave-runtime-reviewed-20261018.json) separates this from distributed-node Observer and isolated Eval. The final462-case full quality gate also passes; no arbitrary user-app or sandbox authorization is implied.


## Browser and research contracts

The core supplies **contracts and checked Actions**, not a built-in browser engine, search service or credentialed network client. A host must bind a real implementation.

Browser requests are only navigate (`url`, optional existing `page_id`), snapshot/close (`page_id`), click (`page_id`, selector), fill (`page_id`, selector, value), plus bounded timeout/text budget. No arbitrary JavaScript, cookies, headers or RPC method is accepted. The host enforces approved origins, redirects, popups, downloads, ownership and actual cleanup. Replies include opaque `page_id`, actual HTTP(S) URL, UTF-8 content/title and optional truncation; a close must return the requested ID with `closed: true`. Navigation/click/fill are sensitive. Text is `trust: :untrusted`.

Research requests are search (`query`, limit) or read (credential-free HTTP(S) `url`). Search replies are `%{results: [%{url: url, title: title, snippet: text}]}`; read replies are `%{url: url, title: title, content: text}`. Every call requires sensitive external approval. No headers/cookies/shell/tool-discovery selector is exposed. The host enforces egress/redirect/provider policy and releases real request resources; URL syntax validation alone is not an SSRF boundary.

`Extensions.Browser.smoke/4` and `Research.smoke/5` require explicit `human_initiated: true`, real adapter bindings and normal approvals. Browser smoke verifies expected content and confirmed close; research smoke verifies actual search/read observations. Artifact/Review smoke helpers likewise require this flag. LSP/DAP/MCP helpers accept explicitly supplied real servers/plans and normal host authorization. None run automatically or make fixture evidence a live external-service result.

The historical [Elixos reference example](../../examples/elixos/README.md) binds native Browser/CDP services under a serialized singleton lease; Elixos-side integration is outside this library delivery. Its native API cannot safely page-close, click or fill; unavailable operations are not fabricated successes. Release is not page close. A real Chromium/native CDP smoke exercised checked navigation/snapshot, ownership/grant rejection, screenshot, release and separately observed native-owned page teardown (`artifact://315`), not isolated browser contexts or a guest launcher.

Actual library Research Actions also exercised a narrowly approved native HTTPS Hex catalog search/read: two HTTP200 responses identified QuickBEAM0.11.3, output remained untrusted and within256 bytes, and subsequent grant/policy/allowance denials made no further requests (`artifact://355`). This proves that host binding, not general web-search coverage or rejection of every unknown Action parameter.

## Artifacts and model-visible images

The supplied `Extensions.Artifact.Local` supports bounded UTF-8 text, PNG/GIF header dimensions and binary byte count/SHA-256. It reads a regular confined file, performs no execution/network call, and does not decode pixels, frames, complete image validity, OCR or arbitrary document formats. Other decoders must be real host bindings with their own limits/security policy.

Header-only inspection is default:

```elixir
adapters: %{artifact: {OhMyJido.Extensions.Artifact.Local, []}}
```

If the host explicitly approves sending image bytes to its selected model, enable:

```elixir
adapters: %{artifact: {OhMyJido.Extensions.Artifact.Local, model_inputs: true}}
```

The trusted option, not a model-supplied request flag, allows recognized image bytes to become native `ReqLLM.Message.ContentPart.image/2` inputs in the real tool exchange. The adapter projects at most one valid native image part, bounded by approved input bytes. It is not a separate uploader/vision engine: subsequent native inference sends approved context to the already host-selected account/model. Use an image-capable approved model and obtain the host's disclosure/billing permission. Header dimensions alone are not semantic image evidence; the actual blue/yellow PNG model smoke is recorded separately in [operations](OPERATIONS_AND_EVIDENCE.md).

Artifact operations are `inspect`/`read_text`, kind `auto|image|text|binary`, path and bounds. Defaults are 8 MiB input/8 KiB text; host ceilings and complete-file limits still apply. ContextPolicy's projected-byte budget counts content too; an admitted artifact is not permission to exceed the conversation budget. Returned summaries/content/metadata are untrusted and deliberately projected; arbitrary decoder response fields are omitted. Unsupported image formats fail explicitly.

## Diff review and security hints

Review captures **actual tracked Git changes**, not model-supplied diff text. Default source `"git"` needs `:review` and `:git`; staged/paths select the scope. An approved host `"host"` source must return a real confined `%{source: :workspace_git, diff: bytes, truncated: boolean}`. Untracked file additions are not magically part of a tracked diff.

Rules identify possible secrets, dynamic execution and destructive operations, with concrete changed path/line evidence. Optional `enrich: true` sends only the bounded captured diff/hash to an approved host service under fresh sensitive external approval; suggestions must cite changed locations. Results include risk, limitations, diff identity/truncation, findings/truncation and `security_certainty: :limited`. A hint does not prove exploitability, live credentials, full security or approval of the reviewed effect. Review/advisor child agents provide recommendations under parent control, not an automatic deployment decision.

Review redaction retains every distinct detected secret within the already bounded captured diff, including a truncated final line; it does not evict earlier credentials after100 later matches. Approved enrichment responses are checked against that complete detected set before publication. Detection is still limited to the documented patterns, not a claim to recognize every possible secret.
