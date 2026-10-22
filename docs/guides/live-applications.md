# Inspect a running application

Use Observer to inspect a running BEAM VM without opening a GUI or evaluating arbitrary code. If you also need an application's documentation, source locations, logs or explicitly approved live evaluation, bind its Tidewave tools through MCP. These are separate from the debugger and from isolated Eval workers.

## Choose the right tool

| Need | Tool | Required permission | Target |
|---|---|---|---|
| VM counters, processes, supervision or ETS metadata | `"observer"` | `:observe` | This VM or an already configured distributed node |
| Application logs through Tidewave | `"mcp"` | `:mcp` and sensitive approval | A separately running approved application |
| Tidewave docs/source lookup or another live tool | `"mcp"` | `:mcp`, `:live_eval` and sensitive approvals | A separately running approved application |
| Breakpoints, stepping and debugger variables | `"debug"` | `:debug`; launch needs approval | An approved debugger; see [language intelligence](language-intelligence.md) |
| Evaluate code away from a live application | `"eval"` | `:eval` and configured backend policy | Isolated workers; see [Eval](eval.md) |

Tool availability and permissions are independent. The `:live_inspection` bundle selects Observer but does not grant `:observe`, RPC or evaluation. See [permissions and approvals](permissions-and-approvals.md).

## Enable local Observer

Observer is a headless inspection adapter built from fixed OTP APIs. It does not call `:observer.start/0`, require wxWidgets, open IEx or expose arbitrary RPC.

Bind the target and the supervision roots your application permits:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:observe],
    bundles: [:live_inspection],
    adapters: %{
      observer: {
        OhMyJido.Intelligence.Observer,
        [target: :local, supervisors: %{"app" => MyApp.Supervisor}]
      }
    }
  )

{:ok, overview} =
  OhMyJido.execute_tool(session, "observer", %{operation: "overview"})

{:ok, processes} =
  OhMyJido.execute_tool(session, "observer", %{
    operation: "processes", limit: 20, offset: 0
  })

{:ok, tree} =
  OhMyJido.execute_tool(session, "observer", %{
    operation: "supervision", root: "app", depth: 3, limit: 100
  })
```

`MyApp.Coding` must already be supervised. `MyApp.Supervisor` is an application-approved supervisor, not a model-selected module. The `supervisors` map accepts string labels mapped to supervisor PIDs or registered names. Requests use only those labels; an unknown label returns `:observer_supervisor_not_granted`.

### Inspect a process or ETS table

Use an identifier returned by the inventory, not a PID or table guessed from another VM:

```elixir
# This example requires a nonempty process page.
[entry | _] = processes.entries

{:ok, process} =
  OhMyJido.execute_tool(session, "observer", %{
    operation: "process", pid: entry.pid
  })

{:ok, tables} = OhMyJido.execute_tool(session, "observer", %{operation: "ets"})

# For a nonempty ETS page, inspect a returned table identifier.
[table | _] = tables.entries

{:ok, metadata} =
  OhMyJido.execute_tool(session, "observer", %{
    operation: "table", table: table.id
  })
```

A process or table can disappear between calls. That is a real `:observer_process_gone` or `:observer_table_gone` outcome, not an empty successful inspection.

### Observer operations

| `operation` | Selectors | Returned information |
|---|---|---|
| `"overview"` | None | OTP/Elixir version, uptime, run queue, VM counts/limits, schedulers, word size and system memory in bytes |
| `"applications"` | `limit`, `offset` | Started application names and versions |
| `"processes"` | `limit`, `offset` | PID strings, registered names, status, memory, reductions, mailbox length, initial/current function and heap/stack sizes |
| `"process"` | Returned `pid` string | The same fixed metadata for one process |
| `"supervision"` | Approved `root` label, `depth`, `limit` | Child IDs, PIDs, types, modules and parent links; explicit traversal errors/truncation |
| `"ets"` | `limit`, `offset` | Table IDs, names, sizes, memory, type, protection, owner and concurrency flags |
| `"table"` | Returned `table` ID string | The same metadata for one table; no contents |

Every successful observation includes the actual `target` node name and `atomic: false`. Inventory results include `entries`, `count`, `observed_total`, `disappeared`, `offset` and `truncated`; supervision instead reports its approved root, entries, count and truncation. These are live observations, not a consistent VM-wide snapshot.

| Option or bound | Default | Allowed / behavior |
|---|---|---|
| `limit` | `50` | `1..200`; for supervision, one total node budget across the traversal |
| `offset` | `0` | `0..100_000`; inventory pagination |
| `depth` | `3` | `1..5`; supervision traversal depth |
| Trusted `target` | No implicit target | `:local` or an already configured node atom |
| Trusted `supervisors` | `%{}` | Only approved string labels are traversable |
| Trusted `timeout_ms` | `5_000` | Remote call timeout, capped at `30_000` milliseconds; supervision has its own bounded traversal deadline |
| `extension_result_bytes` | `65_536` | Structured result limit, capped at `131_072` for Observer |
| Process enumeration | OTP 28+ iterator | Stops after the requested offset/page plus lookahead; older targets return `:observer_process_iterator_unavailable` |
| Memory units | Mixed, explicitly named | System `memory_bytes` are bytes; ETS `memory` is VM words. Use overview's `wordsize` to convert. |

For processes, `observed_total` is a non-atomic sample of the target VM's process count. It does not mean the adapter enumerated every process. Snapshots neither reset cumulative counters nor enable scheduler tracing.

### Observe another node

Change the trusted binding, not the tool request:

```elixir
adapters: %{
  observer: {
    OhMyJido.Intelligence.Observer,
    [
      target: :"my_app@approved-host",
      supervisors: %{"app" => MyApp.Supervisor},
      timeout_ms: 5_000
    ]
  }
}
```

Your application must already configure distribution and authentication, connect the node, and install `OhMyJido.Intelligence.Observer` on that target. Registered supervisor names are resolved on the target VM; use target-local names for remote roots. The adapter uses `:erpc` only to invoke its fixed collector. It does not start distribution, set a cookie, inject code or silently switch targets.

| Reason | Meaning |
|---|---|
| `:observer_timeout` | An OTP collection or remote call exceeded its deadline |
| `:observer_observation_unavailable` | A requested OTP observation is unsupported or unavailable locally or remotely |
| `:observer_target_unavailable` | The remote node is disconnected or missing |
| `:observer_target_failed` | Another remote transport/target failure |
| `:observer_supervisor_not_granted` | The requested supervision label is not approved |
| `:observer_process_iterator_unavailable` | The target cannot provide bounded iterator-based process inventory |
| `:observer_process_gone`, `:observer_table_gone` | The selected live object no longer exists |
| `{:extension_result_limit, :observer, limit}` | The structured observation exceeded the allowed result size |

Partial supervision traversal keeps per-root errors and `truncated: true`; it does not invent an empty tree. A missing remote target remains distinct from an unavailable OTP observation.

## Connect Tidewave tools

Tidewave exposes tools inside an application you run. `OhMyJido.Extensions.Tidewave` pins those tools to one approved loopback application port and reuses the existing MCP stdio owner. It adds no new evaluator, transport, GUI or core Tidewave dependency.

Install Tidewave in your approved development application using Tidewave's own integration instructions. Run that application in a **separate VM** from your application using Oh-My-Jido. Start the reviewed `mix tidewave.proxy --no-browser-tools` command through the session-bound MCP owner. Do not substitute a model-supplied command.

**Tested with:** Tidewave 0.9.1 and Bandit 1.13.1. The binding uses Tidewave's released stdio proxy.

With `MyApp.Intelligence` supervised as in the [language-server setup](language-intelligence.md#connect-a-language-server), prepare a Context and proxy for the same future session identity. `workspace` is the approved development project; `mix_executable` is your reviewed Mix executable with the intended Elixir/OTP toolchain:

```elixir
permissions = [:mcp, :live_eval]

{:ok, context} =
  OhMyJido.Context.new(
    runtime: MyApp.Coding,
    workspace: workspace,
    permissions: permissions,
    tools: [OhMyJido.Tools.MCP]
  )

{:ok, proxy} =
  DynamicSupervisor.start_child(MyApp.Intelligence,
    {OhMyJido.Extensions.MCP,
     context: context,
     executable: mix_executable,
     args: ["tidewave.proxy", "--no-browser-tools"]}
  )

{:ok, live_session} =
  OhMyJido.start_session(MyApp.Coding,
    id: context.session_id,
    workspace: context.workspace,
    permissions: permissions,
    tools: [OhMyJido.Tools.MCP],
    adapters: %{
      mcp: {
        OhMyJido.Extensions.Tidewave,
        [
          server: proxy,
          port: 4000,
          tools: ["get_docs", "get_source_location", "get_logs", "project_eval"]
        ]
      }
    }
  )
```

The application must already be listening on the approved port. If session creation fails, close the prepared MCP owner with `OhMyJido.Extensions.MCP.close_session(context, server: proxy)`. Session restore and child sessions need their own correctly owned proxy bindings.

Initialize and discover the allowed tools through the existing `"mcp"` Action:

```elixir
{:ok, initialized} =
  OhMyJido.execute_tool(live_session, "mcp", %{operation: "initialize"})

{:ok, listed} =
  OhMyJido.execute_tool(live_session, "mcp", %{operation: "list_tools"})

{:ok, docs} =
  OhMyJido.execute_tool(live_session, "mcp", %{
    operation: "call_tool",
    name: "get_docs",
    arguments: %{"reference" => "Enum.map/2"}
  })
```

Read the returned tool schemas for your Tidewave version before constructing other calls. The binding removes the proxy's `port` property and requirement from discovery, then injects port `4000` from trusted options. Returned content stays `trusted: false` and identifies `target: "http://127.0.0.1:4000/tidewave/mcp"` and `mode: :live`.

### Allowlist and approval rules

| Tool | What it does | Authority |
|---|---|---|
| `get_logs` | Reads actual application logs | Exact allowlist entry, `:mcp` and sensitive MCP-call approval |
| `get_docs` | Looks up documentation in actual application dependencies | The same, plus `:live_eval` and sensitive target-specific approval |
| `get_source_location` | Finds source locations in the running application's environment | The same, plus `:live_eval` and sensitive target-specific approval |
| `project_eval` | Runs explicitly approved code in the live application | The same, plus `:live_eval` and sensitive target/code-specific approval; last resort |
| Every other allowlisted tool | Its actual upstream behavior | Requires the same extra `:live_eval` boundary; only `get_logs` is exempt |

The explicit `tools` allowlist is mandatory; it accepts a list or `MapSet` of exact tool-name strings. Without `:live_eval`, tools other than logs are hidden from initialization/list responses and their calls are denied. Announcements and upstream `readOnlyHint` values never grant authority. Runtime-authorized tools are presented with `readOnlyHint: false`.

Docs and source lookups need runtime authority because Tidewave 0.9.1 parses references into permanent atoms and can load modules, including their `@on_load` callbacks. A structured request is not necessarily a harmless one. Prefer Observer, logs and narrowly scoped lookups before live code, while retaining the required approvals for those lookups.

Sensitive `:live_eval` authorization names the exact target and tool and includes `arguments_sha256`; if a `code` argument is supplied, it also includes `code_sha256`. Approval effects contain bounded intent and digests, **not raw arguments or code**. Your application must match those digests to privately reviewed request data; a digest by itself does not explain what an operator is approving. See [permissions and approvals](permissions-and-approvals.md).

The model cannot select `port`, `target`, `host`, `hostname`, `url`, `endpoint`, `base_url`, `node`, `cookie` or `server` as request/argument target selectors. Such selectors return `:tidewave_target_selector_forbidden`. Trusted `port` must be an integer in `1..65_535`; the server must be the bound MCP owner PID. Missing or invalid configuration returns `:tidewave_tools_allowlist_required`, `:invalid_tidewave_tools_allowlist`, `:invalid_tidewave_port`, `:invalid_tidewave_server` or the normal unavailable-service error.

### What live access cannot promise

- `project_eval` may explicitly invoke `:rpc` or `:erpc` as an approved last resort. This is live application execution, not the isolated Eval environment or a grant to execute in your application's VM.
- A pinned port and `:live_eval` permission do not sandbox approved code. The separate target VM and its own OS/network/credential boundaries remain your responsibility.
- The binding starts no application endpoint, package installation, distribution or cookie change. It has no automatic fallback.
- Timeouts, cancellation or transport loss do not prove rollback or that target code stopped. Keep uncertain outcomes and reconcile them instead of retrying.
- Closing the owned proxy does not kill the application. `close_session/2` releases the correct proxy owner even after its permissions have been revoked.

## Limits

- Observer returns VM metadata only. It does not read process state, mailbox messages, process dictionaries, application environment or ETS contents. This exclusion is not a general secret-detection guarantee.
- The model cannot choose an Observer node, cookie, module/function, arbitrary introspection field or executor. Trusted application configuration owns those choices.
- Observer's metadata snapshots are non-atomic. Missing objects and partial traversal are expected live-state outcomes.
- Tidewave retains [MCP's protocol limits, untrusted results and uncertain-effect behavior](integrations.md#call-scoped-mcp-tools). None of these live tools replace OS isolation.

## Related

- [Permissions and approvals](permissions-and-approvals.md)
- [Security boundaries](security.md)
- [Adapter ownership and MCP](integrations.md)
- [Language servers and debuggers](language-intelligence.md)
- [Isolated Eval](eval.md)
- [Configuration reference](../reference/configuration.md)
- [Public API reference](../reference/api.md)
- [Compatibility and verification status](../project-status.md)
