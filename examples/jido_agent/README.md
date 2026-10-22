# Add coding tools to your own Jido agents

This example adds Oh-My-Jido tools to two agents owned by an ordinary Mix application: a plain `Jido.Agent` named `JidoAgentHost.Files` and a `Jido.AI.Agent` named `JidoAgentHost.Editor`. Jido provides execution and supervision; Jido.AI provides the model-and-tool loop. The editor keeps its application-specific `project_status` tool alongside the coding tools.

Use this pattern when you already have a Jido agent and want repository tools without a second agent or an Oh-My-Jido runtime. For managed approvals, an effect journal and session recovery, use the [plain Mix example](../plain_mix/README.md) instead.

## Run the example

Use Elixir `~> 1.20` and the `master` checkout. From the repository root:

```sh
cd examples/jido_agent
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
```

The tests use Jido.AI's scripted model interface, not a paid provider. They exercise real Read/Edit Actions on disposable files, the domain Action, permission denial and rejection of a forged context. No API key, optional Eval backend or installed Igniter application is needed.

This is an independent consumer with its own `deps/`, `_build/` and `mix.lock`. Its `mix.exs` keeps the supplied Jido/ReqLLM diagnostic snapshots as top-level path overrides and pins Jido.AI and Jido.Action to 2.4.0. Keep these dependency choices together; the preview branch uses different native APIs and overrides.

## Read a file without a model

From the example directory:

```sh
MIX_ENV=test iex -S mix
```

Start the example's binding store and a Jido instance:

```elixir
alias JidoAgentHost.{Contexts, Files}

{:ok, supervisor} =
  Supervisor.start_link(
    [Contexts, {Jido, name: JidoAgentHost.Engine}],
    strategy: :one_for_one
  )

# From examples/jido_agent, this is the Oh-My-Jido checkout.
workspace = Path.expand("../..")

:ok =
  Contexts.bind(Files, "reader",
    workspace: workspace,
    bundles: :read_only,
    permissions: [:read]
  )

agent = Files.new(id: "reader")
{updated, []} = OhMyJido.Plugin.cmd(agent, "read", %{path: "mix.exs"})
IO.puts(updated.state.content)
IO.puts(updated.state.project_label)
```

`Plugin.cmd/3` runs through the original agent's command handling without starting an AgentServer for that value. A successful Direct Action merges its result fields into top-level agent state. The existing `project_label` is retained because it does not conflict with those fields.

To use a supervised AgentServer instead, reuse the binding and Jido instance:

```elixir
{:ok, pid} = Jido.start_agent(JidoAgentHost.Engine, Files, id: "reader")

signal =
  Jido.Signal.new!("oh_my_jido.read", %{path: "mix.exs"}, source: "/jido_agent_host")

{:ok, updated} = Jido.AgentServer.call(pid, signal)
IO.puts(updated.state.content)
```

The plugin generates `oh_my_jido.read`, `oh_my_jido.edit` and the other selected tool routes. Use those routes or `Plugin.cmd/3`; they disable effect retries. Native Direct failures use error directives/signals, so `AgentServer.call/3` returning `{:ok, agent}` alone does not prove the Action succeeded.

## Walk through the files

| File | What to learn |
|---|---|
| [`lib/jido_agent_host/agents.ex`](lib/jido_agent_host/agents.ex), `ProjectStatus` | An ordinary application Action that remains in the AI tool registry |
| Same file, `Files` | A complete `Jido.Agent` declaration with `plugins:`, domain state and `private_diagnostics?/0` |
| Same file, `Editor` | A complete `Jido.AI.Agent` declaration with an explicit model, domain tool, `tool_max_retries: 0` and the plugin |
| [`lib/jido_agent_host/contexts.ex`](lib/jido_agent_host/contexts.ex) | A supervised store implementing `OhMyJido.Plugin.ContextProvider`; binds a validated Context by both agent module and ID |
| [`test/native_agent_test.exs`](test/native_agent_test.exs) | Signal-driven Read/Edit, native AI tool turns, permissions, rejected queries and the unbound-agent error directive |
| [`mix.exs`](mix.exs) | Consumer-owned dependency configuration and required diagnostic overrides |

`Contexts.bind/3` validates the workspace, permissions and tool selection with `Context.new/1`. The provider receives only `%{agent_module: module, agent_id: id}` and returns `{:ok, context}` or `{:error, :not_bound}`. The plugin resolves that binding inside each coding Action, not at agent construction. Context does not become agent/plugin state or model request data.

## Try the editor with your own provider

The test walkthrough does not need credentials. An interactive editor request does: configure your application's existing Jido.AI credentials and billing policy for the declared `"openai:gpt-4o-mini"` model before running this section. The plugin does not import credentials, use a managed runtime's resolver or replace your request transformer.

With the supervisor and `workspace` from above:

```elixir
alias JidoAgentHost.Editor

:ok =
  Contexts.bind(Editor, "editor",
    workspace: workspace,
    bundles: :read_only,
    permissions: [:read]
  )

{:ok, pid} = Jido.start_agent(JidoAgentHost.Engine, Editor, id: "editor")

{:ok, %{request: request, events: events}} =
  Editor.ask_stream(pid, "Read mix.exs and explain what this project does.")

for event <- events, do: IO.inspect(event)
{:ok, answer} = Editor.await(request, timeout: 60_000)
```

Native `ask/3`, `await/2`, `ask_stream/3`, steering and cancellation remain available. Let the native API generate request IDs; if you supply one, keep it unique. Reusing an ID cannot produce an independent request handle. Request-scoped tool selection can narrow trusted availability, not add Actions or permissions.

When requests have settled and you are finished with the demonstration:

```elixir
Supervisor.stop(supervisor)
```

## Adapt it to your application

1. Use the dependency recipe in [Getting started](../../docs/getting-started.md) rather than copying example-relative paths into your application.
2. Keep your agent's domain state, tools, model and trusted transformer. Add `OhMyJido.Plugin` to `plugins:` and choose only the bundles you need. Do not add unbound `OhMyJido.Tools.*` Actions to the AI registry; the plugin supplies the bound versions.
3. Implement `OhMyJido.Plugin.ContextProvider` using trusted application-owned bindings. Key them by agent module and ID, never by values supplied in model text or tool arguments. The example's Agent store is in memory, so re-establish bindings after its restart.
4. Set `private_diagnostics?/0` to `true` before native startup. For Jido.AI, keep `tool_max_retries: 0`. The plugin checks these settings and the required native diagnostic patch; it does not change global policy for you.
5. Bind the workspace, tool availability, permissions and any service adapters before running tools. To allow an edit, both plugin and Context must select Edit, and Context must include `:edit`. Language servers, debuggers and Observer targets still need explicit service configuration.
6. Decide how your application handles sensitive effects. The built-in managed approval conversation is not part of this pattern. If policy asks for approval without a managed coordinator, the Action returns `:approval_required`.

The [Jido integration guide](../../docs/guides/jido-agents.md) contains complete provider and plain/AI declarations, bundle tables and the standalone `Context` + `Jido.Exec` alternative.

### Understand failures

| Operation | Outcome to handle |
|---|---|
| Successful `Plugin.cmd/3` on this Direct agent | `{updated_agent, directives}`; Read normally has `[]` directives and fields such as `state.content`/`state.snapshot` |
| Failed coding Action on the Direct agent | `{unchanged_agent, [%Jido.Agent.Directive.Error{}]}`; an unbound identity reports `:context_not_bound` |
| Plugin preflight rejection | `{:error, {:oh_my_jido_plugin, reason}}` |
| Coding Action without its permission | A native tool error containing `{:permission_denied, capability}`; the AI may continue and explain the denial |
| Policy-rejected AI query | Native request tracking settles without a provider/tool call; await returns `{:error, {:failed, :error, {:request_transformer, reason}}}` |

For plugin policy rejection, the request-transformer reason is `{:rejected, :coding_tool_policy, message}`. Streaming can include native lifecycle/checkpoint events before terminal `:request_failed`; do not assume a one-event error stream.

## Limits

- Bundles select available tools, not permissions. The provider's Context is a second availability check and supplies the required permission checks.
- No Oh-My-Jido runtime, managed effect journal, recovery, approval UI, Goal/Memory/Eval or subagent coordinator is created. The plugin supports the bundled coding Actions, not the complete registry.
- Private Context bindings stay outside agent/request/checkpoint state. Public results, including file contents, can enter native state and model conversations. Your binding store and privileged application introspection remain trusted resources.
- Cancellation cannot undo an edit or prove an uncertain process never ran. Reconcile uncertain effects rather than automatically replaying them.
- Permissions and workspace confinement are library policy, not an OS sandbox. See [Security](../../docs/guides/security.md) before running untrusted work.

## Related

- [Documentation home](../../docs/README.md)
- [Jido integration guide](../../docs/guides/jido-agents.md)
- [Tools](../../docs/guides/tools.md)
- [Permissions and approvals](../../docs/guides/permissions-and-approvals.md)
- [Managed plain Mix example](../plain_mix/README.md)
