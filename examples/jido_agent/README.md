# Attach coding tools to your own Jido agents

This independent Mix consumer defines its own `Jido.Agent` (`JidoAgentHost.Files`) and `Jido.AI.Agent` (`JidoAgentHost.Editor`). Neither starts an OhMyJido Runtime or CodingAgent. Jido owns execution; Jido.AI owns the model loop, request tracking, streaming and cancellation. The example's domain Action remains available alongside the selected coding Actions.

## Build and exercise

From this directory:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
```

Dependencies, lockfile and build belong to this consumer. Top-level overrides retain the licensed Jido/ReqLLM private-diagnostics snapshots; audited Jido.AI/Action are pinned to 2.4.0. Optional Eval backends and Igniter are not required. Native scripted-provider tests execute real scoped filesystem Actions without paid credentials or a fake coding tool implementation. Current verification is recorded in [PROGRESS](../../docs/oh-my-jido/PROGRESS.md).

## Declare the native plugin

```elixir
defmodule MyApp.Editor do
  use Jido.AI.Agent,
    name: "my_editor",
    model: "openai:gpt-4o-mini",
    tools: [],
    tool_max_retries: 0,
    plugins: [
      {OhMyJido.Plugin,
       %{bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts}}
    ]

  def private_diagnostics?, do: true
end
```

Existing genuine domain tools may stay in `tools:`. The plugin binds its own selected coding Actions into native ReAct requests; do not put unbound `OhMyJido.Tools.*` Actions in the AI registry. Keep the native private-diagnostics callback and zero effect retries. Your model, credentials, billing and trusted request transformer remain your responsibility; the plugin neither imports credentials nor replaces them with the managed Runtime policy.

`MyApp.CodingContexts` implements `OhMyJido.Plugin.ContextProvider.fetch_context/1`, receiving `%{agent_module: module, agent_id: id}` and returning `{:ok, context}` or `{:error, reason}`. Resolve a stable Context from host-owned bindings. Do not derive workspace, grants, host, provider module or service bindings from query/tool arguments. `JidoAgentHost.Contexts` demonstrates an explicitly supervised binding store keyed by both module and ID.

## Credential-free plain Jido usage

In this consumer's `mix run` or IEx session:

```elixir
alias JidoAgentHost.{Contexts, Files}

{:ok, host} = Supervisor.start_link([Contexts], strategy: :one_for_one)
:ok = Contexts.bind(Files, "reader",
  workspace: "/srv/projects/demo",
  bundles: :read_only,
  permissions: [:read]
)

agent = Files.new(id: "reader")
{updated, []} = OhMyJido.Plugin.cmd(agent, "read", %{path: "mix.exs"})
IO.puts(updated.state.content)
Supervisor.stop(host)
```

For your already-supervised native agent, dispatch `oh_my_jido.read`, `oh_my_jido.edit`, etc. through ordinary `Jido.AgentServer` signals. Native Direct strategy merges successful Action output into agent state. Its instruction failures are native error directives/signals; `AgentServer.call/3` returning `{:ok, agent}` alone does not prove the Action succeeded. Process-free `Plugin.cmd/3` exposes the returned directives for host inspection.

For AI execution, start your own module through your existing Jido instance and use its native `ask`/`await`/`ask_stream` APIs. Let native APIs generate request IDs; explicitly reused IDs cannot produce an independent request handle. Per-request tool selection may narrow trusted availability, never add Actions or authority. Query rejection settles native request tracking and terminal stream events without a provider request.

## Explicit limits

- Bundles select availability, not grants. The host Context is a second ceiling; unavailable or ungranted Actions fail before their effect.
- The provider is called inside each actual coding Action. Context does not enter plugin state, model request state, worker payloads or checkpoints. Trusted host introspection and the host's own binding store remain outside the native agent diagnostic boundary.
- Mount/configuration does not start services, model requests or a Runtime. LSP/DAP/Observer still require deliberately configured host targets.
- Denied AI requests use native bounded request tracking and a rejecting request transformer before provider/tool execution. Await returns the native request-transformer failure envelope; streams retain native lifecycle events and terminate with `:request_failed`.
- No managed effect journal, recovery, approval UI, Goal/Memory/Eval or subagent coordination is implied. Host approval without a managed coordinator returns `:approval_required`. Use managed Runtime sessions when you need those lifecycle facilities.
- Cancellation does not roll back edits or prove an uncertain process never ran. Reconcile uncertain effects rather than replaying them automatically.
- No OS sandbox, external Elixos integration, subscription login, release or production certification is claimed.
