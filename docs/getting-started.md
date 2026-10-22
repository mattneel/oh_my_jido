# Getting started

This tutorial takes you from a new Mix project to a coding agent that reads, edits and tests code under your application's control. Steps 1–4 need no model account. Step 5 onward needs a model API key; the examples use Anthropic.

This is the `jido-v3-preview` branch, which runs on the Jido 3.0 beta stack. For the stable Jido 2.4 stack, follow the guide on [`master`](https://github.com/mattneel/oh_my_jido/blob/master/docs/getting-started.md).

If you have not read it yet, [concepts](concepts.md) explains the terms used here: runtime, session, run, permissions and events.

## Before you start

- Elixir `~> 1.20`. Oh-My-Jido is tested with Elixir 1.20.2 on OTP 28.
- Tools that start OS processes (List, Search, Shell, Git, Claude Code, language servers, debuggers, MCP servers and Eval) need Linux with `setsid` and `/proc`. The managed process runner also needs `sh`, `mkfifo`, `cat` and `kill`. Elsewhere these tools fail closed with `{:capability_unavailable, :linux_process_groups}`, `:protocol_platform_unavailable` or `{:backend_unavailable, …}`. Other operating systems are untested; Read, Write, Edit, AST, Observer and the model loop do not start OS processes.
- `rg` ([ripgrep](https://github.com/BurntSushi/ripgrep)) for the list and search tools, and `git` for the Git tools.
- For step 5: an API key for a model provider supported by [ReqLLM](https://github.com/agentjido/req_llm), such as Anthropic.

## 1. Create a project

Use an existing application or create a new one with a supervision tree:

```sh
mix new my_app --sup
cd my_app
```

## 2. Add Oh-My-Jido

Oh-My-Jido is not on Hex yet. Install it from GitHub, or from a local checkout if you work on the library itself.

### From GitHub

```elixir
# mix.exs
defp deps do
  omj = [github: "mattneel/oh_my_jido", branch: "jido-v3-preview"]

  [
    {:oh_my_jido, omj},
    {:jido, omj ++ [sparse: "vendor/jido", override: true]},
    {:jido_ai, omj ++ [sparse: "vendor/jido_ai", override: true]},
    {:jido_action, omj ++ [sparse: "vendor/jido_action", override: true]},
    {:req_llm, omj ++ [sparse: "vendor/req_llm", override: true]},
    {:jido_signal,
     git: "https://github.com/agentjido/jido_signal.git",
     ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
     override: true},
    {:zoi,
     git: "https://github.com/mikehostetler/zoi.git",
     ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
     override: true}
  ]
end
```

```sh
mix deps.get
mix compile
```

The first five entries come from the same repository branch. Update them together with `mix deps.update oh_my_jido jido jido_ai jido_action req_llm` so they stay on the same commit.

### Why the overrides

The preview ships patched snapshots of Jido 3.0.0-beta.1, Jido.Action 3.0.0-beta.12, Jido.AI (native Jido 3 support; its upstream version metadata still reads 2.3.0) and ReqLLM 1.28.0 in `vendor/`. The patches keep credentials and private request data out of crash reports, status reports and HTTP error diagnostics. Stock packages do not have these boundaries, so the snapshots must override them in your dependency graph. Jido.Signal and Zoi are pinned to the exact revisions those snapshots require. See [security](guides/security.md#keep-the-bundled-patched-dependencies) for what the patches cover.

### From a local checkout

Point path dependencies at a clone of this branch:

```elixir
defp deps do
  root = "/path/to/oh_my_jido"

  vendored =
    for app <- [:jido, :jido_ai, :jido_action, :req_llm] do
      {app, path: Path.join([root, "vendor", Atom.to_string(app)]), override: true}
    end

  [
    {:oh_my_jido, path: root},
    {:jido_signal,
     git: "https://github.com/agentjido/jido_signal.git",
     ref: "fd8d00555d6a64b4109619f4c26f1b75e8a91d41",
     override: true},
    {:zoi,
     git: "https://github.com/mikehostetler/zoi.git",
     ref: "2fff2a23e23e7ac0b26f62f49bbc1b12f7818ac9",
     override: true}
  ] ++ vendored
end
```

Or let the bundled installer edit your `mix.exs`. Run it from your project directory before `mix deps.get`; it previews the change first and only writes with `--apply --yes`:

```sh
elixir /path/to/oh_my_jido/priv/oh_my_jido/install.exs --dry-run
elixir /path/to/oh_my_jido/priv/oh_my_jido/install.exs --apply --yes
mix deps.get
```

The installer adds the path dependencies, the overrides and the Jido.Signal and Zoi pins. It only edits `mix.exs`, does not evaluate your configuration, and refuses layouts it cannot edit safely. Add `--snakepit` to both commands only if you plan to use Python Eval.

## 3. Start a runtime

A **runtime** is a named Oh-My-Jido instance in your supervision tree. Add one to your application:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {OhMyJido, name: MyApp.Coding}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

Starting the runtime opens no session, starts no external service and makes no model request.

## 4. Call a tool

Start IEx with `iex -S mix`. A **session** is one agent bound to one existing workspace directory. It starts with no permissions; grant only what the task needs:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: File.cwd!(),
    permissions: [:read]
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
IO.puts(file.content)
```

`file` also contains `bytes`, `encoding`, line information and `snapshot`: the SHA-256 of the whole file. The write and edit tools require that snapshot, so the agent can only change a file it has seen in its current state.

A tool without its permission fails before it does anything:

```elixir
OhMyJido.execute_tool(session, "write", %{path: "notes.txt", content: "hi", snapshot: "missing"})
#=> {:error, %Jido.Action.Error.ExecutionFailureError{details: %{reason: {:permission_denied, :edit}, ...}, ...}}
```

Paths outside the workspace fail the same way with `reason: :outside_workspace`.

`execute_tool/4` is the same path the agent uses: it checks permissions and your policy, runs the Jido Action, and records the call in the session's effect journal.

## 5. Connect a model

Model credentials come from your code. Write a **credentials resolver**: a module with `resolve(context, account, options)`. It receives the session's *account*, an opaque name your application chooses, and returns ReqLLM options for that account. Put it in your application, for example `lib/my_app/model_credentials.ex`:

```elixir
defmodule MyApp.ModelCredentials do
  def resolve(_context, "anthropic", _options) do
    {:ok, [api_key: System.fetch_env!("ANTHROPIC_API_KEY")]}
  end

  def resolve(_context, _account, _options), do: {:error, :unknown_account}
end
```

Pass it to the runtime in `lib/my_app/application.ex`:

```elixir
children = [
  {OhMyJido, name: MyApp.Coding, credentials: {MyApp.ModelCredentials, []}}
]
```

The runtime checks at startup that the module exports `resolve/3`, so define the module in a file rather than pasting it into IEx. Oh-My-Jido calls the resolver before every model request. It never reads environment variables or credential files itself; the example reads `ANTHROPIC_API_KEY` only because the resolver chooses to.

Restart `iex -S mix`. Open a session with a model and an account, submit a task with `prompt/3`, and wait for it with `await/3`:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: File.cwd!(),
    permissions: [:read],
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic"
  )

{:ok, run_id} = OhMyJido.prompt(session, "How are this project's tests organized?")
{:ok, result} = OhMyJido.await(session, run_id, timeout: 120_000)
IO.puts(result.answer)
```

`prompt/3` returns a run ID as soon as the session accepts the task. Later problems, such as a rejected API key, appear in the result of `await/3`. That result is the run record: `status`, `answer`, `usage`, the tool calls made, and `error` if it failed. A timeout in `await/3` only stops waiting; the run continues.

If you omit `model:`, this branch uses built-in defaults: Claude Sonnet 4.6 for the coding, planning, review and advisor roles, and Claude Haiku 4.5 for exploration and compaction. The account still has to be able to pay for the selected model. [Models and accounts](guides/models-and-accounts.md) covers roles, configuration and other providers.

## 6. Follow progress with events

A subscribed process receives `{:oh_my_jido, %OhMyJido.Event{}}` messages. Each event has a `kind`, a `payload`, the `run_id` and an increasing `seq`. This helper runs one task from IEx, prints the model's output as it streams, and asks you on the console whenever the agent needs an approval. Paste it into IEx, or add it as `lib/my_app/console.ex` and run `recompile()` in IEx:

```elixir
defmodule MyApp.Console do
  def run(session, task) do
    :ok = OhMyJido.subscribe(session, self())
    {:ok, run_id} = OhMyJido.prompt(session, task)
    follow(session, run_id)
  end

  defp follow(session, run_id) do
    receive do
      {:oh_my_jido, %OhMyJido.Event{kind: :llm_delta, payload: %{delta: text}}} when is_binary(text) ->
        IO.write(text)
        follow(session, run_id)

      {:oh_my_jido, %OhMyJido.Event{kind: :tool_started, payload: payload}} ->
        IO.puts("\n[tool] #{payload.tool_name}")
        follow(session, run_id)

      {:oh_my_jido, %OhMyJido.Event{kind: :approval_requested, payload: %{id: id, question: question}}} ->
        reply = IO.gets("\nApprove #{inspect(question)}? [y/N] ")
        OhMyJido.answer(session, id, if(String.trim(reply) == "y", do: :approve, else: :deny))
        follow(session, run_id)

      {:oh_my_jido, %OhMyJido.Event{kind: :run_completed, run_id: ^run_id}} ->
        OhMyJido.await(session, run_id)

      {:oh_my_jido, _event} ->
        follow(session, run_id)
    end
  end
end
```

In IEx, with the session from step 5:

```elixir
MyApp.Console.run(session, "Summarize what this project does.")
```

Subscribe before you submit, so you do not miss early events. In a real application, handle events in a GenServer or LiveView and keep the process that answers questions separate from any process blocked in `await/3`. [Running tasks](guides/running-tasks.md) shows that pattern and lists every event kind.

## 7. Let the agent change code

Grant more only when the task needs it. This session can read, write and edit files and run commands. `bundles:` limits which tools are available; permissions decide what those tools may do:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/a/disposable/checkout",
    bundles: [:read_only, :editing, :process],
    permissions: [:read, :edit, :exec],
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic"
  )

MyApp.Console.run(session, "Run mix test. If a test fails, fix the code and run the tests again.")
```

Try this on a checkout you can reset. Things to know before granting `:exec`:

- The default policy, `OhMyJido.Host.Local`, asks for approval before **sensitive** actions such as Git commits, applying a rename, MCP tool calls and browser actions. It does not ask before every shell command: with `:exec`, the agent can run any executable in the workspace as your OS user. To review each command, use a stricter policy; [permissions and approvals](guides/permissions-and-approvals.md#write-a-stricter-host-policy) has a complete example.
- Only `:approve`, `true` or `"approve"` approve an action. Any other answer denies it.
- By default a command may run for 30 seconds (`tool_timeout_ms`) and a whole task for 5 minutes (`run_timeout_ms`). Waiting for your approval does not use a command's 30 seconds: an approval or answer can wait up to 5 minutes (`question_timeout_ms`), although that wait still counts toward the task's 5 minutes. A first `mix test` that compiles dependencies can take longer than 30 seconds. Compile the project yourself first (`mix deps.get` and `MIX_ENV=test mix compile`), or raise the limit on the runtime, for example `tool_timeout_ms: 120_000`. Cancelling a task can wait up to `tool_timeout_ms` for a running call before the agent is stopped, so keep the limit no higher than your commands need.
- Permissions are not an OS sandbox. Run untrusted repositories inside a container or as a separate OS user; see [security](guides/security.md).
- A model's final answer is not proof of success. Check the tool results in the run record, or run the tests yourself.

## 8. Keep sessions across restarts

By default, sessions are stored in ETS and disappear when the VM stops. Configure file storage in a private directory outside any workspace. The directory must be writable by the user running your application, and only one BEAM instance may own it:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   credentials: {MyApp.ModelCredentials, []},
   storage: {Jido.Persistence.File, path: Path.expand("~/.local/share/my_app/coding_sessions")}}
]
```

In production, use a dedicated directory created for your application's OS user; see [operations](operations.md#choose-storage-and-back-it-up).

Restart `iex -S mix` and open a session as in step 5. Save its ID (for example in your database), checkpoint when the session is idle, and restore it later, even after restarting the application:

```elixir
session_id = session.id
:ok = OhMyJido.checkpoint(session)
:ok = OhMyJido.stop_session(session)

# Later, with the same runtime name and storage:
{:ok, session} = OhMyJido.resume_session(MyApp.Coding, session_id)
```

Restoring brings back the conversation, workspace, permissions and the effect journal. It never re-runs work. If a crash interrupted a tool call, that call is marked `:uncertain`, and you decide what to do after checking the real state. Checkpoints written by the `master` branch are not converted automatically. [Sessions and recovery](guides/sessions-and-recovery.md) explains the details.

## Troubleshooting

| You see | Cause | Fix |
|---|---|---|
| `start_session/2` returns `{:error, :enoent}` | The workspace directory does not exist | Create it first; Oh-My-Jido never creates workspaces |
| `{:error, {:unknown_tool, "name"}}` | The tool is not available in this session | Check `bundles:` or `tools:` for the session |
| A tool error with `reason: {:permission_denied, cap}` | The session lacks that permission | Add `cap` to `permissions:` if the task needs it |
| A tool error with `{:capability_unavailable, :linux_process_groups}` | The tool starts a process and you are not on Linux | Run on Linux, for example in a container |
| `await/3` returns `{:error, %{status: :failed, error: {:request_transformer, :account_required}}}` | The session has no account | Pass `account:` to `start_session/2` or `prompt/3` |
| The same shape with `:explicit_credentials_required` | The resolver returned no usable credential | Return `{:ok, [api_key: key]}` with a non-empty key |
| The same shape with `:credential_service_failed` | The resolver raised, or returned an error that is neither an atom nor an `OhMyJido.Auth.Error` | Return `{:error, atom}` for refusals; your atom is passed through |
| A command result with `status: :timed_out` | The command reached the 30-second `tool_timeout_ms` limit | Compile slow projects beforehand, or raise `tool_timeout_ms` |
| A tool call fails with a timeout error | The call reached its limit of `tool_timeout_ms` plus `question_timeout_ms` | Raise `tool_timeout_ms` for slow tools (an experiment trial uses its own `timeout`); make custom Actions bound their own work |
| A question or approval fails with `:approval_timeout` | Nobody answered within `question_timeout_ms` (5 minutes by default) | Answer sooner, or raise `question_timeout_ms` |
| A run ends with `status: :timed_out` | The 5-minute task limit, which includes time spent waiting for answers | Raise `run_timeout_ms` |
| `warning: Using unverified model` | The model ID is not in ReqLLM's catalog, often a typo | Check the model string; the request is still sent |
| `Jido.AI.Reasoning.ReAct using ephemeral token secret` | Jido.AI's own continuation tokens have no configured secret | Harmless for Oh-My-Jido: sessions restore from their own checkpoints |
| `{:error, :busy}` from `prompt/3` | A run is already active in this session | Wait for it, or use another session |
| `{:error, {:capacity, kind}}` | A runtime limit is full; work is refused, not queued | Retry later or raise the limit; see [configuration](reference/configuration.md) |
| List or search fails with an executable error | `rg` is not installed | Install ripgrep |

## Next steps

- [Concepts](concepts.md): how runtimes, sessions, runs, permissions and the journal fit together.
- [Running tasks](guides/running-tasks.md): events in a GenServer or LiveView, steering, cancelling, questions and goals.
- [Tools](guides/tools.md): the full tool catalog and how to add your own Jido Actions.
- [Models and accounts](guides/models-and-accounts.md): model roles, other providers, OpenAI sign-in and Claude Code.
- [Examples](../README.md#examples): complete applications that use these APIs.
