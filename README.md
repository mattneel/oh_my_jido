# OhMyJido

**An embeddable, host-controlled coding-agent library on Jido and OTP.**

Oh-My-Jido runs ordinary supervised coding sessions in an Elixir application.
Jido/Jido.AI own agent lifecycle and the native ReAct model/tool loop; Jido Actions
and `Jido.Exec` execute tools; ReqLLM owns provider transport. Your host owns
workspaces, accounts, permissions, approvals, storage, external services and
presentation. There is no required CLI, default coding instance or TypeScript/Bun
tool host.

The project declares app `:oh_my_jido`, version `0.1.0`, and Elixir `~> 1.20`.
Stable usability is verified in the [current acceptance record](docs/oh-my-jido/evidence/usability-20261019.json). Earlier [library-scope evidence](docs/oh-my-jido/evidence/library-acceptance-20261019.json) remains historical; [PROGRESS](docs/oh-my-jido/PROGRESS.md) records exact source hashes and boundaries.
No published Hex release or production certification is claimed; [operational boundaries](docs/oh-my-jido/OPERATIONS_AND_EVIDENCE.md) remain explicit.

## Choose the integration level

| You need | Start here | Who owns the agent? |
|---|---|---|
| Scoped tools in existing Elixir code | `Context.new/1` plus native `Jido.Action` modules | Your application; no coding runtime |
| Coding tools on your own Jido/Jido.AI agent | `OhMyJido.Plugin` and a trusted context provider | Your existing native agent and model policy |
| Managed coding sessions, approvals, journals and recovery | `{OhMyJido, name: MyApp.Coding}` | Host-supervised Runtime using native Jido |

Tool selection and permission grants are separate. None of these entrypoints imports credentials, grants execution, installs services or starts a model request merely by being configured.

## Installation

From an ordinary Mix consumer directory, preview setup from an approved source checkout **before** resolving the consumer dependency graph:

```sh
elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
elixir /absolute/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes
mix deps.get
mix compile
```

This uses native Igniter and changes only the consumer's `mix.exs` dependencies. It preserves the licensed Jido/ReqLLM privacy snapshots with required top-level overrides, pins the audited Jido.AI/Action version and refuses incompatible existing declarations. It does not evaluate consumer Mix/config/formatter code during the standalone bootstrap, configure credentials, start services or set up Runtime. Initial installer tooling may require ordinary Hex downloads. Add `--snakepit` to both commands only when explicitly selecting Python Eval; Python provisioning remains separate.

The installer requires a literal `project/0` configuration with `deps: deps()` and a literal private dependency list. Computed/incompatible layouts are refused rather than rewritten speculatively. For manual setup, retain the same source overrides:

```elixir
defp deps do
  root = Path.expand("../oh_my_jido", __DIR__)

  [
    {:oh_my_jido, path: root},
    {:jido, path: Path.join(root, "vendor/jido"), override: true},
    {:req_llm, path: Path.join(root, "vendor/req_llm"), override: true},
    {:jido_ai, "== 2.4.0"},
    {:jido_action, "== 2.4.0"}
  ]
end
```

Adapt the checkout location to your host. The independent
[plain Mix example](examples/plain_mix/README.md) selects the same licensed
Jido/ReqLLM path overrides, with its own dependencies, lockfile and build.
It does not select optional native Eval packages.
Do not replace the pinned Jido/ReqLLM diagnostic boundaries with stock packages
while retaining this library's credential/privacy claims.

QuickBEAM 0.11 and Snakepit 0.14 are optional, `runtime: false` dependencies.
No Eval language is enabled by default. A Python host must select the licensed
`vendor/snakepit` snapshot with `override: true, runtime: false`; stock Snakepit
lacks the required private-diagnostics boundary. Select/provision native backends
only when needed; missing dependencies fail explicitly, without an automatic
installer or substitute runtime. See [Eval operations](docs/oh-my-jido/EVAL_OPERATIONS.md).

## Supervise and embed

Place the public child directly in your application's supervision tree:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   bundles: :read_only,
   storage: {Jido.Storage.File, path: "/srv/my_app/coding_sessions"}}
]
```

Starting the application/runtime starts no session and sends no model request.
Create a session with an existing explicit workspace and minimal grants:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/srv/projects/demo",
    permissions: [:read]
  )

:ok = OhMyJido.subscribe(session, self())
{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

Direct tools work without model credentials and still use host policy and the
durable effect journal. To submit a model task, first configure a real host
credential resolver and an approved matching account/model/billing choice:

With the default local host, add `credentials: {MyApp.ModelCredentials, options}` to the Runtime child; the explicit resolver implements `resolve(context, opaque_account, options)`. A supervised `OhMyJido.Auth` broker is another supported resolver. Custom hosts retain their own credential callback. Nothing reads an API key from the environment unless your resolver deliberately does so.

```elixir
{:ok, run} =
  OhMyJido.prompt(session, "Explain this project's test setup without modifying files.",
    account: "host-selected-approved-account"
  )

result = OhMyJido.await(session, run, timeout: 60_000)
```

That account is an opaque reference already recognized by the host, never a key.
The default role aliases select Anthropic models; an OpenAI OAuth broker requires
an explicitly approved OpenAI model selection instead. No failed subscription
request falls back to separately billed API usage.

Keep your human/event interface responsive while another caller awaits. Delivery
is `{:oh_my_jido, %OhMyJido.Event{}}`; an `:approval_requested` event supplies the
question ID for `OhMyJido.answer/3` after a human decision. `Host.Local` asks for
source-marked sensitive effects, not every shell command. A grant is not an OS
sandbox or a universal sensitive-effect classifier.

Steer/cancel/suspend through the public API. Cancellation is a request, not
rollback. `await/3` and host-only inspection preserve actual terminal results and
uncertain effects; restore does not replay them. An idle checkpoint can be restored
through `resume_session/2` with the same runtime name and durable store.

The [embedding guide](docs/oh-my-jido/USER_GUIDE.md) includes a complete supervisor,
Host callback implementation and questions/recovery guidance. The independent
[plain Mix host](examples/plain_mix/README.md) supplies the exercised native
scripted repair and host-restart pattern.

## Individual native tools

```elixir
context =
  OhMyJido.Context.new!(
    workspace: "/srv/projects/demo",
    bundles: :read_only,
    permissions: [:read]
  )

Jido.Exec.run(
  OhMyJido.Tools.Read,
  %{path: "mix.exs"},
  %{oh_my_jido: context},
  max_retries: 0
)
```

The constructor canonicalizes the workspace and validates host/tool/adapter bindings without starting services. Grants default empty; bundle availability defaults read-only. Compose `Tools.select!([:read_only, :editing, :elixir, :process])` for explicit host tool lists. `:live_inspection` selects structured Observer only, not arbitrary live evaluation. Direct Actions retain root/grant/host checks but do not claim the managed session journal or recovery/approval conversation.

## Your own Jido agent

Use `OhMyJido.Plugin` in your agent's native `plugins:` list with `%{bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts}`. The provider implements `OhMyJido.Plugin.ContextProvider.fetch_context/1` and resolves a trusted Context by native module/ID. Keep `private_diagnostics?/0 == true` and, for Jido.AI, `tool_max_retries: 0`.

The plugin retains your existing model/transformer policy and genuine domain tools; it does not create Runtime or CodingAgent. Native plain routes are `oh_my_jido.read`, `oh_my_jido.edit`, etc.; `Plugin.cmd/3` exposes native result/error directives without a server. Jido.AI retains native `ask`/`await`/stream/cancel. The independent [own-agent example](examples/jido_agent/README.md) contains complete plain/AI agent declarations, a host binding store and actual native tool-turn exercises.

## Implemented surfaces and limits

- **Coding:** exact/ranged/binary reads, guarded atomic writes/edits, ignore-aware
  discovery/search, real Linux processes, fixed Git workflows and clean worktrees.
- **Intelligence:** native Elixir structural work, session-bound LSP/DAP stdio
  adapters, diff risk hints, host-approved artifacts and native image content parts.
- **Live application:** headless, explicitly granted OTP Observer for bounded
  metadata, plus an optional trusted-target Tidewave/MCP binding for actual app
  docs/source/logs and separately approved last-resort live evaluation/RPC.
  No wxWidgets, implicit attachment or replacement of isolated Eval.
- **Cooperation:** narrowed Jido children, parent control, structured questions,
  retained facts/plans/check evidence, bounded experiments, custom Jido Actions and
  explicitly trusted native skills.
- **Optional services:** scoped MCP tools/resources, browser and research adapter
  contracts. Unconfigured/unsupported host operations remain unavailable.
- **Eval:** persistent Elixir in a separate ERTS, QuickBEAM JavaScript only in an
  isolated ERTS, and exclusive Snakepit-managed Python workers. Hard loss invalidates
  state until explicit reset; execution/effects are not automatically retried.
- **Accounts:** six native roles/account selection; explicit OpenAI SIWC brokerage
  and metered API separation; official Claude Code is a separately approved
  delegated agent, not a native third-party Claude subscription loop.
- **Embedding/operations:** per-instance Config, native telemetry, bounded admission
  and durable Jido storage. ContextPolicy v2 rejects old policy checkpoints rather
  than relabeling their effect evidence.

These are interfaces/implementations with documented prerequisites, not a statement
that every required row is verified. Core workspace/grant controls, child ERTS and
native quotas **do not provide an OS sandbox**. Hosts own untrusted execution,
network policy, secret separation, resources and deployment.

## Documentation

| Guide | Contents |
|---|---|
| [User guide](docs/oh-my-jido/USER_GUIDE.md) | Source installation, independent embedding and Host example |
| [Public API](docs/oh-my-jido/PUBLIC_API.md) | Functions, types, events, results and errors |
| [Configuration](docs/oh-my-jido/RUNTIME_CONFIGURATION.md) | Exact defaults, budgets, six roles and per-instance selection |
| [Accounts](docs/oh-my-jido/ACCOUNT_OPERATIONS.md) | Host credentials, SIWC, billing and official Claude boundary |
| [Permissions and recovery](docs/oh-my-jido/PERMISSIONS_AND_RECOVERY.md) | Threat model, approvals, ContextPolicy v2, uncertainty and licensed diagnostic snapshots |
| [Tools and extensions](docs/oh-my-jido/TOOLS_AND_EXTENSIONS.md) | Editing, subagents, skills, LSP/DAP, headless Observer, live Tidewave/MCP, browser, research, review and artifacts |
| [Eval operations](docs/oh-my-jido/EVAL_OPERATIONS.md) | Three backends, native setup, trust, output and cancellation/reset limits |
| [Operations and evidence](docs/oh-my-jido/OPERATIONS_AND_EVIDENCE.md) | Telemetry, measured Linux x86_64 smoke, remaining platform/guest gates and Elixos ownership |
| [Changelog](CHANGELOG.md) | Unreleased source/documentation changes |

The [canonical specification index](docs/oh-my-jido/INDEX.md) remains the project's
authority order; [PROGRESS.md](docs/oh-my-jido/PROGRESS.md) is the exact integration
evidence ledger. The [Elixos example](examples/elixos/README.md) owns current
source/guest workflows. Core Oh-My-Jido does not import Elixos modules or perform
NEXT/reboot/health/COMMIT/fallback on its own.

## Development

Preserve the generated [AGENTS.md](AGENTS.md) project guidance:

```sh
mix deps.get
mix ci
```

`mix ci` runs warnings-as-errors compilation, formatter check, tests, strict Credo,
Dialyzer, ExDNA and Reach in the preferred test environment. The
[density harness](bench/README.md) and independent hosts have their own
human-invoked commands; do not equate a focused/smoke result with the full gate.
Recorded Linux x86_64 evidence does not establish aarch64 or actual guest delivery.

The generated documentation guidance still applies: documentation can be generated
with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on
[HexDocs](https://hexdocs.pm). This checkout does not currently declare ExDoc or a
documentation task; configure that tooling through the normal approved dependency
workflow before use. No documentation or package has been published by this work,
and a Hex dependency/HexDocs location is only applicable after an actual approved
release exists.
