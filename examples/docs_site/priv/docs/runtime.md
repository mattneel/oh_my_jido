# Managed runtime

Put `{OhMyJido, name: MyApp.Coding}` under your OTP supervisor. The application starts no default coding session.

## Durable sessions

```elixir
{OhMyJido,
 name: MyApp.Coding,
 storage: {Jido.Persistence.File, path: "/srv/my_app/sessions"}}
```

Open an explicit workspace and grants. Select a host-approved model/account and credential resolver before submitting an AI task; do not put provider keys into task text.

```elixir
{:ok, run} = OhMyJido.prompt(session, "Explain the test setup")
result = OhMyJido.await(session, run, timeout: 60_000)
```

Subscribe before prompting to receive `{:oh_my_jido, event}` messages. A host UI can answer structured questions and approval requests through `OhMyJido.answer/3`, steer an active run, or request cancellation/suspension.

## Recovery is not replay

Checkpoint an idle session and restore it using the same runtime name, durable storage and session ID. Interrupted or uncertain effects must be reconciled; a lost response is not proof that a command never ran.

The studio persists the host-facing run history separately from native checkpoints, so reloading the browser is not cancellation and restarting the editor does not silently repeat effects.
