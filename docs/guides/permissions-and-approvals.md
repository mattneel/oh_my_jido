# Choose permissions and require approvals

Use permissions to decide what a coding session may do, then use approvals to pause selected actions for a human decision. Your application chooses the policy; the model only proposes work.

## Separate tool availability from permission

A session starts with no permissions. Two independent controls decide whether a tool can run:

| Control | Configure with | What it decides |
|---|---|---|
| Tool availability | `bundles:` or an explicit `tools:` list | Which Jido Actions are registered for the session. An Action is an executable tool module. Use one option, not both. |
| Permissions | `permissions: [:read, :edit, ...]` | Which capabilities the session may exercise. Registering a tool or configuring an adapter grants nothing. |

For example, you can register both reading and editing tools while allowing only reads. With `MyApp.Coding` already supervised and `/path/to/project` containing `mix.exs`:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: [:read_only, :editing],
    permissions: [:read]
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})

# Write is registered, but :edit was not granted. No write occurs.
{:error, _denial} =
  OhMyJido.execute_tool(session, "write", %{
    path: "mix.exs",
    snapshot: file.snapshot,
    content: file.content
  })
```

Adding `:edit` to a new session's permissions would authorize guarded file edits; it would not register an absent editing tool. The `:process` bundle similarly registers Shell and Git, but you still need `:exec` for Shell or `:git` for Git.

For model requests, Oh-My-Jido intersects the registered Actions with the session's permissions and the selected model's advertised tool support. Built-in Actions still authorize at the point where they perform an effect. Calling `OhMyJido.execute_tool/4` directly does not bypass permission checks, host policy or the managed session's effect journal.

## Decide which actions need a human

The default policy is `OhMyJido.Host.Local`. `OhMyJido.Tool.authorize(context, capability, effect)` first checks the permission, then calls `Host.authorize/4`. Local requests approval only when the effect contains `sensitive: true`. Otherwise it allows a granted effect.

These built-in effects request approval under Local:

| Action | Approval boundary |
|---|---|
| Git commit | Staging and committing ask for approval separately. Git mutation also requires `:edit`. |
| Applied LSP rename | Applying the rename requires `:edit` and approval; requesting a rename preview is not the same operation. |
| Debugger launch | Launching the debugged program is sensitive. |
| MCP tool call | `call_tool` is sensitive, including tools advertised as read-only by a server. Discovery does not grant authority. |
| Tidewave live operations | In addition to MCP approval, calls other than `get_logs` need `:live_eval` and approval bound to the target, tool and argument digest, plus a code digest when code is supplied. This includes `get_docs` and `get_source_location`: a lookup can allocate atoms or load a module with `@on_load` code. |
| Browser interaction | Navigation, clicking and filling are sensitive; taking a snapshot is not automatically sensitive. |
| Research request | Every request is a sensitive external effect. |
| External review enrichment | Sending a diff to a configured review service is sensitive; local diff analysis is not automatically sensitive. |
| Official Claude Code subprocesses | Both the authentication-status subprocess and the delegated task are sensitive, separate-agent effects. |

Use live execution/RPC only as a last resort after structured Observer inspection, docs/source and logs. A trusted Tidewave binding pins an external application target and a tool allowlist; `:live_eval` does not authorize arbitrary evaluation in the library's own VM.

Configured MCP, LSP and DAP real-server smoke helpers also mark their execution as sensitive. A custom Action or adapter can declare additional sensitive effects.

**Local does not inspect shell commands for danger.** Ordinary Shell calls, isolated Eval calls, file edits and Git worktree mutations are not automatically sensitive. A shell can commit, publish or access the network without going through the corresponding specialized tool. Granting `:exec` under Local therefore gives substantial OS authority. Use a stricter host policy and the [OS controls in the security guide](security.md) when the task needs them.

## Accept only an explicit approval

Clarification questions and effect approvals both produce an `:approval_requested` event. The question callback can answer immediately with `{:ok, answer}`, leave it open with `:pending`, or reject it with `{:error, reason}`. Local leaves questions pending. Your application then passes the authorized human's decision to `OhMyJido.answer(session, question_id, answer)`.

For an effect approval, the answer values are exact:

| Answer | Result |
|---|---|
| `true`, `:approve`, `"approve"` | Approves that waiting effect. |
| Any other supplied value | Returns `{:error, :approval_denied}` to the waiting operation. |
| No answer, dismissal or timeout | Does not approve the effect. A timeout returns `{:error, :approval_timeout}`. |
| The waiting operation ends first, for example at its time limit | The question is withdrawn: `:approval_answered` reports `{:error, :withdrawn}`, and the effect does not run. |
| Response to an answered, expired, withdrawn or otherwise closed ID | `OhMyJido.answer/3` returns `{:error, :unknown_question}`. |

A default choice is not consent. Clarification answers, including options and `multi` selections, are task data, not new permissions. Effect approval itself does not require the Question tool's `:ask` permission.

| Question setting or failure | Contract |
|---|---|
| `max_pending_questions` | Default: 8 pending questions per session. At capacity, the operation fails with `{:error, :question_capacity}`. |
| `question_timeout_ms` | Default: 300,000 ms. The waiting operation fails when its question expires. The wait does not use the tool's `tool_timeout_ms`: a tool call may run for `tool_timeout_ms` plus `question_timeout_ms`, and the run deadline still applies. That allowance covers one wait; a call that asks more than once, such as a Git commit (staging and committing are approved separately), shares it. |
| Host question callback failure | The waiting operation fails; a raised or thrown callback failure becomes `{:error, :approval_host_failed}`. |
| Run termination or cancellation | Rejects its pending questions; a late answer cannot restart the effect. |
| Context without a managed session coordinator | A required approval returns `{:error, :approval_required}` instead of running the effect. |

Do not implement an “approve every event” consumer. Check who may answer for this session, display only the effect details they are allowed to see, and obtain a real decision. Never put credentials in question text, command arguments or UI logs. A custom policy can use a stricter answer contract than the three core approval spellings.

Keep the event handler responsive while an effect waits in its supervised worker. See [running tasks](running-tasks.md) for event handling and the UI approval flow, and [configuration](../reference/configuration.md) for setting question limits.

## Write a stricter host policy

Implement `OhMyJido.Host` when your application needs additional checks. This complete module asks before every Shell, Eval or custom-tool effect, keeps the default approval for sensitive effects, and delegates credentials, services and questions to `OhMyJido.Host.Local`:

```elixir
defmodule MyApp.CodingHost do
  @behaviour OhMyJido.Host

  alias OhMyJido.Host.Local

  @impl true
  def authorize(context, capability, effect, _options) do
    cond do
      not OhMyJido.Context.permitted?(context, capability) ->
        {:error, {:permission_denied, capability}}

      effect[:sensitive] == true or capability in [:exec, :eval, :custom] ->
        {:approval,
         %{
           kind: :effect,
           capability: capability,
           effect: Map.drop(effect, [:content, :source, :env])
         }}

      true ->
        :ok
    end
  end

  @impl true
  def credentials(context, account, options), do: Local.credentials(context, account, options)

  @impl true
  def invoke(context, capability, request, options),
    do: Local.invoke(context, capability, request, options)

  @impl true
  def question(context, question, options), do: Local.question(context, question, options)
end
```

Select the policy in your runtime configuration, and pass the credentials resolver in the policy's options:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   host: {MyApp.CodingHost, credentials: {MyApp.ModelCredentials, []}}}
]
```

Do not also set the runtime's `credentials:` option. That shortcut only configures `Host.Local` and raises `ArgumentError` together with a custom `host:`. `Host.Local`'s credentials callback reads `credentials:` from the options shown above. For the OpenAI account broker, use `credentials: {OhMyJido.Auth, broker: MyApp.AccountBroker}` in the same place; see [models and accounts](models-and-accounts.md).

This module supplies policy and dispatch, not a browser, vault or OS isolation. `Map.drop/2` removes common bulky fields from its approval description; it is not a general secret filter. Project only the fields your approver needs, and apply your own command, path and network restrictions.

### Host callback reference

Each callback receives a trusted `%OhMyJido.Context{}` first and the configured keyword options last.

| Callback | Valid return values |
|---|---|
| `authorize(context, capability, effect, options)` | `:ok`, `{:error, reason}`, or `{:approval, question_map}`. |
| `credentials(context, account, options)` | `{:ok, inference_options}` where `inference_options` is a keyword list, or `{:error, reason}`. Credentials are requested at the model boundary, not from repository configuration. |
| `invoke(context, capability, request, options)` | `{:ok, result}` or `{:error, reason}`. Local dispatches only to the adapter bound to that capability in `context.adapters`. |
| `question(context, question, options)` | `{:ok, answer}`, `:pending`, or `{:error, reason}`. |

At the authorization layer, a missing permission returns `{:error, {:permission_denied, capability}}`. Host denials containing an atom or a two-atom tuple are preserved; other denial details become `{:error, {:host_denied, capability}}`. Invalid authorization returns and raised or thrown failures become `{:error, :authorization_service_failed}`. When an Action runs through Jido V3, `Jido.Action.Error.ExecutionFailureError` can wrap these policy errors in `error.details.reason`.

Callbacks run in supervised tasks and must honor their deadlines. Adapters must retain session ownership, constrain origins, redirects and resources, and clean up the resources they actually created. Where the core can observe cleanup, claiming a successful close without doing it is rejected. A result label cannot provide page isolation, confinement or rollback that the underlying service lacks.

Host modules, Action implementations, adapter bindings and callback options are trusted configuration. Keep service executables, targets and credential selection there. Never turn model input into a module, arbitrary MFA/RPC target or policy change. A custom Action that declares `capability/0` must call `OhMyJido.Tool.authorize/3` at its own effect boundary; the library does not make arbitrary Action code safe by registering it.

## Permission reference

`permissions:` accepts capability atoms. `OhMyJido.Context.new/1` accepts a list or `MapSet` of non-nil, non-boolean atoms, including your application's fixed capabilities. Permissions do not configure optional services or inject tools into an Eval runtime.

| Permission | Authorizes | Additional boundary |
|---|---|---|
| `:read` | Read, List and Search. | Also needed by source-reading paths used by AST and language intelligence. |
| `:edit` | Snapshot-guarded file mutation. | Independently required for Git mutation, structural replacement and applying renames. |
| `:exec` | Subprocess execution through Shell. | Not needed for fixed Git inspection commands. The application must constrain executable and OS authority. |
| `:git` | Fixed Git inspection and worktree/commit workflows. | Mutation also needs `:edit`; no remote, push, force or history-rewriting API is supplied. |
| `:ast` | Structural source inspection and transformations. | Reading also needs `:read`; writing needs `:edit`. |
| `:lsp` | Operations on a configured language service. | Applying a rename also needs `:edit` and approval; source-reading paths may need `:read`. |
| `:debug` | Operations on a configured debugger. | Launch requests require approval. |
| `:observe` | Bounded, headless metadata from an explicitly configured live OTP target. | Excludes process state, messages, dictionaries, application environment and ETS contents. It does not grant live execution. |
| `:delegate` | Bounded child-task creation and control. | Child permissions cannot exceed the parent's; mutating children need an isolated or explicitly allowed workspace. |
| `:planning` | Goal/task planning operations. | Does not authorize executing the plan's steps. |
| `:memory` | Explicitly retaining task facts. | Retained facts are private session data, not a credential store. |
| `:experiments` | Bounded tool trials. | Each trial still needs its tool's permission and authorization. |
| `:ask` | Structured clarification questions. | Answers do not grant permissions. |
| `:skills` | Reading configured skill guidance. | Skill text has no authority to change policy. |
| `:mcp` | A configured MCP service. | Tool calls require approval; server announcements cannot grant access. |
| `:browser` | A configured browser service. | Navigation, clicking and filling require approval. |
| `:research` | A configured research service. | Every request requires approval and the service's network policy. |
| `:artifact` | Bounded artifact/image inspection. | Decoders and any required external resources remain trusted application services. |
| `:review` | Diff review and optional configured enrichment. | External enrichment requires approval; underlying Git/file operations retain their own permissions. |
| `:eval` | Persistent execution in a configured isolated language backend. | Injected tools still require their own permissions. This is independent of `:live_eval`. |
| `:live_eval` | Additional loading/execution authority on a trusted live MCP target. | Tidewave requires it even for its docs/source lookup, with sensitive digest-bound approval. It is not isolated Eval or a sandbox. |
| `:claude_code` | Separate delegation to the official Claude Code binary. | Enabled Read/Glob/Grep tools also need `:read`, Edit/Write need `:edit`, and Bash needs `:exec`; subprocesses require approval. |
| `:custom` | A registered application Action without `capability/0`. | Does not authorize an arbitrary MFA or RPC supplied by the model. |

Your Actions can use additional fixed capabilities, such as an application's `:candidate` or `:deploy`. Those are application policies, not core OS permissions. See [tools](tools.md) for implementing custom Actions and [subagents](subagents.md) for child-task permission rules.

## Limits

- Repository instructions, skills, tool output, web pages, MCP announcements and model answers can never grant permissions, choose credentials, change billing or approve deployment. Your trusted application owns those decisions.
- Permission checks and approvals are library policy, not an OS sandbox. Use [security isolation](security.md) before running untrusted code.
- An approval applies to a waiting effect; it neither expands the session's permissions nor makes an uncertain earlier effect safe to retry. Use [session recovery](sessions-and-recovery.md) to reconcile uncertain outcomes.
- Optional services fail explicitly when unconfigured. Registering a tool, granting its permission and binding its adapter are separate decisions.

## Related

- [Concepts](../concepts.md)
- [Getting started](../getting-started.md)
- [Running tasks and answering questions](running-tasks.md)
- [Security](security.md)
- [Models and accounts](models-and-accounts.md)
- [API reference](../reference/api.md)
