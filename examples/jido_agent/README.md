# Attach coding tools to your own Jido agents

This independent Mix consumer defines its own `Jido.Agent` (`JidoAgentHost.Files`) and `Jido.AI.Agent` (`JidoAgentHost.Editor`). Neither starts an OhMyJido Runtime or CodingAgent. Jido owns execution; Jido.AI owns the model loop, request tracking, streaming and cancellation. The example's domain Action remains available alongside the selected coding Actions.

## Build and exercise

From this directory:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
```

Dependencies, lockfile and build belong to this consumer. Four top-level source overrides retain licensed native Core/AI/Action/ReqLLM snapshots; Signal and Zoi use exact upstream Git revisions. This is real native V3: Core3.0.0-beta.1 and Action3.0.0-beta.12; upstream AI metadata remains2.3.0. Optional Eval/installed Igniter are not required. Native scripted-provider tests exercise actual Actions without paid credentials; current gates belong in [PROGRESS](../../docs/oh-my-jido/PROGRESS.md).

## Declare the native plugin

```elixir
defmodule MyApp.Editor do
  use Jido.AI.Agent,
    name: "my_editor",
    extensions: [OhMyJido.Plugin.AgentExtension]

  agent do
    schema Zoi.object(%{answer: Zoi.string() |> Zoi.default("")})
    plugin OhMyJido.Plugin,
      config: [bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts]

    ai :assistant do
      model "openai:gpt-4o-mini"
      reasoning :react
      result into: :answer
    end
  end

  routes do
    route "editor.ask", ai: :assistant
  end

  def private_diagnostics?, do: true
end
```

Keep genuine domain Actions inside the native profile's `tools do` block. The static extension adds bound coding entries without replacing those Actions, model or transformer. Do not put unbound `OhMyJido.Tools.*` into the AI catalog. Keep `private_diagnostics?/0` true from startup; bound coding policies use zero retries/`:unsafe_once`. Credentials, billing and trusted transport remain the host's responsibility.

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

{:ok, agent} = Files.new(id: "reader")
{:ok, updated, []} = OhMyJido.Plugin.cmd(agent, "read", %{path: "mix.exs"})
IO.puts(updated.state.oh_my_jido_tools.content)
Supervisor.stop(host)
```

Plain modules explicitly declare selected `oh_my_jido.*` routes to bound Actions. Dispatch through ordinary native `Jido.AgentServer` signals or process-free `Plugin.cmd/3`. Successful tool results live under `agent.state.oh_my_jido_tools`; the reducer preserves domain fields. Native errors return `{:error, reason}`, not a successful result-shaped echo.

Start your module through your existing Jido instance and use native `ask`/`await`/`ask_stream`. Let native APIs generate request IDs; reused IDs cannot produce an independent handle or terminate the original stream. Per-request tool selection may narrow trusted availability, never add Actions or authority. Invalid admission returns an error before a provider starts.

## Explicit limits

- Bundles select availability, not grants. The host Context is a second ceiling; unavailable or ungranted Actions fail before their effect.
- The provider is called inside each actual coding Action. Context does not enter plugin state, model request state, worker payloads or checkpoints. Trusted host introspection and the host's own binding store remain outside the native agent diagnostic boundary.
- Mount/configuration does not start services, model requests or a Runtime. LSP/DAP/Observer still require deliberately configured host targets.
- Native V3 admission rejects invalid AI requests before a provider starts; `ask`/`ask_stream` return errors without manufacturing a handle, failed model turn or synthetic stream. Reused IDs cannot terminate the original stream.
- No managed effect journal, recovery, approval UI, Goal/Memory/Eval or subagent coordination is implied. Host approval without a managed coordinator returns `:approval_required`. Use managed Runtime sessions when you need those lifecycle facilities.
- Cancellation does not roll back edits or prove an uncertain process never ran. Reconcile uncertain effects rather than replaying them automatically.
- No OS sandbox, external Elixos integration, subscription login, release or production certification is claimed.
