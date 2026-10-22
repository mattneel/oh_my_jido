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

Install the dependencies described in [Getting started](../getting-started.md), including the supplied Jido and ReqLLM diagnostic patches. This page uses the `master` branch's Jido 2.4 declarations. The `jido-v3-preview` branch has a different agent DSL and return shapes; use its version of this guide with that branch.

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
    max_retries: 0
  )

IO.puts(file.content)
```

Read returns `{:ok, file_map}`. Failures return `{:error, reason}`; native validation/execution errors can be exception structs, not strings. Other Actions can also return `{:ok, result, effects}`. Keep `max_retries: 0` so a failed call cannot automatically repeat an effect.

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

A context provider maps an agent's module and ID to the workspace and permissions your application assigned it. The plugin calls `fetch_context/1` inside each coding Action, not when the agent is constructed. Do not take workspace, permissions, policy modules or service bindings from queries, signals or tool arguments.

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

Define the agent and select its available bundles:

```elixir
defmodule MyApp.Files do
  use Jido.Agent,
    name: "project_files",
    default_plugins: false,
    plugins: [
      {OhMyJido.Plugin,
       %{bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts}}
    ],
    schema: Zoi.object(%{project_label: Zoi.string() |> Zoi.default("my-project")})

  def private_diagnostics?, do: true
end
```

Keep `private_diagnostics?/0` returning `true` from startup. The plugin checks for the supplied native diagnostic patch; it does not change global diagnostic settings.

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

The agent's plugin makes Read and Edit available, but this particular binding only permits read-only tools. Both selections must allow an Action, and its required permission must be present.

### Run a tool without an AgentServer

`Plugin.cmd/3` accepts the original Action module or its exact tool name, such as `"read"`. It runs through your agent's native command handling:

```elixir
agent = MyApp.Files.new(id: "reader")

{updated, []} = OhMyJido.Plugin.cmd(agent, "read", %{path: "mix.exs"})
IO.puts(updated.state.content)
IO.puts(updated.state.project_label)
```

With Jido's Direct strategy, successful tool fields merge into top-level agent state. Your existing domain state remains unless it uses the same field names as the tool result. Keep those names distinct.

A preflight rejection returns `{:error, {:oh_my_jido_plugin, reason}}`. An Action failure instead appears in the native directives:

```elixir
unbound = MyApp.Files.new(id: "not-bound")

{_unchanged, [%Jido.Agent.Directive.Error{context: :instruction, error: error}]} =
  OhMyJido.Plugin.cmd(unbound, "read", %{path: "mix.exs"})

IO.inspect(error)
```

Here the error reports `:context_not_bound`. Inspect directives rather than treating every returned agent as success.

### Send a signal to a running agent

The plugin automatically adds routes named `oh_my_jido.<tool_name>` for the selected bundles:

```elixir
{:ok, pid} = Jido.start_agent(MyApp.Jido, MyApp.Files, id: "reader")

signal =
  Jido.Signal.new!("oh_my_jido.read", %{path: "mix.exs"}, source: "/my_app/files")

{:ok, updated} = Jido.AgentServer.call(pid, signal)
IO.puts(updated.state.content)
```

Examples include `oh_my_jido.read`, `oh_my_jido.search`, `oh_my_jido.write` and `oh_my_jido.edit`. These routes and `Plugin.cmd/3` disable effect retries. Do not bypass them with a retryable instruction. A native `AgentServer.call/3` reply of `{:ok, agent}` is not by itself proof that an Action succeeded: Direct instruction failures use error directives/signals.

## Add the plugin to a Jido.AI agent

Jido.AI uses a ReAct loop: the model chooses a tool, sees its result and continues. Keep your own model and domain tools; the plugin adds the selected coding tools to that loop.

```elixir
defmodule MyApp.Editor do
  use Jido.AI.Agent,
    name: "project_editor",
    model: "openai:gpt-4o-mini",
    tools: [],
    tool_max_retries: 0,
    max_iterations: 8,
    plugins: [
      {OhMyJido.Plugin,
       %{bundles: [:read_only, :editing], context_provider: MyApp.CodingContexts}}
    ]

  def private_diagnostics?, do: true
end
```

Put genuine domain Actions in `tools:`. Do not put unbound `OhMyJido.Tools.*` modules there: the plugin supplies bound Actions that look up context at execution time. `tool_max_retries: 0` is required. The plugin preserves your trusted request transformer and model policy; per-request tool selection can narrow the registry, never add Actions or authority.

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

For streaming, `MyApp.Editor.ask_stream/3` returns `{:ok, %{request: handle, events: enumerable}}`; consume the events and then await the handle. Native `cancel/2` and `steer/3` remain available. When finished with this standalone demonstration, call `Supervisor.stop(supervisor)`.

Let native APIs generate request IDs. If you supply them, each ID must be unique; reusing one does not create an independent request handle. Policy-rejected AI requests still enter native bounded request tracking, then fail before provider/tool execution. Await returns `{:error, {:failed, :error, {:request_transformer, reason}}}`; plugin policy rejections use `reason = {:rejected, :coding_tool_policy, message}`. Streams can include lifecycle/checkpoint events before terminal `:request_failed`, rather than one synthetic failure event.

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

Configuration and preflight errors use `{:oh_my_jido_plugin, reason}`; execution can wrap that reason in native error structs or directives. Match the machine-readable reason, not a human error string.

| Reason | What to change |
|---|---|
| `:context_not_bound` | Bind this exact agent module and ID before running a tool |
| `:context_provider_required`, `:context_provider_callback_required` | Configure a provider exporting `fetch_context/1` |
| `:private_diagnostics_required`, `:patched_jido_private_diagnostics_required` | Enable the callback and install the required Jido snapshot |
| `:tool_max_retries_must_be_zero` | Set `tool_max_retries: 0` |
| `:tool_not_available`, `:tool_not_available_in_host_context` | Select the tool in both the plugin and the trusted Context |
| `:unbound_or_conflicting_coding_tool` | Remove unbound coding Actions or conflicting tool names from the domain registry |
| `:untrusted_authority`, `:untrusted_tool_selection`, `:untrusted_request_transformer` | Keep authority and execution policy in trusted application configuration |
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
