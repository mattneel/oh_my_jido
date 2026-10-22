# Add coding tools to your Jido agents

Use individual Oh-My-Jido tools when your application already knows which operation to run. Add the plugin when you want those tools on an agent you already own. Jido provides agents and their OTP lifecycle; Jido.AI adds a model-and-tool loop. Neither integration requires a second coding agent.

## Choose an integration

| Choose | What you configure | What you get | What you do not get automatically |
|---|---|---|---|
| Standalone tools | A trusted `OhMyJido.Context` and the Action to execute | File, search, editing and other tools called from your Elixir code, with their permission and application-policy checks | A model loop, managed runtime, effect journal, approval conversation or recovery |
| Plugin on your agent | `OhMyJido.Plugin`, selected bundles and a context provider | Coding tools alongside your domain tools; your existing Jido/Jido.AI agent, model policy and native request APIs | Another agent, credentials, managed checkpoints, goals, subagents or an approval UI |
| Managed runtime | A supervised `{OhMyJido, name: MyApp.Coding}` child and sessions | Coding sessions with events, questions, approvals, an effect journal and checkpoint/recovery APIs | Permissions, credentials, an automatic session/model request, optional services or an OS sandbox |

Start with a credential-free Read. Choose [managed sessions](../getting-started.md) if you need the built-in human approval and recovery workflow. The [plain Mix example](../../examples/plain_mix/README.md) demonstrates that route; the [own-agent example](../../examples/jido_agent/README.md) demonstrates the plugin.

## Before you start

Install the dependencies described in [Getting started](../getting-started.md), including the supplied Jido, Jido.AI, Jido.Action and ReqLLM snapshots. This page uses the `jido-v3-preview` branch's native Jido 3 agent/profile DSL. Do not mix these declarations or dependency overrides with the `master` branch's Jido 2.4 examples.

Your workspace must be an existing directory. Read needs `permissions: [:read]`; enabling a tool does not grant its permission. Search/List need ripgrep, Git tools need Git, and process tools need the [Linux prerequisites](../operations.md). Language servers, debuggers and live application targets need their own configuration.

## Call a tool from Elixir

No Oh-My-Jido runtime or session supervisor is needed:

```elixir
context =
  OhMyJido.Context.new!(
    workspace: "/path/to/project",
    bundles: :read_only,
    permissions: [:read]
  )

{:ok, file} =
  Jido.Exec.run(
    OhMyJido.Tools.Read,
    %{path: "mix.exs"},
    %{oh_my_jido: context},
    timeout: 30_000
  )

IO.puts(file.content)
```

Read returns `{:ok, file_map}`. Failures return `{:error, reason}`; native validation/execution errors can be exception structs, not strings. Other Actions can also return `{:ok, result, effects}`. Native V3 `Jido.Exec` never retries. Unlike the stable branch, it rejects `max_retries: 0` as an unknown option, so omit that option. Its default timeout is `:infinity`; the example sets a finite deadline.

| Read result field | Meaning |
|---|---|
| `path` | Workspace-relative path |
| `content`, `encoding`, `binary` | Text and `"utf8"` for a text file; binary files have `content: nil`, `encoding: "binary"` and a `base64` field |
| `snapshot` | Lowercase SHA256 of the whole file, even for a line-range or truncated read; use it for a later guarded edit |
| `bytes`, `bytes_returned` | Whole-file size and returned source-byte count, before Base64 encoding for binary files |
| `line_count`, `start_line`, `end_line`, `newline` | Text range and newline information; binary results do not have text-range fields |
| `truncated`, `truncation.output` | Whether the selected output exceeded the output limit |

`Context.new!/1` canonicalizes the workspace and validates configuration. It does not invoke your policy/adapter callbacks, start services, read credentials or send a model request. `Context.new/1` is the non-raising form: `{:ok, context}` or `{:error, {:invalid_context, field, reason}}`.

When calling `Jido.Exec` directly, your application chooses the Action module. Use the selected list in `context.tools` to make that choice; `Jido.Exec` itself is not a tool-registry gate. The Action still checks its own permissions, workspace and application policy. The plugin adds the registry checks described below.

## Provide trusted context for each agent

A context provider maps an agent's module and ID to the workspace and permissions your application assigned it. The plugin calls `fetch_context/1` inside each coding Action, not during agent construction, preparation or request admission. Do not take workspace, permissions, policy modules or service bindings from queries, signals or tool arguments.

This implementation follows the example's supervised binding store:

```elixir
defmodule MyApp.CodingContexts do
  use Agent
  @behaviour OhMyJido.Plugin.ContextProvider

  def start_link(_options) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def bind(agent_module, agent_id, options) do
    with {:ok, context} <- OhMyJido.Context.new(options) do
      Agent.update(__MODULE__, &Map.put(&1, {agent_module, agent_id}, context))
    end
  end

  @impl true
  def fetch_context(%{agent_module: module, agent_id: id}) do
    case Agent.get(__MODULE__, &Map.fetch(&1, {module, id})) do
      {:ok, context} -> {:ok, context}
      :error -> {:error, :not_bound}
    end
  end
end
```

The key includes both module and ID, so two agent types cannot accidentally share a binding. In your application you can use a trusted database or another supervised store instead. Re-establish bindings after this in-memory store restarts. Returned contexts must have `runtime: nil` and `coordinator: nil`; managed session contexts are not accepted by the plugin.

## Add the plugin to a Jido agent

Define the agent, select its available bundles and declare each public tool route:

```elixir
defmodule MyApp.Files do
  use Jido.Agent, name: "project_files"

  agent do
    schema(Zoi.object(%{project_label: Zoi.string() |> Zoi.default("my-project")}))

    plugin(OhMyJido.Plugin,
      config: [bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts]
    )
  end

  routes do
    route("oh_my_jido.read", OhMyJido.Plugin.Tools.Read)
    route("oh_my_jido.search", OhMyJido.Plugin.Tools.Search)
    route("oh_my_jido.list", OhMyJido.Plugin.Tools.List)
    route("oh_my_jido.write", OhMyJido.Plugin.Tools.Write)
    route("oh_my_jido.edit", OhMyJido.Plugin.Tools.Edit)
  end

  def private_diagnostics?, do: true
end
```

Keep `private_diagnostics?/0` returning `true` before native startup. The plugin checks for the supplied diagnostic patch; it does not change global diagnostic settings. Privacy does not retroactively protect work admitted before activation.

Supervise the binding store and a Jido instance, then bind a specific agent identity:

```elixir
{:ok, supervisor} =
  Supervisor.start_link(
    [MyApp.CodingContexts, {Jido, name: MyApp.Jido}],
    strategy: :one_for_one
  )

:ok =
  MyApp.CodingContexts.bind(MyApp.Files, "reader",
    workspace: "/path/to/project",
    bundles: :read_only,
    permissions: [:read]
  )
```

The agent's plugin makes Read and Edit available, but this particular binding only permits read-only tools. Both selections must allow an Action, and its required permission must be present. Routes control which coding commands your agent accepts directly; they do not grant permissions.

### Run a tool without an AgentServer

`Plugin.cmd/3` accepts the original Action module or its exact tool name, such as `"read"`. It sends a native Signal through your agent's declared route:

```elixir
{:ok, agent} = MyApp.Files.new(id: "reader")

{:ok, updated, _directives} = OhMyJido.Plugin.cmd(agent, "read", %{path: "mix.exs"})
IO.puts(updated.state.oh_my_jido_tools.content)
IO.puts(updated.state.project_label)
```

Successful coding results live under `agent.state.oh_my_jido_tools`. The plugin reducer replaces that result map while preserving your domain fields. It does not merge arbitrary tool keys into top-level state.

Failures return `{:error, reason}`, not a successful result-shaped reply or the stable branch's Direct error directives:

```elixir
{:ok, unbound} = MyApp.Files.new(id: "not-bound")
{:error, error} = OhMyJido.Plugin.cmd(unbound, "read", %{path: "mix.exs"})
IO.inspect(error)
```

Here the error reports `:context_not_bound`. Native errors can carry a machine-readable reason in `details.reason`; coding execution failures mark `details.retry` as `false`. Do not assume every error is an atom or a string.

### Send a signal to a running agent

Declare routes as above, then use ordinary `Jido.AgentServer` calls:

```elixir
{:ok, pid} = Jido.start_agent(MyApp.Jido, MyApp.Files, id: "reader")

signal =
  Jido.Signal.new!("oh_my_jido.read", %{path: "mix.exs"}, source: "/my_app/files")

{:ok, updated} = Jido.AgentServer.call(pid, signal)
IO.puts(updated.state.oh_my_jido_tools.content)
```

Examples include `oh_my_jido.read`, `oh_my_jido.search`, `oh_my_jido.write` and `oh_my_jido.edit`. In V3, selecting bundles does not automatically add these routes. `Plugin.cmd/3` also requires the exact route to the selected bound Action. All coding effects use native execution without retries.

## Add the plugin to a Jido.AI agent

Jido.AI uses a ReAct loop: the model chooses a tool, sees its result and continues. Add `OhMyJido.Plugin.AgentExtension` to bind the coding tools into each static AI profile while keeping your model and domain tools.

```elixir
defmodule MyApp.Editor do
  use Jido.AI.Agent,
    name: "project_editor",
    extensions: [OhMyJido.Plugin.AgentExtension]

  agent do
    schema(Zoi.object(%{answer: Zoi.string() |> Zoi.default("")}))

    plugin(OhMyJido.Plugin,
      config: [bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts]
    )

    ai :assistant do
      model("openai:gpt-4o-mini")
      reasoning(:react)

      controls do
        max_iterations(8)
      end

      observability do
        stream_content(true)
      end

      result(into: :answer)
    end
  end

  routes do
    route("editor.ask", ai: :assistant)
  end

  def private_diagnostics?, do: true
end
```

Put genuine domain Actions in the profile's `tools do` block. Do not put unbound `OhMyJido.Tools.*` modules in the catalog. The extension adds bound coding entries with `max_retries: 0`, `retry_backoff: 0`, `idempotency: :unsafe_once` and an identity-only context projection. There is no V3 `tool_max_retries` agent option; do not copy that stable-branch setting into this declaration.

For programmatically constructed profiles, `Plugin.tool_catalog/1` returns `{:ok, catalog}` or an error. Combine those entries with your native domain catalog instead of using the static extension. Request selections can narrow the declared catalog, never broaden its targets or change its execution policy. Your native model, transport, request transformer, interceptors and request coordinator remain in control.

Before making a model request, configure credentials and billing through your application's existing Jido.AI setup. The plugin does not apply a managed runtime's credentials resolver or turn a Context's `account` into model credentials. The own-agent example's tests demonstrate tool turns without provider credentials.

Using the same supervised store and Jido instance as above:

```elixir
:ok =
  MyApp.CodingContexts.bind(MyApp.Editor, "editor",
    workspace: "/path/to/project",
    bundles: [:read_only, :editing],
    permissions: [:read, :edit]
  )

{:ok, pid} = Jido.start_agent(MyApp.Jido, MyApp.Editor, id: "editor")
{:ok, request} = MyApp.Editor.ask(pid, "Read mix.exs and explain this project.")
{:ok, answer} = MyApp.Editor.await(request, timeout: 60_000)
```

For streaming, `MyApp.Editor.ask_stream/3` returns `{:ok, %{request: handle, events: enumerable}}`; consume the events and then await the handle. Native `steer/3` and `cancel/2` remain available. AI routes require AgentServer admission; process-free `Plugin.cmd/3` is for coding commands, not starting the model loop. When finished with this standalone demonstration, call `Supervisor.stop(supervisor)`.

Let native APIs generate request IDs. If you supply them, each ID must be unique. V3 rejects invalid requests before a provider starts: `ask/3` and `ask_stream/3` return an error without creating a request handle, a failed model turn or a synthetic stream. Reused IDs are rejected without terminating the original stream.

## Reference

### Tool selection and context

| API or option | Contract |
|---|---|
| `Tools.bundles/0` | Returns the fixed availability map below |
| `Tools.select/1` | Accepts one bundle atom or a list; returns `{:ok, modules}` or a selection error; removes duplicates in caller order; `[]` selects nothing |
| `Tools.select!/1` | Returns the same list or raises `ArgumentError` |
| Selection errors | `{:unknown_bundle, name}`, `{:invalid_bundle, value}` or `{:invalid_bundle_selection, :expected_atom_or_list}`; strings are not converted to atoms |
| `Tools.default/0` | The complete registry, not a blanket permission or optional-service installer |
| `Context` `workspace:` | Required, existing directory; canonicalizes symlinks |
| `permissions:` | Defaults to `[]`; accepts a list or `MapSet` of permission atoms |
| `bundles:` | Defaults to `[:read_only]`; selects availability, not read permission |
| `tools:` | Explicit Action list, including custom Actions; replaces bundles; supplying both `tools:` and `bundles:` is an error |
| `session_id:` | Keeps a supplied ID or generates a native Jido ID; does not create a managed session |
| `host:`, `adapters:` | Trusted policy/service bindings; callbacks are checked but not called by the constructor |
| `Context.fetch/1`, `Context.permitted?/2` | Extract an existing Context and check an existing permission; neither creates authority |

The plugin accepts only `bundles:` and `context_provider:` configuration. The provider is required; bundles default to `[:read_only]`.

| Bundle | Actions / signal suffixes | Additional setup |
|---|---|---|
| `:read_only` | Read (`read`), Search (`search`), List (`list`) | `:read` permission; ripgrep for Search/List |
| `:editing` | Write (`write`), Edit (`edit`) | `:edit` permission and snapshot-guarded inputs |
| `:elixir` | AST (`ast`), LSP (`lsp`), Debug (`debug`) | [Language intelligence](language-intelligence.md) permissions and services |
| `:process` | Shell (`shell`), Git (`git`) | [Process/Git permissions](tools.md) and system executables |
| `:live_inspection` | Observer (`observer`) | Configured live target and `:observe`; structured inspection, not arbitrary live evaluation |

### Plugin failures

Configuration and preflight errors use `{:oh_my_jido_plugin, reason}`; execution can wrap that reason in native error structs. Match the machine-readable reason, not a human error string.

| Reason | What to change |
|---|---|
| `:context_not_bound` | Bind this exact agent module and ID before running a tool |
| `:context_provider_required`, `:context_provider_callback_required` | Configure a provider exporting `fetch_context/1` |
| `:private_diagnostics_required`, `:native_private_diagnostics_required` | Enable the callback before startup and install the required native snapshots |
| `:tool_not_available`, `:tool_not_available_in_host_context` | Select the tool in both the plugin and the trusted Context |
| `:explicit_coding_route_required` | Declare the exact `oh_my_jido.<name>` route to its bound Action |
| `:unbound_or_conflicting_coding_tool` | Remove unbound coding Actions or conflicting tool names from the domain catalog |
| `:untrusted_authority`, `:untrusted_tool_selection`, `:untrusted_request_transformer` | Keep authority and execution policy in trusted application configuration |
| `:untrusted_credentials`, `:untrusted_transport`, `:unsafe_retry_metadata` | Do not pass credentials, transport overrides or retry policy through untrusted arguments/request resources |
| `:native_identity_projection_required` | Preserve the bound catalog entry's native identity-only context projection |
| `:managed_context_requires_runtime` | Return a standalone Context without a runtime/coordinator binding |
| `{:permission_denied, capability}` | Grant the permission deliberately, or use an allowed operation |
| `:approval_required` | Your policy requested approval without a managed coordinator; use managed sessions or implement the approval decision in your own policy |

See the [API reference](../reference/api.md) and [configuration reference](../reference/configuration.md) for the broader public contracts.

## Limits

- Standalone tools and the plugin do not provide Oh-My-Jido's managed effect journal, recovery, approval conversation, Goal/Memory/Eval or subagent coordination. The plugin supports the bundled Actions above, not every Action in `Tools.default/0`.
- The provider's Context stays out of agent/plugin state, model request state, worker payloads and checkpoints. Public tool results, including file contents, can enter native state and model conversations. Your binding store and privileged application introspection remain trusted resources; private diagnostics are not encryption.
- Selection does not start language servers, debuggers, live targets or optional adapters. Configure their services separately.
- Cancellation does not undo edits or prove a process never ran. Reconcile an uncertain effect before attempting it again.
- Permissions and workspace checks are library policy, not an OS sandbox. Use [OS isolation](security.md) for untrusted work.

## Related

- [Concepts](../concepts.md)
- [Tools and custom Actions](tools.md)
- [Permissions and approvals](permissions-and-approvals.md)
- [Sessions and recovery](sessions-and-recovery.md)
- [Own-agent example](../../examples/jido_agent/README.md)
- [Managed plain Mix example](../../examples/plain_mix/README.md)
