# Embed a coding agent in a plain Mix application

This example shows how to supervise Oh-My-Jido in an ordinary OTP application, run coding tasks, handle events and restore a session after a restart. You do not need Phoenix or a command-line agent. Jido provides the agent lifecycle, and Jido.AI runs the model-and-tool loop.

Starting `PlainMixHost.Application` starts a named runtime, not a session or model request. You can try a Read without credentials. The test walkthrough uses a scripted model but real file and process tools.

## Run the example

Use Elixir `~> 1.20`. The repair walkthrough needs Linux, `mix` on `PATH`, and the process utilities listed in [Operations](../../docs/operations.md). Search/List tools need ripgrep; Git tools need Git. No API key, optional Eval backend or installed Igniter application is needed for the tests.

From the repository root:

```sh
cd examples/plain_mix
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
```

The tests create a disposable Mix project, read and repair its source, run that project's test suite, handle questions and run controls, then restore a saved conversation after restarting the supervision tree. They use Jido.AI's test script API, so no paid model request is involved. Only the test-owned runtime enables `allow_test_scripts: true`.

This is a separate Mix consumer: its `deps/`, `_build/` and `mix.lock` belong to the example. Its `mix.exs` uses the checkout as a path dependency and keeps the supplied Jido/ReqLLM diagnostic snapshots as top-level overrides. It does not load the repository's application configuration. `mix deps.get --check-locked` can only work offline after the exact dependencies have been cached; it does not install them.

## Read a file without a model

From the example directory, start IEx:

```sh
MIX_ENV=test iex -S mix
```

Then run:

```elixir
# From examples/plain_mix, this is the Oh-My-Jido checkout.
workspace = Path.expand("../..")

{:ok, session} =
  PlainMixHost.open(workspace,
    permissions: [:read],
    tools: OhMyJido.Tools.select!(:read_only)
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
IO.puts(file.content)
:ok = OhMyJido.stop_session(session)
```

Replace `workspace` with your project's existing directory to read that project. This call uses the managed runtime, permission checks and effect journal even though no model is involved. `file.snapshot` covers the complete file and can guard a later edit.

## Walk through the files

| File | What to learn |
|---|---|
| [`mix.exs`](mix.exs) | Independent consumer dependencies, including the required source overrides |
| [`lib/plain_mix_host.ex`](lib/plain_mix_host.ex), `PlainMixHost.Application` | Reads `:plain_mix_host, :coding` configuration and places the runtime under application supervision |
| Same file, `PlainMixHost.Supervisor` | Adds the public `{OhMyJido, options}` child and configures `Jido.Storage.File` |
| Same file, `PlainMixHost` | `open/2` selects workspace, permissions and tools; `submit/3` calls `OhMyJido.prompt/3`; `restore/2` calls `OhMyJido.resume_session/2` |
| [`test/minimal_runtime_test.exs`](test/minimal_runtime_test.exs) | A credential-free Read with no inherited model configuration |
| [`test/embedded_host_test.exs`](test/embedded_host_test.exs) | A read/edit/test workflow, typed events, questions, steering, cancellation, suspension and restore across a runtime restart |

The wrapper intentionally gives new sessions more than the library's empty permission default:

| Setting | Example default | How to change it |
|---|---|---|
| Runtime name | `PlainMixHost.Coding` | Set `runtime:` in application configuration and pass the same name to `open/2` and `restore/2` |
| Storage | `{Jido.Storage.File, path: Path.expand("var/sessions")}` | Set `storage_path:` before application startup; use an application-owned durable directory |
| Credentials | None | Set `credentials: {YourResolver, options}` before application startup |
| Available tools | `:read_only`, `:editing`, `:process`, plus `OhMyJido.Tools.Question` | Pass an explicit replacement `tools:` list to `open/2` |
| Permissions | `[:read, :edit, :exec, :ask]` | Pass `permissions:` to `open/2`; the Read example narrows them to `[:read]` |
| Runtime controls forwarded by the supervisor | `credentials:`, `max_sessions:`, `max_active:`, `allow_test_scripts:` when supplied | Configure them under `:plain_mix_host, :coding` |

Git is available through `:process`, but the wrapper does not grant `:git`. This wrapper already supplies `tools:`, so narrow its selection with `tools:`, not an additional `bundles:` option. Supplying both is a configuration error.

## Adapt it to your application

### Choose storage and credentials

Reuse the supervision pattern, but choose your own runtime name and storage directory. Follow [Getting started](../../docs/getting-started.md) for dependencies outside this checkout; do not copy its example-relative path into a deployed application.

For an application adapted from this example, configure the wrapper before it starts:

```elixir
import Config

config :plain_mix_host, :coding,
  storage_path: "/srv/my_app/coding_sessions",
  credentials: {MyApp.ModelCredentials, []}
```

Your resolver implements `resolve(context, account, options)` and returns explicit ReqLLM options. For example, this application-owned module deliberately reads an API key for one account:

```elixir
defmodule MyApp.ModelCredentials do
  def resolve(_context, "anthropic", _options) do
    {:ok, [api_key: System.fetch_env!("ANTHROPIC_API_KEY")]}
  end

  def resolve(_context, _account, _options), do: {:error, :unknown_account}
end
```

If you already supervise an authorized account broker, the alternative setting is `credentials: {OhMyJido.Auth, broker: MyApp.AccountBroker}`. The broker owns enrollment and token renewal. Startup does not call the resolver, and the example does not import credential files, read environment keys or switch billing sources on its own. See [Models and accounts](../../docs/guides/models-and-accounts.md) for resolver and broker configuration.

### Submit a model task and handle events

With your resolver and account configured:

```elixir
{:ok, session} =
  PlainMixHost.open("/path/to/project",
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic",
    role: :coding,
    permissions: [:read, :edit, :exec, :ask]
  )

:ok = OhMyJido.subscribe(session, self())

{:ok, run} =
  PlainMixHost.submit(session,
    "Repair the failing increment test. Preserve the public API and run the suite."
  )
```

On `master`, select an active model explicitly, as above, or configure `model_roles` on your runtime. The bare Jido 2.4 aliases can point to a retired model. This example supervisor does not forward `model_roles`, so extend its option list if you choose runtime-level role configuration.

Subscribers receive `{:oh_my_jido, %OhMyJido.Event{}}` messages. Keep your event-handling/UI process responsive while another process calls `OhMyJido.await(session, run, timeout: 60_000)`. A completed result matches `{:ok, %{status: :completed}}`; do not block the only process that can answer a question.

| Task | Call or event |
|---|---|
| Display streamed tool output | Handle an event with `kind: :tool_output` and payload `stream`/`text` |
| Display a question or approval | Handle `kind: :approval_requested`, taking the question ID from `event.payload.id` |
| Answer after a human decision | `OhMyJido.answer(session, question_id, answer)`; effect consent is only `true`, `:approve` or `"approve"` |
| Add a constraint while running | `OhMyJido.steer(session, run, "Do not change the label API")` |
| Suspend or cancel | `OhMyJido.suspend(session, run)` or `OhMyJido.cancel(session, run)` |
| Allow a new task after suspension | `OhMyJido.resume(session)` |

The default local policy requests approval for effects marked sensitive, not every shell command. Cancellation and suspension finish with error terminal records matching `{:error, %{status: :cancelled}}` or `{:error, %{status: :suspended}}`. They do not undo previous effects. Use [Running tasks](../../docs/guides/running-tasks.md) for a complete event/approval workflow.

### Restore a session

After a task is idle:

```elixir
:ok = OhMyJido.checkpoint(session)
:ok = OhMyJido.stop_session(session)

# After a restart, configure the same runtime name and storage directory.
{:ok, restored} = PlainMixHost.restore(session.id)
{:ok, state} = OhMyJido.inspect_session(restored)
```

Keep `session.id`, not agent/coordinator PIDs. Restoration reads `Jido.Storage.File` without replaying interrupted effects. See [Sessions and recovery](../../docs/guides/sessions-and-recovery.md) for uncertain effects and reconciliation.

## Limits

- This example is an OTP application, not a CLI or a ready-made approval UI. Your application supplies the user interface and account policy.
- File storage contains session data. Choose storage access controls and retention deliberately; see [Security](../../docs/guides/security.md).
- Tools use explicit workspaces and child-process environments; they do not change the application's VM working directory or environment. Permissions are not an OS sandbox.
- Optional language servers, debuggers, adapters and Eval backends are not installed or configured by these bundles.

## Related

- [Documentation home](../../docs/README.md)
- [Getting started](../../docs/getting-started.md)
- [Tools](../../docs/guides/tools.md)
- [Add tools to your own Jido agents](../../docs/guides/jido-agents.md)
- [Own-agent example](../jido_agent/README.md)
