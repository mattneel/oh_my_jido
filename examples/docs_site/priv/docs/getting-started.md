# Get started with Oh-My-Jido

Start with a credential-free file read. Then add a model and credentials resolver when you are ready to let an agent choose tools for a task.

## Before you start

Use Elixir `~> 1.20` and an existing project directory. Every tool that starts a subprocess needs Linux with `setsid` and `/proc`: List, Search, Shell, Git, language servers, debuggers, MCP servers and Eval. List/Search also need ripgrep (`rg`), and Git tools need `git`. On macOS and Windows, use only Read, Write, Edit and structural Elixir edits. The current tested baseline is Elixir 1.20.2 / OTP 28 on Linux x86_64.

Install from GitHub using the [V3 preview installation recipe](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/getting-started.md). Oh-My-Jido is not on Hex. Keep its branch selection, four vendored overrides (`jido`, `jido_ai`, `jido_action`, `req_llm`) and pinned `jido_signal`/`zoi` Git overrides. They select the supported Jido 3 SDK and its diagnostic protection. If you use a local checkout, follow that guide's path-dependency or installer instructions.

## Open a session and read a file

For an IEx experiment in an application with the dependency installed:

```elixir
{:ok, _runtime} = OhMyJido.start_link(name: MyApp.Coding)

{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: :read_only,
    permissions: [:read]
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

Replace `/path/to/project` with an existing project containing `mix.exs`. No model is involved. `file` contains the read result and its whole-file snapshot digest. In a real application, supervise `{OhMyJido, name: MyApp.Coding}` instead of starting it from IEx.

| Input | Meaning |
|---|---|
| `workspace:` | Existing directory this session can access. |
| `bundles: :read_only` | Registers Read, Search and List. A list of bundles is also accepted. |
| `permissions: [:read]` | Allows reading. Tool availability alone does not allow an operation. |
| `session` | A durable `%OhMyJido.SessionRef{runtime:, id:}` identifying the session. |

## Submit an AI task

Credentials come from your application for every model request. Save this resolver in your application's `lib/` directory, then restart `iex -S mix` before the next example:

```elixir
# lib/my_app/model_credentials.ex
defmodule MyApp.ModelCredentials do
  def resolve(_context, "anthropic", _options) do
    {:ok, [api_key: System.fetch_env!("ANTHROPIC_API_KEY")]}
  end

  def resolve(_context, _account, _options), do: {:error, :unknown_account}
end
```

Set `ANTHROPIC_API_KEY` in your trusted application's environment. That name is your resolver's choice; Oh-My-Jido does not discover keys from environment variables or credential files itself. Never put a key in a prompt or account reference.

Start a separate runtime for this example, then subscribe before submitting work:

```elixir
{:ok, _runtime} =
  OhMyJido.start_link(
    name: MyApp.AssistedCoding,
    credentials: {MyApp.ModelCredentials, []}
  )

{:ok, session} =
  OhMyJido.start_session(MyApp.AssistedCoding,
    workspace: "/path/to/project",
    bundles: :read_only,
    permissions: [:read],
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic"
  )

:ok = OhMyJido.subscribe(session, self())
{:ok, run_id} = OhMyJido.prompt(session, "Explain how the tests are organized.")
result = OhMyJido.await(session, run_id, timeout: 60_000)
```

Use an active model your provider account is authorized to pay for. The preview library supplies provider-qualified default models: Claude Sonnet 4.6 for coding, planning, review and advisor work; Claude Haiku 4.5 for exploration and compaction. Explicit `model:` or `model_roles` configuration can replace them. Recognition in the local catalog does not guarantee current provider availability.

Your subscriber receives `{:oh_my_jido, %OhMyJido.Event{}}` messages. A UI can display progress and answer questions or approval requests with `OhMyJido.answer/3`. An `await/3` timeout stops waiting; it does not cancel the run. Tool calls can fail even when the model finishes a turn, so inspect the actual result and tool events.

## Limits

- Starting a runtime alone opens no session and makes no model request.
- This session has only read tools and read permission. Add tools and permissions deliberately when you want it to edit or execute commands.
- In-memory storage does not survive an application restart. Choose durable storage before relying on recovery.

## Related

- [Runtime and sessions](/docs/runtime)
- [Tools and safety](/docs/tools)
- [Models and accounts](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/guides/models-and-accounts.md)
- [Complete API reference](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/reference/api.md)
