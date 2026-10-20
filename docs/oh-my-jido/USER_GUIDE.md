# User guide: embedding the implemented library

This guide describes the source API and its three integration levels. The canonical [specification index](INDEX.md) defines the library boundary; [PROGRESS.md](PROGRESS.md) records current verification and the usability delivery. Use [the API reference](PUBLIC_API.md), not proposed signatures in older specifications.

Oh-My-Jido is an OTP library. Jido owns the agent hierarchy; Jido.AI ReAct owns model/tool turns, streaming and control; Jido Actions and `Jido.Exec` execute tools; ReqLLM owns provider encoding and transport. There is no required CLI, TUI, Bun tool host or default coding instance. Starting the application starts no coding session and sends no model request.

## Choose how much to embed

| Integration | What you configure | What you do not get implicitly |
|---|---|---|
| Individual Jido Actions | Validated `Context`, explicit workspace/grants and a selected Action | Model loop, runtime, journal or recovery |
| Native plugin on your own agent | `OhMyJido.Plugin`, trusted context provider, selected bundles and native agent safety settings | A second agent, credential policy, managed approvals/checkpoints/subagents |
| Managed coding sessions | Named `{OhMyJido, options}` child, session workspace/grants, explicit model/account resolver when needed | Ambient credentials, an automatic session/model request, optional service installation |

The first useful task can be a credential-free Read. Enable editing, execution, language servers, live targets and model billing only when the host deliberately configures them.

## Reading path

1. This guide: source installation, supervision and host integration.
2. [Public API](PUBLIC_API.md): calls, return values, events and types.
3. [Configuration](RUNTIME_CONFIGURATION.md): exact defaults, independent instances and six model roles.
4. [Accounts and billing](ACCOUNT_OPERATIONS.md): host-owned credentials, OpenAI SIWC and official Claude Code delegation.
5. [Permissions and recovery](PERMISSIONS_AND_RECOVERY.md): threat model, questions, effect uncertainty and ContextPolicy v2.
6. [Tools and extensions](TOOLS_AND_EXTENSIONS.md): precise editing, delegation, skills, language intelligence and host services.
7. [Eval operations](EVAL_OPERATIONS.md): three persistent languages, optional prerequisites and invalidation.
8. [Operations and evidence](OPERATIONS_AND_EVIDENCE.md): telemetry, density, platform limits and Elixos ownership.

## Install from an approved source checkout

The project declares `:oh_my_jido`, version `0.1.0`, and Elixir `~> 1.20`; this branch targets the coherent native Jido V3 preview. No Hex publication is claimed. Preserve all four licensed Core/AI/Action/ReqLLM source overrides and exact Signal/Zoi Git revisions. Core is3.0.0-beta.1; upstream AI still reports2.3.0 despite its native V3 implementation. SDK `UPSTREAM.json` manifests and the branch README record provenance; stable2.4 evidence is historical, not V3 acceptance.

From the consumer directory, use the standalone source bootstrap before its dependency graph is resolved:

```sh
elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes
mix deps.get
mix compile
```

Native Igniter previews the dependency change and applies only with explicit confirmation flags. Only `mix.exs` changes; four source overrides and exact Signal/Zoi Git refs are added. The bootstrap never evaluates consumer Mix/config/formatter code. Its tooling may use ordinary Hex downloads, but it does not resolve the consumer graph or start services. Incompatible/computed layouts are refused. Add `--snakepit` only for the patched optional backend.

The independent [plain Mix host](../../examples/plain_mix/README.md) demonstrates the actual dependency pattern. In a host whose checkout layout is the same as `examples/plain_mix`, its `mix.exs` uses:

```elixir
defp deps do
  root = Path.expand("../..", __DIR__)

  overrides =
    Enum.map([:jido, :jido_ai, :jido_action, :req_llm], fn app ->
      {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
    end)

  [
    {:oh_my_jido, path: root},
    {:jido_signal, git: "https://github.com/agentjido/jido_signal.git",
     ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41", override: true},
    {:zoi, git: "https://github.com/mikehostetler/zoi.git",
     ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9", override: true}
  ] ++ overrides
end
```

For another layout, change only how the approved absolute `root` is obtained. Retain the dependency declarations/lockfile and the licensed source directories. The independent example uses its own `deps/` and build; it does not evaluate another Mix project to discover dependency declarations or share mutable downloaded sources. A Python host additionally selects the licensed Snakepit snapshot described in [Eval operations](EVAL_OPERATIONS.md).

QuickBEAM and Snakepit are optional and `runtime: false` in this project. An ordinary consumer need not select them. Missing native packages return explicit capability errors, not a fallback engine. [Eval operations](EVAL_OPERATIONS.md) explains opt-in packaging.

## Put Runtime under the host supervisor

This complete supervisor module uses the same construction as the independent example:

```elixir
defmodule MyApp.CodingSupervisor do
  use Supervisor

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    runtime = Keyword.get(options, :runtime, MyApp.Coding)
    storage_path = Keyword.fetch!(options, :storage_path)
    runtime_options = Keyword.take(options, [:credentials])

    children = [
      {OhMyJido,
       Keyword.merge(runtime_options,
         name: runtime,
         bundles: :read_only,
         storage: {Jido.Persistence.File, path: storage_path}
       )}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Place `{MyApp.CodingSupervisor, storage_path: "/srv/my_app/coding_sessions"}` in the application's children. That path must be host-owned, writable and outside repositories the agent may edit. Its contents include private conversation/evidence; the session store is not a credential vault and does not encrypt itself.

If the host already supervises an authorized OAuth broker, add:

```elixir
credentials: {OhMyJido.Auth, broker: MyApp.AccountBroker}
```

`MyApp.AccountBroker` is a name chosen and supervised by the host, not a library default. Starting a runtime does not enroll an account. Production model requests require a selected opaque account and explicit host-supplied inference credentials. Direct tools and idle sessions can be used without a provider account.

## Open a rooted session

The directory must already exist. Supply only the tools and grants this task needs:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/srv/projects/demo",
    permissions: [:read, :edit, :exec, :ask],
    tools: OhMyJido.Tools.select!([:read_only, :editing, :process]) ++ [OhMyJido.Tools.Question],
    role: :coding,
    account: "host-selected-account"
  )

:ok = OhMyJido.subscribe(session, self(), max_pending: 128)
{:ok, run} = OhMyJido.prompt(session, "Repair the failing test. Preserve the public API.")
```

The string account above represents a reference already recognized by the host's credential service; it is not a token. Use an account/model pair approved for the same provider and billing mode. The runtime resolves model metadata locally but neither selects a paid credential nor probes eligibility on your behalf.

For a credential-free example that executes actual tools rather than a model:

```elixir
{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "lib/demo.ex"})
# file.snapshot covers the entire file even when a read selects a line range.
```

`execute_tool/4` still uses grants, host authorization, `Jido.Exec` and the durable effect journal. It is not a policy bypass.

For a tool-only integration, no supervisor is needed:

```elixir
context = OhMyJido.Context.new!(
  workspace: "/srv/projects/demo",
  bundles: :read_only,
  permissions: [:read]
)

Jido.Exec.run(OhMyJido.Tools.Read, %{path: "mix.exs"}, %{oh_my_jido: context}, max_retries: 0)
```

`Context.new/1` is the non-raising form. It canonicalizes an existing root, supplies a native ID when omitted, defaults to **no grants** and returns field-specific errors for invalid configuration. Bundle names only select availability. `:live_inspection` is structured Observer, not live execution; `:elixir` still needs explicit language/debugger services. Direct Actions preserve their filesystem/host/capability checks but are not managed session journal/recovery operations. A missing human approval coordinator returns an approval error; use managed sessions for the built-in approval conversation or supply deliberate host policy.

## Consume events and keep the human interface responsive

Delivery is `{:oh_my_jido, %OhMyJido.Event{}}`. A UI/coordinator should consume events while a separate caller waits with `await/3`. Do not block the only question responder in `await/3`.

```elixir
receive do
  {:oh_my_jido,
   %OhMyJido.Event{kind: :approval_requested, payload: %{id: question_id, question: question}}} ->
    {question_id, question}

  {:oh_my_jido, %OhMyJido.Event{} = event} ->
    Map.take(Map.from_struct(event), [:session_id, :run_id, :seq, :kind, :at_ms])
end
```

The first branch returns a request for your existing human interface to display. Only after that interface obtains a decision does it call `OhMyJido.answer(session, question_id, answer)`. For an effect approval, `true`, `:approve` or `"approve"` consents; other answers deny. Clarification answers can be structured values. No default answer is consent, and a capability grant alone is not approval of a sensitive effect.

Inspect `:run_completed`'s `payload.status`; the event name is also used for failed, cancelled, suspended, timed-out and interrupted runs. Collect the actual result:

```elixir
result = OhMyJido.await(session, run, timeout: 60_000)
```

A completed model answer is not proof that a tool succeeded or that the repository passed its tests. Examine the returned tool/effect records and actual process exit results. An await timeout does not cancel the run.

During an active run, the host can use `steer/3`, `cancel/2` or `suspend/2`. Suspension terminates that run; `resume/1` unblocks the session for a new task and does not restart the old effects. Controls that target a non-active run return `{:error, :run_not_active}`.

## Implement a stricter host policy

`Host.Local` is a reference policy: the dispatcher checks grants, sensitive effects ask for approval, optional capabilities dispatch only to configured adapters, credentials come only from an explicit resolver, and questions remain pending. In particular, it does not automatically classify every shell command as sensitive.

This complete host callback module also asks before every shell, Eval or custom-tool effect:

```elixir
defmodule MyApp.CodingHost do
  @behaviour OhMyJido.Host

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
  def credentials(context, account, options) do
    OhMyJido.Auth.resolve(context, account, broker: Keyword.fetch!(options, :broker))
  end

  @impl true
  def invoke(context, capability, request, _options) do
    case Map.fetch(context.adapters, capability) do
      {:ok, {module, options}} -> module.invoke(context, request, options)
      :error -> {:error, {:capability_unavailable, capability}}
    end
  end

  @impl true
  def question(_context, _question, _options), do: :pending
end
```

Configure it with `host: {MyApp.CodingHost, broker: MyApp.AccountBroker}`. This example supplies authorization and dispatch, not a browser, credential store or OS sandbox. Choose a stricter command/network/path policy for the actual host. Never put provider secrets in command arguments, project instructions, adapter responses or approval descriptions.

Callbacks must honor their deadlines, retain session ownership and clean up real resources. The callback's options are trusted host data; the model's request must not become a module, MFA, executable selector or policy change.

## Checkpoint and restore

After the run is idle:

```elixir
:ok = OhMyJido.checkpoint(session)
:ok = OhMyJido.stop_session(session)
{:ok, restored} = OhMyJido.resume_session(MyApp.Coding, session.id)
{:ok, snapshot} = OhMyJido.inspect_session(restored)
```

Across host restarts, retain the runtime name and durable storage configuration. A session ID is durable; `agent_pid` in an inspection is an intentional **host-only** transient native diagnostic, not a restoration handle or serializable public UI/telemetry field. Configure account resolvers and adapters again in the runtime: per-session credential-bearing host/adapters and arbitrary metadata are deliberately transient. Restored interrupted runs/effects are not replayed.

After independent operator cleanup, `reconcile_interrupted/4` can record execution
quiescence for the exact pending effect set of an originally restored interrupted
run. It preserves outcome uncertainty and performs no model request or replay;
it is not native SDK shutdown proof or a way to unseal a live stopping session.
See [explicit operator reconciliation](PERMISSIONS_AND_RECOVERY.md#explicit-operator-reconciliation).

ContextPolicy **version 2** is a clean cutover. Old version-1 policy checkpoints cannot be safely upgraded by changing a version field; restore rejects them. Preserve historical evidence, reconcile uncertainty and start a new session with approved retained facts when an old policy is encountered. See [permissions and recovery](PERMISSIONS_AND_RECOVERY.md).

## Independent examples and operational scope

- [Plain Mix host](../../examples/plain_mix/README.md): real native scripted repair, actual disposable Mix tests, human controls and File-store restart; optional native runtimes are not selected.
- [Own Jido agents](../../examples/jido_agent/README.md): complete plain/AI declarations, explicit host context store, preserved domain tools, native requests and real scoped Read/Edit without managed Runtime.
- [Elixos host](../../examples/elixos/README.md): requester roots, Ask, current source services, candidate provenance and guest workflow. Core Oh-My-Jido never imports Elixos modules or promotes OS generations.
- [Density harness](../../bench/README.md): finite credential-free populations and real tools; simulated model latency is not provider latency.

Examples are source-backed patterns. Current exercised commands, earlier failures and scope limits are recorded in [PROGRESS](PROGRESS.md) and [operations and evidence](OPERATIONS_AND_EVIDENCE.md). These local usability exercises do not imply new live-provider authorization, external guest effects or publication.
