# Run and restore sessions

Use a managed runtime when your application needs supervised coding agents, saved context, events and recovery. A runtime is a named supervisor. A session binds one agent to a workspace and permissions. A run is one task submitted to that session.

## Supervise a runtime

Add a runtime to your application's child list. Choose file-backed storage when sessions must survive an application restart:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   storage: {Jido.Persistence.File, path: "/srv/my_app/coding-sessions"}}
]
```

The directory is private application data, not a public document store. The default ETS storage survives a session worker restart, but not the lifetime of the application. File storage is not encrypted. A runtime starts no default session, model request or optional language service.

Open a session with an explicit workspace and permissions. Before an AI task, configure your credentials resolver and select a model/account as shown in [Getting started](/docs/getting-started).

## Run work and handle events

```elixir
:ok = OhMyJido.subscribe(session, self())
{:ok, run_id} = OhMyJido.prompt(session, "Explain the test setup.")
result = OhMyJido.await(session, run_id, timeout: 60_000)
```

Subscribe before prompting. Events arrive as `{:oh_my_jido, %OhMyJido.Event{}}`. Keep the session reference and run ID; neither a browser connection nor a caller waiting for a result owns the run's lifetime.

| Operation | What it does |
|---|---|
| `subscribe(session, pid)` | Sends ordered, bounded events to your subscriber. |
| `events(session, after: sequence)` | Reads the retained event buffer after a sequence number. It is not an unlimited history. |
| `answer(session, question_id, value)` | Answers one clarification or approval request. |
| `steer(session, run_id, text)` | Queues guidance for the active run. |
| `cancel(session, run_id)` | Requests cancellation and prevents new effects for that run. It does not undo earlier writes. |
| `suspend(session, run_id)` | Requests a suspended state. `resume(session)` allows a new context-aware task; it does not replay the interrupted one. |
| `await(session, run_id, timeout: milliseconds)` | Waits for a terminal result. A caller timeout does not cancel work. |

Process and Eval streaming output use public event kind `:tool_output`, with `:stream` and `:text` payload fields; Eval also includes `:execution_id`. Slow subscribers can be detached at their configured bound. Store the events your application needs independently of the runtime buffer.

## Save and restore context

Finish active work and direct tool calls before checkpointing. With the file-backed runtime above:

```elixir
:ok = OhMyJido.checkpoint(session)
:ok = OhMyJido.stop_session(session)
{:ok, restored} = OhMyJido.resume_session(MyApp.Coding, session.id)
```

After a restart, supervise the same runtime name with the same durable storage, then call `resume_session/2` with the saved session ID. Explicit checkpointing rejects active model runs. `stop_session/1` stops accepting new work and confirms that tracked execution and resources stopped before terminating the session; successful shutdown does not roll back previous effects.

## Recovery is not replay

The effect journal records tool calls and their outcomes. An effect interrupted by a crash becomes `:uncertain`: the lost response does not tell you whether the command, edit or external request happened. Recovery restores context without automatically repeating the effect or model turn.

If cleanup cannot be confirmed, keep the session closed to new work and reconcile its actual resources and external state. A process exit alone does not confirm cleanup. Operator reconciliation is a trusted application operation, not an agent tool or browser control; see the full [sessions and recovery guide](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/guides/sessions-and-recovery.md).

The [docs studio](/docs/studio) saves its application-facing run history separately from session checkpoints. Reopening its browser reconnects to work; restarting the editor does not silently repeat it.

## Related

- [Getting started](/docs/getting-started)
- [Tools and safety](/docs/tools)
- [Runtime configuration](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/reference/configuration.md)
- [Running tasks](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/guides/running-tasks.md)
