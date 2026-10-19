# Plain Mix embedded host

This is an independent Mix application, not a CLI. `PlainMixHost.Application`
places the public `{OhMyJido, options}` child beneath ordinary OTP supervision. No session or model
request starts automatically. The runtime has no credentials by default and
production scripted-model execution remains disabled.

## Independent commands

From this directory, provision this consumer's own dependency sources first:

```sh
MIX_ENV=test mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix format
MIX_ENV=test mix test
```

The previous independent run passed warnings-as-errors compilation, formatter
validation and both real host scenarios; current usability checks are tracked in
[PROGRESS](../../docs/oh-my-jido/PROGRESS.md). `deps/`, `_build/` and `mix.lock` belong
to this project; dependency resolution cannot replace the root project's sources.
The library and its licensed Jido/ReqLLM snapshots use explicit canonical path
overrides. No nested `Mix.Project.in_project` or optional QuickBEAM/Snakepit
selection is needed. An offline `deps.get --check-locked` requires those exact
Hex packages to have been cached first; it is not an installer substitute.

The network-free tests drive the installed Jido.AI ReAct script API, but execute
real read/edit/process Actions: they repair a disposable Mix project and run its
actual test suite. They inspect typed progress/output events, exercise explicit
answers, steering, cancellation and suspension, restart the host supervision
tree, and restore the conversation from `Jido.Storage.File`. Only test-owned
runtimes set `allow_test_scripts: true`.

## Host-owned credentials and storage

Configure the host before starting its application. For an account broker the
host already supervises, a valid configuration is:

```elixir
config :plain_mix_host, :coding,
  storage_path: "/srv/my_app/coding_sessions",
  credentials: {OhMyJido.Auth, broker: MyApp.AccountBroker}
```

Alternatively supply a host module implementing
`resolve(%OhMyJido.Context{}, opaque_account, options)`, returning explicit
ReqLLM options. The broker/provider owns authorized account enrollment and token
renewal. This example imports neither credential files nor environment API keys,
and it does not obtain a provider account or select a different billing source.

The host forwards this explicit `credentials:` shortcut to the default local Runtime host; startup does not invoke the resolver. `PlainMixHost.open/2` composes `:read_only`, `:editing` and `:process` bundles plus the managed Question Action, while grants remain explicit. Git availability does not grant `:git`. For a narrower host, pass an explicit replacement `tools:` list when opening a session; no bundle or service starts an agent loop at configuration time.

## Embed a task and consume events

With a host-supplied authorized account:

```elixir
{:ok, session} = PlainMixHost.open("/srv/projects/my_project",
  account: "opaque-account-reference", role: :coding)
:ok = OhMyJido.subscribe(session, self())
{:ok, run} = PlainMixHost.submit(session,
  "Repair the failing increment test. Preserve the public API and run the suite.")

receive do
  {:oh_my_jido, %OhMyJido.Event{} = event} -> IO.inspect(event)
end

:ok = OhMyJido.steer(session, run, "Do not change the label API")
# For a still-running task, the operator can instead suspend or cancel:
# OhMyJido.suspend(session, run)
# OhMyJido.cancel(session, run)
result = OhMyJido.await(session, run, timeout: 60_000)
```

The workspace is explicit; no operation changes the host VM cwd or environment.
The granted shell capability is not an OS sandbox. Local-host sensitive effects
emit `:approval_requested`; the host UI uses `OhMyJido.answer/3` with the event's
question ID after a human decision. A suspended session uses `OhMyJido.resume/1`
before a new task. Cancellation/suspension returns an error terminal record,
not a fabricated successful answer or an assertion that prior effects vanished.

## Durable restore

After a task is idle:

```elixir
:ok = OhMyJido.checkpoint(session)
:ok = OhMyJido.stop_session(session)
# The same storage path and runtime name must be configured after host restart.
{:ok, restored} = PlainMixHost.restore(session.id)
{:ok, state} = OhMyJido.inspect_session(restored)
```

`session.id` is durable; agent/coordinator PIDs are not. Restoration does not
replay interrupted effects. The tests are host-level scripted evidence, not a
live provider demonstration or a claim of Elixos generation promotion/fallback.
