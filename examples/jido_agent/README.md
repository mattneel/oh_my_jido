# Add coding tools to your own Jido agents

This example adds Oh-My-Jido tools to two agents owned by an ordinary Mix application: a plain `Jido.Agent` named `JidoAgentHost.Files` and a `Jido.AI.Agent` named `JidoAgentHost.Editor`. Jido provides execution and supervision; Jido.AI provides the model-and-tool loop. The editor keeps its application-specific `project_status` tool alongside the coding tools.

Use this pattern when you already have a Jido agent and want repository tools without a second agent or an Oh-My-Jido runtime. For managed approvals, an effect journal and session recovery, use the [plain Mix example](../plain_mix/README.md) instead.

## Run the example

Use Elixir `~> 1.20` and the `jido-v3-preview` checkout. From the repository root:

```sh
cd examples/jido_agent
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
```

The tests use Jido.AI's scripted model interface, not a paid provider. They exercise real Read/Edit Actions on disposable files, the domain Action, permission denial and rejection of a forged context. No API key, optional Eval backend or installed Igniter application is needed.

This is an independent consumer with its own `deps/`, `_build/` and `mix.lock`. Its `mix.exs` overrides Jido, Jido.AI, Jido.Action and ReqLLM with the supplied snapshots and pins Jido Signal and Zoi to exact Git revisions. The preview uses native Jido 3.0.0-beta.1 and Jido.Action 3.0.0-beta.12; Jido.AI's upstream metadata still says 2.3.0 despite its native V3 profile API. Keep these dependencies together; do not substitute the stable branch's declarations or overrides.

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

{:ok, agent} = Files.new(id: "reader")
{:ok, updated, _directives} = OhMyJido.Plugin.cmd(agent, "read", %{path: "mix.exs"})
IO.puts(updated.state.oh_my_jido_tools.content)
IO.puts(updated.state.project_label)
```

`Plugin.cmd/3` sends a native Signal through the original agent's route without starting an AgentServer for that value. Successful coding output lives under `state.oh_my_jido_tools`. The plugin reducer replaces that result map and preserves top-level domain fields such as `project_label`.

To use a supervised AgentServer instead, reuse the binding and Jido instance:

```elixir
{:ok, pid} = Jido.start_agent(JidoAgentHost.Engine, Files, id: "reader")

signal =
  Jido.Signal.new!("oh_my_jido.read", %{path: "mix.exs"}, source: "/jido_agent_host")

{:ok, updated} = Jido.AgentServer.call(pid, signal)
IO.puts(updated.state.oh_my_jido_tools.content)
```

`Files` explicitly declares `oh_my_jido.read` and `oh_my_jido.edit` routes to bound Actions. Selecting bundles does not generate routes in V3; `Plugin.cmd/3` also requires the exact declared route. Coding execution uses no retries. Failures return `{:error, reason}`, not the stable branch's Direct error directives.

## Walk through the files

| File | What to learn |
|---|---|
| [`lib/jido_agent_host/agents.ex`](lib/jido_agent_host/agents.ex), `ProjectStatus` | An ordinary application Action that remains in the AI tool catalog |
| Same file, `Files` | A complete native `agent do` declaration, explicit `routes do`, domain state and `private_diagnostics?/0` |
| Same file, `Editor` | A complete AI profile: model, ReAct reasoning, domain tool, iteration limit, streaming, result field and `editor.ask` route |
| Same file, Editor's `extensions:` | `OhMyJido.Plugin.AgentExtension` adds the selected bound coding tools to static AI profiles |
| [`lib/jido_agent_host/contexts.ex`](lib/jido_agent_host/contexts.ex) | A supervised store implementing `OhMyJido.Plugin.ContextProvider`; binds a validated Context by both agent module and ID |
| [`test/native_agent_test.exs`](test/native_agent_test.exs) | Signal-driven Read/Edit, native AI tool turns, streamed permission errors, query admission rejection and the unbound-agent error |
| [`mix.exs`](mix.exs) | Consumer-owned dependency configuration and required preview overrides |

`Contexts.bind/3` validates the workspace, permissions and tool selection with `Context.new/1`. The provider receives only `%{agent_module: module, agent_id: id}` and returns `{:ok, context}` or `{:error, :not_bound}`. The plugin resolves that binding inside each coding Action, not during construction, preparation or request admission. Context does not become agent/plugin state or model request data.

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

Native `ask/3`, `await/2`, `ask_stream/3`, `steer/3` and cancellation remain available. The generated helper uses the declared `editor.ask` route; AI work requires AgentServer admission, not a process-free coding command. Let the native API generate request IDs; if you supply one, keep it unique. Reused IDs are rejected without terminating the original request's stream.

When requests have settled and you are finished with the demonstration:

```elixir
Supervisor.stop(supervisor)
```

## Adapt it to your application

1. Use the preview dependency recipe in [Getting started](../../docs/getting-started.md) rather than copying example-relative paths into your application.
2. Keep your agent's domain state, tools, model and trusted transformer. Declare `plugin OhMyJido.Plugin, config: [...]` inside `agent do`; choose only the bundles you need. Plain coding commands need explicit `oh_my_jido.<name>` routes to `OhMyJido.Plugin.Tools.*`.
3. For AI profiles, add `OhMyJido.Plugin.AgentExtension` to `extensions:` and keep genuine domain Actions in `tools do`. Do not add unbound `OhMyJido.Tools.*` Actions to the catalog. Programmatic profile authors can use `Plugin.tool_catalog/1` instead of the static extension.
4. Implement `OhMyJido.Plugin.ContextProvider` using trusted application-owned bindings. Key them by agent module and ID, never by values supplied in model text or tool arguments. The example's Agent store is in memory, so re-establish bindings after its restart.
5. Set `private_diagnostics?/0` to `true` before native startup. The extension's coding entries enforce `max_retries: 0`, `retry_backoff: 0`, `idempotency: :unsafe_once` and identity-only context forwarding. There is no V3 `tool_max_retries` agent option; native V3 Exec also rejects `max_retries` run options because it never retries.
6. Bind the workspace, tool availability, permissions and any service adapters before running tools. To allow an edit, both plugin and Context must select Edit, and Context must include `:edit`. Language servers, debuggers and Observer targets still need explicit service configuration.
7. Decide how your application handles sensitive effects. The built-in managed approval conversation is not part of this pattern. If policy asks for approval without a managed coordinator, the Action returns `:approval_required`.

The [Jido integration guide](../../docs/guides/jido-agents.md) contains complete provider and plain/AI declarations, bundle tables and the standalone `Context` + `Jido.Exec` alternative. Request-scoped tool selection can narrow trusted catalog entries, not add targets or change their execution policy.

### Understand failures

| Operation | Outcome to handle |
|---|---|
| Successful `Plugin.cmd/3` | `{:ok, updated_agent, directives}`; the result is stored under `state.oh_my_jido_tools`, and `directives` contains the plugin's result directive |
| Failed coding Action or plugin preflight | `{:error, reason}`; an unbound identity reports `:context_not_bound` |
| Missing direct coding route | A route error or `{:oh_my_jido_plugin, :explicit_coding_route_required}` |
| Coding Action without its permission | A native tool error containing `{:permission_denied, capability}`; the AI may continue and explain the denial |
| Policy-rejected AI query | `ask/3` and `ask_stream/3` return an error during admission, before a provider starts; no request handle or synthetic failure stream is created |

Native execution errors can carry `details.reason` and `details.retry: false`. Preserve the machine-readable reason instead of matching a human error string. Do not copy the stable branch's request-transformer rejection envelope into V3 error handling.

## Limits

- Bundles select available tools, not permissions. The provider's Context is a second availability check and supplies the required permission checks.
- No Oh-My-Jido runtime, managed effect journal, recovery, approval UI, Goal/Memory/Eval or subagent coordinator is created. The plugin supports the bundled coding Actions, not the complete registry.
- Private Context bindings stay outside agent/request/checkpoint state. Public results, including file contents, can enter native state and model conversations. Your binding store and privileged application introspection remain trusted resources. Private diagnostics do not retroactively protect work admitted before activation.
- Cancellation cannot undo an edit or prove an uncertain process never ran. Reconcile uncertain effects rather than automatically replaying them.
- Permissions and workspace confinement are library policy, not an OS sandbox. See [Security](../../docs/guides/security.md) before running untrusted work.

## Related

- [Documentation home](../../docs/README.md)
- [Jido integration guide](../../docs/guides/jido-agents.md)
- [Tools](../../docs/guides/tools.md)
- [Permissions and approvals](../../docs/guides/permissions-and-approvals.md)
- [Managed plain Mix example](../plain_mix/README.md)
