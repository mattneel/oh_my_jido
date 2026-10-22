# Evaluate persistent code cells

Use Eval when a coding task needs calculations, data processing or experiments that build on values from earlier code cells. Oh-My-Jido provides one `"eval"` tool for Elixir, JavaScript and Python. Each session gets a separate namespace for each enabled language; Eval does not run the agent loop or implement the other coding tools.

| Use | Choose |
|---|---|
| Keep language variables and reuse them in later cells | Eval |
| Run a command, build, test suite or repository script | [Shell](tools.md), with its separate `:exec` permission |
| Inspect a running application, or request approved live evaluation there | [Live application tools](live-applications.md), not Eval |
| Set breakpoints and step through code | [Debugger tools](language-intelligence.md) |

## Before you start

Install the library using [Getting started](../getting-started.md). Eval then needs all three of the following:

- A configured language backend. No language is enabled by default.
- The `OhMyJido.Tools.Eval` Action registered for the session. A Jido Action is a tool the agent can call. The full default tool registry includes Eval, but none of the named bundles does; an explicit `tools:` selection must include it.
- The `:eval` permission. Tools called from a cell also need their own registration, permissions and normal authorization.

The examples below use `isolation: :trusted`: you accept the code's access under the worker's operating-system identity. For untrusted code, provide the operating-system controls described in [Choose isolation](#choose-isolation).

## Enable Elixir

Add this child to your application's supervision tree:

```elixir
children = [
  {OhMyJido,
   name: MyApp.Coding,
   tools: [OhMyJido.Tools.Eval, OhMyJido.Tools.Read],
   eval: [
     max_kernels: 4,
     backends: %{elixir: [isolation: :trusted]}
   ]}
]
```

Elixir Eval needs no optional language package. Your deployment must provide a matching runnable Erlang/Elixir installation, the `erl` executable and Linux `setsid`. The worker uses the application's installed code paths. Oh-My-Jido does not install an ERTS, the Erlang runtime system, for you.

Runtime Eval settings belong under `eval:`. You can also set them at application startup with `config :oh_my_jido, eval: [...]`; a runtime child's `eval:` value replaces that application-level value. Eval limits are separate from the runtime's other limits.

### Run two cells in the same namespace

After your supervisor has started:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:eval, :read]
  )

{:ok, first} =
  OhMyJido.execute_tool(session, "eval", %{
    language: "elixir",
    source: "value = 40"
  })

{:ok, second} =
  OhMyJido.execute_tool(session, "eval", %{
    language: "elixir",
    source: "value + 2",
    timeout: 5_000,
    output_limit: 4_096
  })
```

The first execution opens the kernel, meaning the worker and its retained language state. The second cell reuses `value`; its `display` is `"42"`. You do not need model credentials to call a tool directly.

Successful Elixir cells retain their bindings and `Macro.Env`. JavaScript retains its engine context; Python retains its namespace. A language error is not a transaction rollback: JavaScript and Python can change values before raising, and any language can make earlier tool or OS effects. Elixir commits new bindings and evaluation environment only on success, but module loading and other effects in its child VM can still have happened.

## Add JavaScript

1. Add QuickBEAM before compiling Oh-My-Jido, alongside the library dependencies and overrides from Getting started:

   ```elixir
   {:quickbeam, "~> 0.11", runtime: false}
   ```

2. Resolve and compile your dependencies with `mix deps.get` and `mix compile`. If Oh-My-Jido was already compiled without QuickBEAM, recompile it with `mix deps.compile oh_my_jido --force`. The QuickBEAM integration is selected at compile time; a missing package produces an unavailable-backend error, not an installer or fallback engine.
3. Add `javascript: [isolation: :trusted]` to the runtime's backend map. To keep Elixir as well, use:

   ```elixir
   {OhMyJido,
    name: MyApp.Coding,
    tools: [OhMyJido.Tools.Eval, OhMyJido.Tools.Read],
    eval: [
      backends: %{
        elixir: [isolation: :trusted],
        javascript: [isolation: :trusted]
      }
    ]}
   ```

JavaScript uses persistent QuickBEAM inside a separate ERTS, never in your application's VM. It has the same `erl`, `setsid` and isolation-launcher requirements as Elixir. For example, execute `"globalThis.total = 40"` and then `"total + 2"` with `language: "javascript"`.

QuickBEAM 0.11.3 publishes Linux x86-64/ARM64 precompiled artifacts for glibc and musl. Source builds require Zig 0.16; `QUICKBEAM_BUILD=1` with `QUICKBEAM_CPU=baseline` selects a portable source build. You must provide a compatible compiled artifact or source-build environment. That package compatibility list is not Oh-My-Jido's supported-platform claim; see [Project status](../project-status.md).

## Add Python

Each Python session keeps its own worker. If that worker dies, the next cell fails instead of silently starting with empty state. See the [worker identity reference](#python-worker-identity) for how replacement is detected. SnakeBridge is optional for a separately chosen typed Python-library binding; Eval does not require it or generate bindings.

### 1. Select the vendored Snakepit dependency

QuickBEAM 0.11 and Snakepit 0.14 are optional dependencies with `runtime: false`. For Python, select Oh-My-Jido's vendored Snakepit 0.14.0 snapshot before compiling, not the stock Hex package:

```elixir
{:snakepit,
 github: "mattneel/oh_my_jido",
 sparse: "vendor/snakepit",
 override: true,
 runtime: false}
```

Keep the base library overrides from Getting started. For a local checkout, the equivalent dependency is `{:snakepit, path: Path.join(root, "vendor/snakepit"), override: true, runtime: false}`, where `root` is your approved Oh-My-Jido checkout. The snapshot retains Snakepit's MIT license.

The adapter requires `Snakepit.GRPCWorker.private_diagnostics_version()` to return `1`. Stock Snakepit 0.14 lacks that boundary; Python fails with `{:backend_unavailable, :python, :snakepit_private_diagnostics_unavailable}` rather than disabling privacy protections. Resolve and compile the selected dependency before Oh-My-Jido; if necessary, use `mix deps.compile oh_my_jido --force` after adding it.

### 2. Provision and configure Python

Provision a Python executable and the packages in [Snakepit's requirements file](../../vendor/snakepit/priv/python/requirements.txt). The generated stubs require `grpcio >= 1.84.0`, `grpcio-tools >= 1.84.0` and `protobuf >= 7.35.1`, as well as that file's other dependencies. Package downloads, compiled Python wheels and target compatibility are your application's deployment responsibility. Eval does not install Python, resolve packages or start a substitute process manager.

Set these values once, before starting Snakepit's infrastructure, for example in `config/runtime.exs`:

```elixir
import Config

config :snakepit,
  python_executable: "/srv/my_app/python/bin/python",
  python: [strategy: :system, managed: false],
  grpc_listener: %{mode: :internal},
  instance_name: "my_app",
  instance_token: System.fetch_env!("MY_APP_RUNTIME_INSTANCE"),
  data_dir: System.fetch_env!("MY_APP_SNAKEPIT_DATA_DIR")
```

The executable must already exist; it may be an approved compatible isolation wrapper. `:python_executable` takes precedence over `SNAKEPIT_PYTHON`. Do not change VM-global configuration or environment variables for each session.

Use a nonsecret runtime identity for `instance_token`, not a provider credential. Concurrent application VMs need distinct instance identities and separate owned data directories. Snakepit's stale-worker cleanup uses that identity to recognize its workers; sharing it can make another live VM's workers look like leftovers. Configure one Snakepit instance per application VM, not one per coding session.

### 3. Supervise Snakepit's infrastructure once

Installed Python packages are not a running Snakepit service. In your application's startup callback, start the gRPC applications and supervise Snakepit's components before accepting cells:

```elixir
def start(_type, _args) do
  {:ok, _} = Application.ensure_all_started(:grpc_server)
  {:ok, _} = Application.ensure_all_started(:grpc)

  children = [
    {Task.Supervisor, name: Snakepit.TaskSupervisor},
    {Snakepit.Bridge.SessionStore, []},
    {Snakepit.Bridge.ToolRegistry, []},
    {Snakepit.Pool.Registry, []},
    {Snakepit.Pool.ProcessRegistry, []},
    {Snakepit.ETSOwner, []},
    {Snakepit.GRPC.Listener, []},
    {Snakepit.Pool.Worker.StarterRegistry, []},
    {Snakepit.WorkerProfile.Thread.CapacityStore, []},
    {Snakepit.Pool.WorkerSupervisor, []},
    {Snakepit.Worker.LifecycleManager, []},
    {OhMyJido,
     name: MyApp.Coding,
     tools: [OhMyJido.Tools.Eval, OhMyJido.Tools.Read],
     eval: [backends: %{python: [isolation: :trusted]}]}
  ]

  {:ok, supervisor} =
    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)

  {:ok, _listener} = Snakepit.GRPC.Listener.await_ready()
  {:ok, supervisor}
end
```

Merge these children into your existing supervision tree; do not duplicate components that your application already owns. Keep the internal gRPC listener private to its intended workers. The adapter checks the registered Snakepit services, including gRPC client infrastructure and Ranch. Missing infrastructure returns `{:error, {:backend_unavailable, :python, :snakepit_runtime_not_started}}`.

Do not start the Snakepit application per session. Its startup changes VM-global environment variables, and its pool bootstrap can install or upgrade packages in development/test. Oh-My-Jido keeps Snakepit `runtime: false` and does not run that installer. Snakepit's executable and infrastructure configuration remains application-wide even if you supervise several coding runtimes with separate Eval managers.

You can now run `"value = 40"` followed by `"value + 2"` with `language: "python"` in a session with `:eval`. Python captures print/stderr and displays the final expression. The adapter sets its module, `PYTHONPATH` and private ownership token in the worker configuration, not the application's environment. It cleans up owned workers and Snakepit tool/session registrations on timeout, reset and teardown.

Python integration checks are opt-in with `OH_MY_JIDO_PYTHON_EVAL=1` and the same approved, preprovisioned executable; ordinary test runs skip that suite. See [Operations](../operations.md) and [Project status](../project-status.md) for compatibility and verification guidance.

## Call registered tools from a cell

The injected APIs call the same registered tools that the session can use outside Eval. For example, with `OhMyJido.Tools.Read` registered and `:read` granted, use one of these snippets as **cell source**, not as application-side code:

```elixir
Eval.tool("read", %{path: "mix.exs"})
```

```javascript
tools.call("read", {path: "mix.exs"});
```

```python
tools.call("read", {"path": "mix.exs"})
```

| Language | Injected API |
|---|---|
| Elixir | `Eval` aliases `OhMyJido.Eval.API`: `Eval.tool(name, parameters \\ %{})`, `Eval.display(value)`, `Eval.artifact(name, media_type, binary_data)`; bounded normal IO |
| JavaScript | Synchronous `tools.call(name, object = {})`, `display(value)`, `artifact(name, mediaType, data)`; `console.log/info/debug` go to stdout, `console.warn/error` to stderr |
| Python | `tools.call(name, dict)`, `display(value)`, `artifact(name, media_type, text_or_bytes)`; captured stdout/stderr and final-expression display |

Tool callbacks are scoped to the active kernel generation, execution ID and remaining deadline. Every tool still needs its own permission and normal authorization or approval. The bridge does not permit recursive calls to Eval, arbitrary host RPC or selecting arbitrary BEAM modules. Rejected tool calls raise language-visible errors; cells and callbacks are never automatically retried.

### Keep bridge data structured

Tool names are at most 128 bytes. Bridge data is limited to depth 16, 1,024 nodes and 128 entries per map. The two directions have different rules:

| Direction | Validation and normalization |
|---|---|
| Parameters sent to a tool | Checked as supplied. They must be a JSON-compatible map; structs, PIDs, references, functions and other unsupported values are rejected. The encoded data must fit the cell's requested output limit. |
| Successful tool results returned to a cell | Redacted and normalized before validation: structs become maps, PIDs/references/functions become `nil`, and lists retain only their first 100 items. The normalized data must then pass JSON and structural validation and fit the remaining output budget. |

At most eight tool callbacks can be in flight. Each has the smaller of `callback_timeout` and the cell's remaining time.

The Elixir/JavaScript worker channel carries bounded data-only JSON, not worker-controlled Erlang terms or a general RPC channel. It also admits at most eight pending callbacks and 1,024 callback requests per cell.

### Do not assume a Node or Bun environment

QuickBEAM starts with `apis: []`. Its built-in `Beam` global is removed from the public globals, built-in Beam handlers are denied, and only the scoped `omj_eval` handler is added. QuickBEAM's general Web/BEAM APIs are not Eval APIs: do not assume Node, Bun filesystem/process APIs, unrestricted `fetch` or unrestricted BEAM RPC.

## Return output and artifacts

A successful call returns `{:ok, result}`. Inspect `result.status`: a language exception normally returns `{:ok, %{status: :error, ...}}`, not an infrastructure `{:error, reason}`.

| Cell result field | Meaning |
|---|---|
| `status` | `:ok`, `:error`, `:timeout`, `:cancelled` or `:crashed` |
| `display` | Bounded text for the final value |
| `stdout`, `stderr` | Captured text |
| `displays` | Text explicitly emitted with `display` |
| `diagnostics` | Bounded language/compiler diagnostics; up to 100 entries are considered |
| `error` | Bounded, redacted error text, or `nil` |
| `artifacts` | Returned artifact records |
| `truncated` | Whether output was clipped |
| `generation`, `execution_id` | Kernel generation and generated cell execution ID |
| `kernel_state` | `:ready` or `:invalidated` after the cell |
| `duration_ms` | Elapsed execution time, not a CPU measurement |
| `effects` | `:completed` or `:uncertain`; completion is not rollback |
| `cleanup` | When reported for interruption/invalidation, `:confirmed` or `:uncertain` |

Stdout, stderr, final display, explicit displays, errors, diagnostics and artifact payload/metadata share **one combined byte budget**. This differs from Shell's per-stream budget. Text clipping is explicit through `truncated`; an artifact that cannot fit is rejected with `:output_limit`. Backends do not synthesize CPU or RSS measurements when none are available.

For example, this Elixir cell returns a text artifact:

```elixir
Eval.artifact("summary.txt", "text/plain", "Result: 42\n")
```

Artifacts are data in `result.artifacts`, not automatic workspace writes or uploads. Each record has `name`, `media_type`, `data`, `encoding` and `bytes`. Valid UTF-8 uses encoding `"utf-8"`; other binary data uses `"base64"`. The name must be a single safe basename of 1–255 bytes: no `.`/`..`, directory paths, backslashes or NUL. Media types are at most 128 bytes. Invalid artifacts return `:invalid_artifact`. Payload and metadata count against the shared budget, including base64 expansion. Returned metadata does not prove that an image or other decoder can interpret the data.

Output is redacted against known session secrets and trusted Context metadata secrets. Snakepit workers also use `private_diagnostics: true`: supported Snakepit status, callback failures, queued requests and streaming completions expose metadata rather than cell payloads, including opaque envelopes in OTP sys-debug history. Normal Snakepit lifecycle and nonprivate-worker behavior remain unchanged. Trusted application-VM introspection and arbitrary raw BEAM messages are outside that diagnostic boundary; keep provider credentials out of Eval workers.

During an active managed run, captured output reaches subscribers as `:tool_output` events with `stream`, `text` and `execution_id` in the payload. The internal message name `:eval_output` is not a public event kind. See [Running tasks](running-tasks.md) and the [API reference](../reference/api.md) for subscriptions.

## Interrupt a cell or discard its state

```elixir
{:ok, _} =
  OhMyJido.execute_tool(session, "eval", %{
    language: "elixir",
    operation: "reset"
  })
```

Reset destroys the existing namespace and starts a new generation. It does not restore lost variables or authorize replaying earlier effects. Close removes the kernel entry entirely; a later deliberate open or execute starts fresh state.

Timeout, hard interruption, caller/worker/controller/owner death, idle expiry or an unfinished/timed-out callback invalidates retained state. Later execute calls return `{:error, {:kernel_invalidated, reason}}` until you explicitly reset or close. Stale execution/generation messages are rejected. The state index preserves this refusal across a manager-child restart while its owning Eval supervisor and index remain alive; it is not a durable language checkpoint across application restart.

An interrupted running cell can return `status: :timeout | :cancelled | :crashed`, `kernel_state: :invalidated`, `effects: :uncertain` and `cleanup: :confirmed | :uncertain`. Confirmed cleanup means the worker stopped, not that earlier file writes or network calls were undone. See [Sessions and recovery](sessions-and-recovery.md) before deciding whether to repeat an effect.

Runtime-owned sessions resolve the current supervised Eval manager for each operation, including after supervisor replacement. An explicit trusted `metadata.eval` PID stays application-owned and is not replaced with the runtime's manager. Resource tracking monitors the Eval controller as well as the owning supervision lifecycle, so hard controller loss releases its slot without replaying the cell.

## Tool operation reference

| `operation` | Behavior and successful result |
|---|---|
| `"execute"` | Default. Opens a new kernel if no entry exists, then executes a cell; returns the cell result above. Never silently replaces an invalidated namespace. |
| `"open"` | Opens a kernel or returns existing kernel information (`status`, `generation`, `reason`). Does not execute source or repair invalidated state. |
| `"interrupt"` | Interrupts a running cell and invalidates its state. With an idle kernel, does nothing. The control call returns `%{status: :cancelled}`; inspect the running cell's result for cleanup details. |
| `"reset"` | Requires an existing entry. Destroys old state and returns new-generation kernel information. |
| `"close"` | Discards the entry; returns `%{status: :closed}`. Closing an absent entry also succeeds. |

The Action removes `worker`, `controller` and `last_used` from returned kernel information. It does not expose an `"info"` operation.

| Tool parameter | Default | Rules |
|---|---|---|
| `language` | Required | `"elixir"`, `"javascript"` or `"python"` |
| `operation` | `"execute"` | One of the operations above |
| `source` | `""` | Valid UTF-8 source, used by execute |
| `timeout` | `30_000` ms | Positive integer no greater than `max_timeout` |
| `output_limit` | `65_536` bytes | Positive integer no greater than `max_output_limit` |
| `cell_id` | Omitted | Optional valid UTF-8 label, 1–128 bytes; not an idempotency, deduplication or retry token |

Each cell gets a newly generated execution ID regardless of `cell_id`. The tool explicitly supplies its timeout/output defaults, so changing only the direct API defaults below does not change the tool's defaults.

## Configuration reference

These options go inside a runtime's `eval:` list, or directly into a standalone `OhMyJido.Eval` child:

| Option | Default | Meaning |
|---|---|---|
| `backends` | `%{}` | Explicitly enabled languages, each mapped to backend keyword options |
| `max_kernels` | `8` | Kernel admission across all enabled languages |
| `max_tasks` | `64` | Maximum children of Eval's task supervisor |
| `idle_timeout` | `300_000` ms | Retire nonbusy kernels after this idle time |
| `sweep_interval` | `30_000` ms | Interval between idle checks |
| `callback_timeout` | `2_000` ms | Maximum time for a tool callback, also bounded by the cell deadline |
| `limits: [timeout: ...]` | `30_000` ms | Default for direct `Eval.execute` calls |
| `limits: [output_limit: ...]` | `65_536` bytes | Default for direct `Eval.execute` calls |
| `limits: [max_timeout: ...]` | `120_000` ms | Maximum requested cell timeout |
| `limits: [max_output_limit: ...]` | `1_048_576` bytes | Maximum requested combined output budget |
| `limits: [source_limit: ...]` | `262_144` bytes | Maximum UTF-8 source size |

`max_kernels` counts kernel-controller entries, not just executing cells. An invalidated controller can still occupy a slot until you reset or close it. Busy kernels are not removed by the idle sweep.

These cell deadlines do not raise the outer limits. A tool call is stopped after `tool_timeout_ms` plus `question_timeout_ms`, and the run deadline still applies. Allow time for worker startup as well as execution: raise `tool_timeout_ms` for long cells, or pass a suitable `timeout:` in `OhMyJido.execute_tool/4` options for a direct tool call. See [Configuration](../reference/configuration.md).

| Backend option | Default | Applies to |
|---|---|---|
| `isolation` | None; required | All languages; `:trusted` or the language-specific `:os` contract below |
| `launcher` | None | Application-provided OS launcher/wrapper |
| `schedulers` | `2` | Elixir/JavaScript child ERTS; also starts one async thread |
| `boot_timeout` | `15_000` ms | Elixir/JavaScript startup |
| `boot_timeout` | `30_000` ms | Python worker startup |
| `memory_limit` | `67_108_864` bytes | QuickBEAM engine memory budget |
| `max_stack_size` | `1_048_576` bytes | QuickBEAM engine stack budget |
| `max_convert_depth` | `16` | QuickBEAM conversion depth |
| `max_convert_nodes` | `4_096` | QuickBEAM conversion nodes |
| `adapter_env` | `[]` | Trusted Python worker environment additions; Eval sets its own `PYTHONPATH` and ownership fields |

QuickBEAM budgets are engine limits, not total worker/application RSS limits or OS security guarantees.

### Python worker identity

Each Python kernel exclusively owns a Snakepit worker and pins its PID, process token and generation. Worker replacement or expired affinity metadata cannot silently create an empty namespace. Commands use `affinity: :strict_fail_fast` and `idempotent: false`, so the adapter fails rather than moving a cell to another worker or replaying it.

### Choose isolation

| Language | `isolation: :os` setup |
|---|---|
| Elixir/JavaScript | `launcher: {absolute_executable, trusted_argv_prefix}`. The executable must be an absolute regular-file path; the prefix is a list of strings. Oh-My-Jido runs it with the selected `erl` executable and ERTS arguments. Your launcher must enforce mounts, network access, identity and resources while supporting that launch. |
| Python | `launcher: "/absolute/path/to/approved-python-wrapper"`. This must be an absolute regular-file path equal to the executable selected by `Snakepit.Adapters.GRPCPython.executable_path()`. Configure that wrapper with Snakepit before startup. The ERTS tuple launcher is not valid here. |

The library validates launcher shape/path, not its isolation policy. It does not supply or install a sandbox launcher. Separate ERTS instances and managed workers provide crash separation, not filesystem/network containment. In particular, arbitrary Elixir and Python can call OS facilities outside the injected tool bridge. Permissions alone cannot sandbox those languages; validate your actual wrapper and apply [OS isolation](security.md) for untrusted work.

Elixir/JavaScript workers run without distribution, shell or input, over a data-only Port protocol. Elixir deliberately does not use OTP `:peer`, whose alternative channel can forward worker-controlled messages into the origin. Code may load modules, corrupt its own child VM or use its permitted OS access, but cells never execute inside or modify the application VM's global cwd, environment or code paths through an injected evaluator.

## Use the standalone Eval server from application code

You can supervise Eval without a coding runtime or model. Add this child to your supervision tree:

```elixir
{OhMyJido.Eval,
 name: MyApp.Eval,
 backends: %{elixir: [isolation: :trusted]}}
```

Then create a trusted Context and execute directly:

```elixir
alias OhMyJido.{Context, Eval}

{:ok, context} =
  Context.new(
    session_id: "report-calculation",
    workspace: "/path/to/project",
    permissions: [:eval, :read],
    tools: [OhMyJido.Tools.Read]
  )

{:ok, result} = Eval.execute(MyApp.Eval, context, :elixir, "value = 40", timeout: 5_000)
{:ok, result} = Eval.execute(MyApp.Eval, context, :elixir, "value + 2", timeout: 5_000)
:ok = Eval.close_session(MyApp.Eval, context.session_id)
```

The server argument is the Eval supervisor PID or registered name. Languages here are existing atoms (`:elixir`, `:javascript`, `:python`), unlike the tool's string enum. Direct calls are trusted application APIs, not a replacement for the Action's per-operation Host authorization. `open` and `execute` check the Context's `:eval` permission; session-ID control calls rely on caller trust. Injected tool calls still use normal tool authorization.

| Application API, on `OhMyJido.Eval` | Result/contract |
|---|---|
| `start_link(options \\ [])` | Starts the Eval supervisor and manager; ordinary supervisor start result |
| `open(server, context, language, options \\ [])` | `{:ok, info}` or `{:error, reason}`. The options argument does not set per-cell budgets. |
| `execute(server, context, language, source, options \\ [])` | `{:ok, cell_result}` or `{:error, reason}`; options are `timeout:`, `output_limit:` and `cell_id:` |
| `interrupt(server, session_id, language)` | `:ok` or `{:error, reason}` |
| `interrupt(server, session_id, language, execution_id)` | Targets that active execution; mismatches return `{:error, :stale_execution}` |
| `reset(server, context_or_session_id, language)` | `{:ok, info}` or `{:error, reason}`. Use a trusted `%Context{}` when the manager no longer has the original Context. |
| `close(server, session_id, language)` | `:ok` or a manager error |
| `close_session(server, session_id)` | Closes all languages for that session; `:ok` or a manager error |
| `info(server, session_id, language)` | `{:ok, info}` or `{:error, reason}` |

Direct open/reset/info results include transient `worker` and `controller` PIDs plus `last_used`; keep them application-only. After manager recovery, reset by session ID can return `:reset_context_required`. Reset with a trusted Context, or through the session's Eval Action, supplies the missing identity.

### Error reference

These are direct Eval error reasons, returned as `{:error, reason}`. Jido may wrap Action validation/dispatch failures in its own error envelope.

| Reason | Meaning/action |
|---|---|
| `{:permission_denied, :eval}` | Grant `:eval` to the trusted session/Context if appropriate. |
| `:eval_unavailable` or `{:eval_unavailable, reason}` | No usable Eval server/manager. |
| `{:backend_unavailable, language}` | That language is not configured. |
| `{:backend_unavailable, language, reason}` | Dependency, startup or backend infrastructure unavailable; inspect the reason. |
| `{:isolation_required, language}` | Missing or invalid isolation configuration. |
| `:invalid_eval_request` | Invalid source, timeout/output bound or cell label. Invalid tool parameter types may fail schema validation first. |
| `:kernel_busy` | Another cell is running in this session/language. |
| `:kernel_limit` | Eval kernel admission is full. |
| `:not_open` | An operation requiring an existing entry found none. |
| `{:kernel_invalidated, reason}` | State was lost or invalidated; explicitly reset or close, without blindly replaying effects. |
| `:session_mismatch` | The Context's workspace does not match the retained kernel. |
| `:reset_context_required` | Reset after manager recovery needs the trusted Context. |
| `:stale_execution` | A targeted interrupt no longer matches the active cell. |

## Limits

- Kernels are transient. Session checkpoints do not preserve executable language state across application restart.
- A single session/language kernel executes one cell at a time. Reset is destructive, not recovery or rollback.
- Eval is not an IEx attachment, distributed RPC endpoint or evaluator inside a running Phoenix/application node. Debugger and approved live MCP tools are separate capabilities with their own targets, permissions and approvals; Eval never escalates to them automatically.
- JavaScript supports the documented injected API, not general Node/Bun compatibility. Python uses Snakepit's actual managed infrastructure, not a parallel pool or package manager.
- Backend runtime packaging and resource enforcement belong to your application. See Project status for the exercised platform matrix rather than inferring support from an engine's published targets.

## Related

- [Tools](tools.md) and [Permissions and approvals](permissions-and-approvals.md)
- [Security](security.md) and [Sessions and recovery](sessions-and-recovery.md)
- [Live applications](live-applications.md) and [Language intelligence](language-intelligence.md)
- [Configuration](../reference/configuration.md) and [API reference](../reference/api.md)
- [Operations](../operations.md) and [Project status](../project-status.md)
