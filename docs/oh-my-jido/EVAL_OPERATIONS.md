# Eval operations: Elixir, JavaScript and Python

Eval is one native Jido Action, `OhMyJido.Tools.Eval` (`"eval"`), over configured persistent language backends. It never implements the agent loop, coding tools, generic Bun/Node compatibility or a second Python process manager. Arbitrary Elixir cells never run in the host ERTS.

No backend is enabled by default. A session needs `:eval`, a registered Eval Action and an explicitly configured language. Host tools invoked from a cell also need registration, their independent grants and normal authorization.

## Enable only trusted/contained execution

For explicitly trusted code, a Runtime child can use:

```elixir
{OhMyJido.Runtime,
 name: MyApp.Coding,
 eval: [
   max_kernels: 4,
   backends: %{
     elixir: [isolation: :trusted],
     javascript: [isolation: :trusted],
     python: [isolation: :trusted]
   }
 ]}
```

JavaScript/Python entries additionally require the native dependencies and host infrastructure below. An enabled entry is not an installed backend. `:trusted` explicitly accepts the code's access under the worker's OS identity; it is not a sandbox setting.

Elixir/JavaScript `isolation: :os` requires `launcher: {absolute_executable, trusted_argv_prefix}`. The host supplies a **real** isolation launcher, including permitted mounts/egress/identity/resources and a way to launch the selected ERTS. The library validates the launcher shape/path, not its OS policy. No sandbox launcher is fabricated or installed.

Python `isolation: :os` has a different contract: `launcher` is an absolute executable string equal to the executable configured for `Snakepit.Adapters.GRPCPython`. Configure Snakepit's approved Python/isolation wrapper before startup. A tuple-shaped ERTS launcher is not a Python launcher. Do not label `:os` as verified containment without testing the actual host wrapper.

All process/execution authority is host-owned. Separate ERTS/managed workers are crash separation, not OS confinement. Arbitrary trusted Elixir/Python can call OS facilities outside the injected bridge; bridge grants alone cannot sandbox those languages. Resource limits below are not a memory or filesystem security claim.

## One session/language namespace and explicit cells

```elixir
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

The actual Action language enum is `"elixir" | "javascript" | "python"`; operations are `"execute"` (default), `"open"`, `"interrupt"`, `"reset"`, `"close"`. Source defaults to empty text, timeout to 30,000 ms and output limit to 65,536 bytes. A native execution ID is generated for each cell. Optional `cell_id` is a bounded label, **not** an idempotency token/deduplication/retry mechanism.

A successful control/execute call returns `{:ok, result}`. Inspect `result.status`: an ordinary language exception is often `{:ok, %{status: :error, ...}}`, not an infrastructure `{:error, ...}`. Completed cell results include status, display text, stdout/stderr, explicit displays, diagnostics, error, artifacts, truncation, generation, execution ID, kernel state, duration and effect status. Not every backend reports native CPU/RSS usage; no resource measurement is synthesized.

Successful cells retain bindings/context/namespace in their session/language. A language error is not a transaction rollback: JavaScript/Python may have changed namespace state before the error, and any language may have made earlier host/OS effects. Elixir updates retained binding/environment on successful evaluation; its separate VM can still contain earlier module/OS effects. Kernels are transient, not a durable executable checkpoint across host restart.

## Injected APIs

| Language | Implemented injected surface |
|---|---|
| Elixir | Alias `Eval` to `OhMyJido.Eval.API`: `Eval.tool(name, parameters \\ %{})`, `Eval.display(value)`, `Eval.artifact(name, media_type, binary_data)`; normal bounded IO |
| JavaScript | Synchronous `tools.call(name, object)`, `display(value)`, `artifact(name, mediaType, data)`, console log/info/debug to stdout and warn/error to stderr |
| Python | `tools.call(name, dict)`, `display(value)`, `artifact(name, media_type, text_or_bytes)`; captured print/stderr; final expression display |

For example, a granted registered `"read"` tool can be called as:

```elixir
Eval.tool("read", %{path: "mix.exs"})
```

```javascript
tools.call("read", {path: "mix.exs"});
```

```python
tools.call("read", {"path": "mix.exs"})
```

These snippets are **cell source**, not host API calls. The bridge is generation/execution/deadline scoped. Parameters/results must be bounded JSON-compatible data; structs, PIDs, arbitrary RPC/module names and oversized/non-structured objects are not a tool bridge. Recursive Eval tool calls are denied. Up to 8 bridge callbacks are admitted; they have their own bounded remaining deadline. A denied call returns/raises an actual language-visible error. No callback or cell is automatically retried.

QuickBEAM's native `Beam` global is removed from the injected public globals, native built-in Beam handlers are denied, and only the scoped `omj_eval` handler is added. Engine startup uses `apis: []`. The QuickBEAM package's general Web/BEAM APIs are **not** this harness's Eval contract: do not assume Bun filesystem/process APIs, unrestricted fetch, native Beam RPC or a Node environment.

`artifact` returns bounded data in the result; it does not silently write to the workspace or upload it. Names must be single safe basenames; binary data uses UTF-8 when valid and otherwise base64, with media type/bytes/encoding. Artifacts share the combined output budget. They are not authority or evidence that a decoder interpreted their contents.

## Bounds and invalidation

Eval-manager options are separate from Runtime `limits`:

| Eval option | Default |
|---|---|
| `max_kernels` | `8` live kernels across enabled languages |
| `max_tasks` | `64` native task-supervisor children |
| `idle_timeout` | `300_000` ms |
| `sweep_interval` | `30_000` ms |
| `callback_timeout` | `2_000` ms |
| `limits: [timeout: ...]` | `30_000` ms direct-execution default |
| `limits: [output_limit: ...]` | `65_536` bytes direct-execution default |
| `limits: [max_timeout: ...]` | `120_000` ms ceiling |
| `limits: [max_output_limit: ...]` | `1_048_576` bytes ceiling |
| `limits: [source_limit: ...]` | `262_144` UTF-8 bytes |

The Action supplies its schema defaults explicitly; changing only the direct API defaults does not change those Action defaults. Invalid requested timeout/output/source/cell labels return `:invalid_eval_request`. Concurrent cells in one kernel return `:kernel_busy`; exceeding live admission returns `:kernel_limit`.

Output is a **combined** budget for stdout, stderr, display/displays, errors, diagnostics and artifact payload/metadata, not the Process tool's per-stream budget. Truncation is explicit; artifacts too large for the remaining budget return `:output_limit`. Bridge data has separate complexity limits (depth 16, 1,024 nodes, bounded map size) and JSON encoding checks. ERTS control traffic is bounded data-only JSON; no worker-controlled Erlang-term/RPC channel is trusted.

Timeout, hard interruption, worker/controller/owner death, idle expiry or unfinished timed-out callback invalidates retained state. Old execution/generation messages are rejected. The next execute does **not** silently create an empty namespace under a familiar identity: it reports `{:kernel_invalidated, reason}` until explicit reset/close. The retained-state index also preserves invalidation across manager-child restart while its owning Eval supervisor/index remains alive.

```elixir
{:ok, reset} =
  OhMyJido.execute_tool(session, "eval", %{
    language: "elixir",
    operation: "reset"
  })
```

Reset destroys the old worker namespace and starts an explicitly new generation; it is not recovery of vanished variables or permission to replay effects. Closing discards the kernel entry; a subsequent intentional open starts new state. Interrupt results distinguish actual cleanup and uncertainty. A running interrupted cell can return `status: :timeout | :cancelled | :crashed`, `kernel_state: :invalidated`, `effects: :uncertain`, and `cleanup: :confirmed | :uncertain`. Confirmed cleanup never means earlier writes/network calls were undone.

Direct native `Eval` host APIs take an existing atom language and trusted Context. `info`/open/reset contain worker/controller PIDs; the Action removes those handles. Keep direct results host-only. After manager recovery, resetting by session ID alone may report `:reset_context_required`; a trusted Context/reset through the session Action restores the necessary identity.

Runtime-owned sessions resolve the current supervised Eval manager for each operation, including after supervisor replacement. A trusted explicit `metadata.eval` PID remains host-owned; the library does not replace it with the runtime's manager. Worker resource registration monitors the native controller as well as its supervisor, so hard controller loss releases admission without replaying the cell.

## Elixir: non-distributed child ERTS

Elixir uses the existing `erl` executable under Linux `setsid`, a data-only Port protocol and the installed code paths. It is deliberately **not OTP `:peer`**: the stock alternative channel can forward worker-controlled messages into the origin. Backend defaults are `schedulers: 2`, one async thread, `boot_timeout: 15_000` ms, non-distributed/noshell/noinput operation. Bindings and `Macro.Env` are retained across successful cells; IO/compiler diagnostics are separate from JSON control traffic.

No dependency or script installs an ERTS on your behalf. The host packages a matching runnable Erlang/Elixir environment. Elixir code can corrupt its own child VM, load code or use OS access under the selected isolation policy; it must never be used to modify the host VM's global cwd/env/code. Hard loss invalidates that generation without blindly replaying a cell.

This is persistent isolated evaluation, not IEx attachment, distributed RPC or evaluation inside a running Phoenix/application node. DAP debugging is a separate breakpoint/step/inspection capability; it does not supply live-node evaluation.
Approved Tidewave-style actual-application docs/logs/source and last-resort live evaluation/RPC use the separate [trusted live MCP binding](TOOLS_AND_EXTENSIONS.md#tidewave-style-live-application-tools). They require their own target/grants/approval and do not change this isolated Eval contract or enable automatic escalation.


## JavaScript: optional native QuickBEAM

An embedding host choosing JavaScript must select the optional QuickBEAM dependency **before compiling** Oh-My-Jido, for example `{:quickbeam, "~> 0.11", runtime: false}` in its dependency list alongside the approved library/native overrides. The package source/natively compatible artifact must be available. The adapter conditionally compiles its actual native integration; an absent package gives an explicit dependency-unavailable result. It does not install/fall back at execution time.

This backend runs persistent native QuickBEAM **only in the separate ERTS**, not in the host and not as the coding harness. It has the same trusted/OS launcher/ERTS prerequisites. Native engine defaults are 67,108,864-byte memory limit, 1,048,576-byte stack, conversion depth 16 and 4,096 conversion nodes; trusted backend options can select these native limits. They are QuickBEAM engine budgets, not total child/host RSS or OS guarantees.

The installed QuickBEAM 0.11.3 documentation lists Linux x86-64/ARM64 glibc/musl precompiled artifacts and source-build requirements (Zig 0.16 with explicit portable baseline options). That package platform list is **not** Oh-My-Jido's exercised platform matrix. Linux x86_64 native execution is recorded; aarch64/guest packaging remains pending. No Zig/Rust helper is introduced for core tools.

## Python: optional Snakepit-managed exclusive workers

Choose the licensed optional Snakepit snapshot before compilation: `{:snakepit, path: Path.join(root, "vendor/snakepit"), override: true, runtime: false}`, where `root` is the approved Oh-My-Jido checkout. Stock Hex Snakepit0.14 does not have the required `private_diagnostics_version/0 == 1` boundary; Python admission fails explicitly rather than weakening privacy. Provision an approved Python environment yourself and supervise its actual native infrastructure in the host. Eval uses only Snakepit-managed workers, strict fail-fast affinity, `idempotent: false` commands and a generation-bound exclusive worker/namespace. Worker PID/token replacement or expired affinity metadata cannot silently substitute a new namespace. SnakeBridge is optional for a separately justified typed library binding; this backend does not require it, generate bindings or install its runtime.

The **installed generated stubs/requirements**, not older upstream getting-started examples, require `grpcio >= 1.84.0`, `grpcio-tools >= 1.84.0`, `protobuf >= 7.35.1` and the remaining [`vendor/snakepit/priv/python/requirements.txt`](../../vendor/snakepit/priv/python/requirements.txt) dependencies. The host must approve package provisioning/downloads and native wheel/target compatibility. Installed Python packages alone are not a started Snakepit runtime.

Select the executable before host startup with native configuration:

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

That path must be a real preprovisioned executable (or approved compatible isolation wrapper). `:python_executable` precedes the supported `SNAKEPIT_PYTHON` environment override. Never change VM-global config/environment per session.

Set `instance_name`, `instance_token` and an owned `data_dir` once before native SDK startup. Distinct concurrently running host VMs need distinct instance identities and non-shared state directories: Snakepit's stale-worker cleanup owns a logical host instance and must not classify another live host's workers as leftovers. Use a nonsecret runtime identity, not a provider credential; never generate a separate SDK instance per coding-agent session. The opt-in tests and standalone smoke use distinct native host identities.

Do **not** call upstream `Snakepit.Application.start/2` per agent to obtain these components: that startup sets VM-global environment variables, and Python pool bootstrap can install/upgrade packages in dev/test. The library keeps Snakepit `runtime: false` and performs no automatic installer. The actual network-free startup pattern is in [`test/eval_python_test.exs`](../../test/eval_python_test.exs): after starting native `:grpc_server` and `:grpc` applications, the host supervises the following **once per host**:

```elixir
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
  {Snakepit.Worker.LifecycleManager, []}
]
```

Place these real native children under host supervision, not under a newly copied Python pool manager. Ensure `Snakepit.GRPC.Listener.await_ready/0` succeeds before allowing cells. The adapter checks required registered native processes, including gRPC client infrastructure and Ranch; unavailable infrastructure returns `:snakepit_runtime_not_started`. Keep the internal gRPC listener private to its intended workers. Native Snakepit executable/infrastructure configuration is application-level even when coding runtimes have separate Eval managers.

The backend sets its real adapter module/PYTHONPATH and private ownership token in the **worker's** configuration, not the host's environment. It cleans owned workers and native tool/session registrations on timeout/reset/teardown. The licensed SDK's trusted `worker_config.private_diagnostics: true` keeps supported native status, callback faults, queued requests and streaming completions metadata-only, including OTP sys-debug history through opaque native envelopes. Native lifecycle and nonprivate behavior remain intact. Arbitrary raw BEAM messages and introspection by trusted host VM code are outside this boundary; do not put provider credentials in Eval workers or claim isolation from the host administrator.

The native Python opt-in suite is human-invoked with `OH_MY_JIDO_PYTHON_EVAL=1` and an approved preprovisioned executable; normal tests skip that tagged suite otherwise. Run instructions are in [operations](OPERATIONS_AND_EVIDENCE.md), not an automatic installer. Current Linux x86_64 evidence includes12 actual Python scenarios: deliberate worker exit, queued effects, callback errors/throws/exits, private diagnostics, host survival and explicit reset without replay. Full CI and target-platform packaging remain separate gates.
