# Delegate focused tasks

Use a subagent when a separate task can produce a useful result without taking over the primary session: trace a code path, review a change or work on a fix in an isolated workspace. A subagent is a managed coding session adopted into Jido's parent/child hierarchy. Your application controls its permissions, workspace and model role.

## Before you start

The parent needs `:delegate` permission. Children inherit its opaque account reference and use the runtime's model selection for their chosen role. Configure [credentials and model roles](models-and-accounts.md) before starting model-backed child tasks. On `master`, configure explicit models for the child roles you use: the bare Jido 2.4 aliases point at a retired model. Setting only the parent's active coding model does not configure an exploration or review child.

The examples below assume a running `MyApp.Coding` runtime with that model configuration. Read-only examples need `:read` as well as `:delegate`. Writable tasks require the additional permissions and workspace setup described below.

## Start a read-only investigation

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:read, :delegate]
  )

{:ok, child} =
  OhMyJido.delegate(session, "Trace the counter API and report concrete callers",
    tag: "counter-readers",
    role: :exploration,
    permissions: [:read],
    writable: false
  )
```

`delegate/3` returns `{:ok, child}` or an error. The handle is a map with these fields:

| Field | Meaning |
|---|---|
| `tag` | String identity used by the parent's child-control APIs |
| `session` | Child `%OhMyJido.SessionRef{}` |
| `run` | Child run ID |
| `workspace` | Actual child workspace root |
| `role` | Selected model role |

Read-only children share the parent's workspace. They receive only the allowed intersection of requested permissions and parent permissions. They cannot add permissions or receive `:delegate`.

To collect the terminal result:

```elixir
result = OhMyJido.await_child(session, child.tag, timeout: 60_000)
```

A completed run returns `{:ok, record}`. Other terminal run states return `{:error, record}`. The record includes the answer, status, error, usage, timestamps and tool-effect summaries; it is not an automatic merge or a guarantee that the requested work succeeded. A caller timeout returns `{:error, :timeout}` and leaves the child running. You can wait again or cancel deliberately.

Several submissions can run concurrently, subject to runtime capacity. You do not need a separate scheduler.

## Steer, cancel and inspect a running child

While a child is still active, use its tag to add a constraint or request cancellation:

```elixir
:ok =
  OhMyJido.steer_child(session, child.tag,
    "Focus on public callers; do not include generated code."
  )
```

To stop that child without cancelling the parent:

```elixir
:ok = OhMyJido.cancel_child(session, child.tag)
```

Steering queues guidance on the child's existing run. Cancellation asks its native run to stop and reaches registered Process/Eval resources. It is not transaction rollback. A `:cancellation_requested` event does not prove that every synchronous application callback has already stopped. Custom Actions and Host callbacks must honor their own deadlines, cooperative cancellation and cleanup contracts. An interrupted or dead process can still leave an uncertain effect journal entry; see [sessions and recovery](sessions-and-recovery.md).

The parent's inspection snapshot contains tracked children:

```elixir
{:ok, snapshot} = OhMyJido.inspect_session(session)
children = snapshot.children
```

Your application can also subscribe to parent `:subagent_started` and `:subagent_completed` events. Started-event payloads identify `tag`, `child_session` and `child_run`; completed-event payloads contain `tag` and the redacted `result`. Inspection is for trusted application code; project a deliberate public view rather than forwarding the whole session snapshot. See [running tasks](running-tasks.md) for subscriptions.

An active tag cannot be adopted by another child: `{:error, {:tag_in_use, tag}}` leaves the existing owner intact. Use distinct tags for distinct work.

## Narrow child permissions

`writable` defaults to `false`. It chooses a permission policy, not merely a prompt instruction.

| Child mode | Default permissions when `permissions:` is omitted | Workspace behavior |
|---|---|---|
| Read-only (`writable: false`) | Parent permissions intersected with the read-class list below | Shares the parent's workspace |
| Writable (`writable: true`) | Parent permissions, minus `:delegate` | If the resulting permissions include `:edit`, `:exec` or `:custom`, needs an approved distinct workspace or a clean Git worktree |

The read-class list is `:read`, `:git`, `:ast`, `:lsp`, `:observe`, `:artifact`, `:review`, `:memory`, `:planning`, `:skills`, `:ask` and `:research`. These permissions still have their ordinary per-operation authorization checks. For example, `:git` alone cannot commit because mutation also needs `:edit`.

Explicit `permissions:` must be a list of atoms and a subset of the parent's permissions. Asking for a permission the parent lacks returns `:permission_escalation`; explicitly requesting a non-read-class permission for a read-only child returns `:read_only_child`. The library always removes `:delegate`, so ordinary children cannot recursively delegate.

Starting with `writable: true` requires the parent to hold `:edit`, even if the requested child list contains only `:exec` or `:custom`. Execution and custom Actions can mutate files, so either permission also triggers the isolated-workspace requirement. Prefer an explicit minimal list rather than accepting every parent permission.

Children inherit the parent's available Actions, Host policy and adapter bindings. Inheriting an Action never grants its permission. Model roles, skill text and child results cannot expand permissions.

## Give a writable child a separate workspace

Use this when your application has already prepared another checkout or copy. The library does not copy files for you. The destination must be an existing directory, resolve to a different root from the parent and appear in trusted `metadata.delegation_roots`.

```elixir
{:ok, parent} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:read, :edit, :delegate],
    metadata: %{
      delegation_roots: ["/path/to/isolated-project"]
    }
  )

{:ok, child} =
  OhMyJido.delegate(parent, "Update the counter API in this isolated checkout",
    tag: "counter-fix",
    role: :coding,
    writable: true,
    permissions: [:read, :edit],
    workspace: "/path/to/isolated-project"
  )
```

Use canonical absolute paths in `delegation_roots`; the resolved destination must match an entry. Your application is responsible for preparing a genuinely separate working copy. A model-supplied path is not a workspace grant. A missing grant or the parent's own workspace returns `{:error, :child_workspace_not_granted}`.

An explicit `workspace:` is used only when the narrowed permissions include `:edit`, `:exec` or `:custom`. A child with only read-class permissions continues to share the parent's root, even if you set `writable: true`.

## Create a Git-isolated child

If a mutating child has no explicit `workspace:`, delegation calls `OhMyJido.Git.isolate/3`. This creates a real detached worktree pinned to a commit, not an in-memory patch or a sibling writing into the parent's checkout.

Prepare an existing directory for worktrees and authorize it in the parent's metadata:

```elixir
{:ok, parent} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:read, :edit, :git, :delegate],
    metadata: %{
      git_worktree_roots: ["/path/to/worktrees"]
    }
  )

{:ok, child} =
  OhMyJido.delegate(parent, "Implement the counter fix in your worktree",
    tag: "counter-worktree-fix",
    role: :coding,
    writable: true,
    permissions: [:read, :edit]
  )
```

The source repository must be clean, and the parent needs both `:git` and `:edit` to create the worktree. Automatic isolation creates an absent `child-…` path beneath the first approved worktree root, using `HEAD`. Roots must already exist; the default root is the parent's workspace. Isolation returns `{:dirty_repository, :uncommitted_changes}` when the source is dirty, inside `{:error, reason}`.

`child.workspace` is the actual isolated root. Child file access stays confined there; its Git context remembers the approved source repository. The child receives only its requested permissions, not an extra `:git` permission because the parent used Git during setup.

Finishing or cancelling the child does not merge or delete its worktree. Review the changes and choose how your application will merge, archive or retain them. Worktree removal is a separate Git operation that refuses dirty, unregistered or source worktrees and has no force option. See [Git tools](tools.md#inspect-and-change-git-state).

## Ask for a review or advice

Review and advisor are model roles, not separate permission levels. They use the runtime's configured role model without transferring control from the primary session. A role by itself does not make a child read-only; keep `writable: false` and narrow its permissions.

```elixir
{:ok, review} =
  OhMyJido.delegate(session, "Review the counter implementation for correctness",
    tag: "counter-review",
    role: :review,
    writable: false,
    permissions: [:read]
  )

{:ok, advisor} =
  OhMyJido.delegate(session, "Compare the counter API options and recommend a design",
    tag: "counter-advice",
    role: :advisor,
    writable: false,
    permissions: [:read]
  )
```

These independent submissions may overlap in time. Collect each result with `await_child/3`.

| Role | Intended task |
|---|---|
| `:exploration` | Read-only investigation with concrete code paths and unknowns; default child role |
| `:planning` | Actionable plan, dependencies and acceptance criteria |
| `:coding` | A scoped implementation; use an isolated writable child when it must edit |
| `:review` | Findings ordered by severity, with locations and remedies |
| `:advisor` | Trade-offs and recommendations grounded in the repository and goal |

A review-role child is different from the `"review"` tool, which inspects tracked changes for bounded risk hints. Give a review child `:git` or `:review` only if the parent has those permissions and the task needs those tools. See [integrations](integrations.md) for the Review Action, and [models and accounts](models-and-accounts.md) for role-model selection. `:compaction` is a runtime model role, not a role exposed by the Subagent Action.

## API and option reference

| Public call | Result / behavior |
|---|---|
| `OhMyJido.delegate(parent, task, options \\ [])` | `{:ok, %{tag: tag, session: child_ref, run: run_id, workspace: root, role: role}}` or error |
| `OhMyJido.await_child(parent, tag, options \\ [])` | Child run result; `timeout` defaults to `30_000` milliseconds; caller timeout does not cancel |
| `OhMyJido.steer_child(parent, tag, text)` | `:ok` when guidance is queued, or error |
| `OhMyJido.cancel_child(parent, tag)` | `:ok` when cancellation is requested, or error; does not cancel the parent |

| `delegate/3` option | Default / contract |
|---|---|
| `tag` | Generated string; explicit tags must be 1–96 bytes |
| `role` | `:exploration`; selected through the runtime's model configuration |
| `writable` | `false` |
| `permissions` | Read-class intersection for read-only children; all parent permissions for writable children, always with `:delegate` removed |
| `workspace` | Shared parent root for read-class-only work; otherwise an approved explicit root, or automatic Git isolation when omitted |
| `llm_opts` | Optional native model-request preferences; forwarded to the child's prompt |
| `req_http_options` | Optional native request HTTP preferences; forwarded to the child's prompt |
| `max_iterations` | Runtime maximum, normally `40`; a request can narrow, not raise, that maximum |

Account, Host policy, adapters and available Actions come from the parent; these are not child-controlled option overrides. Model/account secrets and lifecycle options are not accepted as ordinary model-request preferences. See [models and accounts](models-and-accounts.md) for the native request-option rules.

The model-facing `"subagent"` Action has a deliberately smaller schema:

| Parameter | Contract |
|---|---|
| `operation` | Required: `"start"`, `"wait"`, `"steer"` or `"cancel"` |
| `task` | Required for `"start"` |
| `tag` | Optional for `"start"`; required for the other operations |
| `role` | `"exploration"` by default; enum is `"coding"`, `"planning"`, `"exploration"`, `"review"`, `"advisor"` |
| `writable` | `false`; relevant to `"start"` |
| `text` | Required for `"steer"` |
| `timeout` | `30_000` milliseconds, minimum `1`; used by `"wait"` |

The Action does not expose `permissions` or `workspace` parameters. Its writable start uses automatic Git isolation; your application can use `delegate/3` for explicit permission/workspace choices. Start returns `tag`, `session_id`, `run_id`, `workspace` and `role`. Steer returns `%{status: :queued}`; cancel returns `%{status: :cancellation_requested}`, each inside `{:ok, result}`. There is no `"monitor"` operation: use inspection and events.

| Common error | Meaning |
|---|---|
| `{:permission_denied, :delegate}` | Parent lacks delegation permission |
| `:invalid_child_permissions` | `permissions:` is not a list of atoms |
| `:permission_escalation` | Explicit permissions include something the parent lacks |
| `:read_only_child` | Explicit read-only request includes a non-read-class permission |
| `{:permission_denied, :edit}` | Writable start requires parent edit permission |
| `:child_workspace_not_granted` | Explicit isolated workspace is not granted or is the parent's root |
| `:invalid_child_tag` / `{:tag_in_use, tag}` | Invalid tag or active ownership conflict |
| `:delegation_depth` | Parent has reached the configured depth ceiling |
| `{:capacity, :subagent}` / `{:capacity, :model}` | Runtime has no free child/model-run slot |
| `:unknown_child` / `:child_starting` | Tag is untracked or its run has not started yet |
| `:run_not_active` | Steering/cancellation targeted a run that is no longer active |
| `:missing_subagent_parameters` | Action operation is missing its required parameters |

Facade calls return these reasons inside `{:error, reason}`. Action execution may wrap them in a native `Jido.Action.Error`; see the [API reference](../reference/api.md).

## Limits

| Runtime limit | Default | Scope |
|---|---|---|
| `max_subagents` | `16` | Concurrent delegated tasks across the runtime |
| `max_active` | `8` | Active model-backed runs across the runtime |
| `max_sessions` | `500` | Supervised sessions, including retained child sessions |
| `run_timeout_ms` | `300_000` | Child runs use the runtime's ordinary run deadline |
| `max_iterations` | `40` | Model/tool iterations per run |
| `limits.max_subagent_depth` | `2` | Depth guard; this does not restore the `:delegate` permission removed from children |

- Read-only permission narrowing and workspace boundaries are library policy, not an OS sandbox. Use OS isolation for untrusted code; see [security](security.md).
- Protocol adapters remain bound to their own session identities. Do not blindly reuse a parent's LSP, debugger or MCP PID in a child. Your application must provide safe per-identity dispatch or handle an explicit unavailable/identity-mismatch error.
- Completed child sessions and worktrees can keep consuming session/storage capacity. Your application chooses when to stop or archive them; task completion is not automatic resource deletion.
- Child results do not automatically change the parent's plan, approve an effect or merge code. The primary session or your application must decide what to do with them.

See [configuration](../reference/configuration.md) for all capacity and tool budgets, and [operations](../operations.md) for retention and production sizing.

## Related

- [Core tools and Git](tools.md)
- [Running and controlling tasks](running-tasks.md)
- [Models and accounts](models-and-accounts.md)
- [Permissions and approvals](permissions-and-approvals.md)
- [Sessions and recovery](sessions-and-recovery.md)
- [Configuration reference](../reference/configuration.md)
- [Public API reference](../reference/api.md)
