# Connect external tools and artifacts

Use adapters to connect a session to services your application already controls: MCP servers, browsers, research providers, artifact decoders and review services. Oh-My-Jido checks the tool request and its permissions. Your adapter performs the real service operation and owns its resources; unconfigured services return an error rather than a simulated result.

## Bind an adapter

Configure optional services with this shape:

```elixir
adapters: %{
  capability => {AdapterModule, trusted_options}
}
```

`capability` is an application-selected atom, `AdapterModule` implements `invoke(context, request, options)`, and `trusted_options` is a keyword list. `OhMyJido.Host.Local` dispatches adapter calls only through this map. The model supplies the checked tool request, never the adapter module, executable, MFA or privileged options. A missing binding returns `{:error, {:capability_unavailable, capability}}`.

For example, this session uses the supplied local artifact adapter without enabling any network service:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:artifact],
    tools: [OhMyJido.Tools.Artifact],
    adapters: %{artifact: {OhMyJido.Extensions.Artifact.Local, []}}
  )

{:ok, artifact} =
  OhMyJido.execute_tool(session, "artifact", %{
    operation: "inspect", path: "priv/images/example.png"
  })
```

The runtime must already be supervised and the file must already exist. Tool selection makes the Action available; it does not grant its permission or configure a missing service.

| Binding key | Supplied implementation or contract | Tool permission |
|---|---|---|
| `:ast` | An application-supplied parser for languages other than Elixir; plans only | `:ast`, plus source read/edit permissions |
| `:lsp` | `OhMyJido.Intelligence.LSP` | `:lsp` |
| `:debug` | `OhMyJido.Intelligence.DAP` | `:debug` |
| `:observer` | `OhMyJido.Intelligence.Observer` | `:observe` |
| `:mcp` | `OhMyJido.Extensions.MCP`, or `Extensions.Tidewave` over the same owner | `:mcp`; Tidewave live tools also need `:live_eval` |
| `:browser` | Your `OhMyJido.Extensions.Browser` implementation | `:browser` |
| `:research` | Your `OhMyJido.Extensions.Research` implementation | `:research` |
| `:artifact` | `Extensions.Artifact.Local` or your `Extensions.Artifact` implementation | `:artifact` |
| `:review` | Your `Extensions.Review` implementation for host capture or enrichment; built-in Git review needs no binding | `:review`; built-in Git capture also needs `:git` |

Each adapter call returns `{:ok, result}` or `{:error, reason}`. Browser, research, artifact and review modules declare behaviours for `invoke/3` and optional `close_session/2`. An adapter must return the real documented result, including unavailable operations and uncertain effects. A callback returning an invalid result does not release resources it already created.

If you need different dispatch, implement the `invoke/4` callback of `OhMyJido.Host` in your own trusted policy. It receives `(context, capability, request, host_options)` and returns `{:ok, result}` or `{:error, reason}`. `OhMyJido.Host.call/3` dispatches to that configured policy. Authorization, questions and credentials are separate callbacks; see [permissions and approvals](permissions-and-approvals.md), [models and accounts](models-and-accounts.md) and the [API reference](../reference/api.md).

## Own adapter resources

Your adapter must enforce:

| Responsibility | What your application must do |
|---|---|
| Identity | Bind resources to the real session/workspace; reject cross-session handles |
| Authority | Enforce the approved service, origins, tools, resources and any extra effects beyond the tool's permission |
| Deadlines and bounds | Honor request deadlines and input/output limits in the actual service, not only in the returned text |
| Cancellation | Stop or reconcile in-flight work, including work created before a callback was interrupted or returned an invalid response |
| Cleanup | Release real pages, readers, requests, decoders, subprocesses or model resources; report unconfirmed cleanup instead of success |
| Restore and children | Rebuild transient bindings for each restored/child identity; do not blindly share a parent's protocol PID |

At session teardown, `OhMyJido.Extensions.close_session/1` invokes optional `close_session(context, options)` hooks for configured AST, LSP, Debug, Observer, MCP, Browser, Research, Artifact and Review bindings. The hook returns `:ok` or `{:ok, result}` on success. Errors are collected as `{:error, [%{capability: capability, reason: reason}]}`; invalid cleanup replies and exceptions also become failures. A missing hook is not proof that resources were cleaned up.

A teardown hook does not replace cancellation of in-flight work. Callback-only services remain application-owned, including resources whose handles never reached the caller. Use managed `OhMyJido.execute_tool/4` when you need the session effect journal; direct adapter/Context calls do not create that durable boundary.

## Call scoped MCP tools

MCP means Model Context Protocol. The supplied adapter is a **stdio client** for an explicitly started server, not a universal transport or an automatic tool installer. The model can call only exact tool names and resource URIs your application allows.

Prepare a trusted Context and future session ID as in the [language-server setup](language-intelligence.md#connect-a-language-server), with `:mcp` permission. Start the approved server under your application's `DynamicSupervisor`, then use that same identity when opening the session:

```elixir
{:ok, server} =
  DynamicSupervisor.start_child(MyApp.Intelligence,
    {OhMyJido.Extensions.MCP,
     context: context, executable: executable, args: args}
  )

{:ok, mcp_session} =
  OhMyJido.start_session(MyApp.Coding,
    id: context.session_id,
    workspace: context.workspace,
    permissions: [:mcp],
    tools: [OhMyJido.Tools.MCP],
    adapters: %{
      mcp: {
        OhMyJido.Extensions.MCP,
        [server: server, tools: approved_tool_names, resources: approved_resource_uris]
      }
    }
  )

{:ok, initialized} =
  OhMyJido.execute_tool(mcp_session, "mcp", %{operation: "initialize"})

{:ok, listed} =
  OhMyJido.execute_tool(mcp_session, "mcp", %{operation: "list_tools"})
```

`executable`, `args`, `approved_tool_names` and `approved_resource_uris` are trusted application inputs, not values copied from a model response. The allowlists accept exact strings in lists or `MapSet`s and default to empty. Clean up the prepared server if session creation fails.

Use an allowed tool's real input schema when building its arguments:

```elixir
{:ok, result} =
  OhMyJido.execute_tool(mcp_session, "mcp", %{
    operation: "call_tool", name: tool_name, arguments: tool_arguments
  })
```

`tool_name` must be allowlisted and `tool_arguments` must be the argument map for that service. Server announcements and list results do not grant access or register new Jido Actions. Every tool call is a sensitive effect and passes through your application's approval policy.

| `operation` | Fields | Behavior |
|---|---|---|
| `"initialize"` | None | Negotiates a supported protocol version, then sends initialized notification |
| `"list_tools"` | Optional `cursor` | Filters the server's results to the exact tool allowlist |
| `"call_tool"` | `name`, `arguments: %{}` by default | Calls one allowed tool; sensitive approval |
| `"list_resources"` | Optional `cursor` | Filters the server's results to the exact resource allowlist |
| `"read_resource"` | `uri` | Reads one allowed resource |
| `"close"` | None | Closes the session-owned server and reports cleanup |

| Option or bound | Default / contract |
|---|---|
| `protocol_version` | `"2025-06-18"`; also supports `"2025-03-26"` and `"2024-11-05"` |
| Client capabilities | Empty; sampling, elicitation, reverse tool execution and implicit roots are not advertised |
| `name` | Nonempty UTF-8, at most 256 bytes, no NUL |
| `uri` | Nonempty UTF-8, at most 8,192 bytes, no NUL |
| `cursor` | Nonempty UTF-8, at most 1,024 bytes, no NUL |
| `extension_input_bytes` | `32_768`; bounds the encoded request |
| `extension_result_bytes` | `65_536`; bounds structured results |
| Successful response | `%{result: native_result, identity: bound_identity, trusted: false}`; close instead returns its cleanup receipt |
| Denied selectors | `{:mcp_tool_not_granted, name}` or `{:mcp_resource_not_granted, uri}` |
| Unsupported version | `:mcp_protocol_version_unsupported` |

A lost tool response returns a reason map containing `reason: :mcp_tool_outcome_unknown`, `cause` and `effect: :uncertain`. An oversized completed result can return `reason: :mcp_result_limit`, `limit`, `effect: :completed`, `result: :unavailable`. In either case, missing usable output does **not** justify repeating the tool effect.

MCP deadlines use `notifications/cancelled` with the actual request ID, not LSP's `$/cancelRequest`. Initialization is not cancelled through that mechanism. A cancellation notification does not prove rollback or completion.

For a pinned live application, use the [Tidewave binding](live-applications.md#connect-tidewave-tools) rather than exposing target selection or evaluation through a generic MCP tool.

## Stdio protocol reference

`OhMyJido.Intelligence.LSP`, `OhMyJido.Intelligence.DAP` and `OhMyJido.Extensions.MCP` implement `start_link/1`, `child_spec/1`, `invoke/3` and `close_session/2`. All use the session-bound `OhMyJido.Intelligence.Stdio` owner and the installed JSON codec. The executable and arguments are trusted startup options; this owner opens no remote transport or model-selected executable.

The owner uses Linux process identity/group cleanup plus a watchdog for abrupt owner loss. One instance belongs to one session and canonical workspace. Keep its trusted `owner:` PID alive; the default is the Context's coordinator or the process starting the adapter. The reference child specs are temporary and have a 15-second supervisor shutdown bound.

| Bound | Default | Configuration |
|---|---|---|
| Frame body | `1_048_576` bytes (1 MiB) | Trusted `max_frame_bytes`, bounded by `limits.protocol_frame_bytes` |
| Normal request | `10_000` ms | Trusted `timeout_ms`, bounded by `limits.protocol_timeout_ms` |
| Pending asynchronous request | `300_000` ms | Trusted `pending_timeout_ms`, bounded by `limits.protocol_pending_timeout_ms` |
| Pending requests | `8` | Fixed bound; completed asynchronous outcomes also consume their retained slots until awaited |
| Retained events | `64` | Fixed bound; do not assume an unlimited event history |

| Trusted API | Use |
|---|---|
| `start_link/1`, `start/1` | Supervised owner, or monitored unlinked owner for a finite human-invoked smoke |
| `bind/2` | Check session/workspace ownership; mismatch returns `:protocol_identity_mismatch` |
| `request/3,4`, `notify/3` | Bounded request/response or notification |
| `begin_request/3,4,5`, `await_response/2,3` | Asynchronous request and later observation of its outcome |
| `await_event/2,3,4`, `latest_event/2,3` | Observe actual retained protocol messages; unavailable events remain errors |
| `document_version/3,4`, `document_versions/1`, `document_sources/1` | LSP version tracking and independently fingerprinted successfully sent full source |
| `close/2`, `close_session/2` | Close only the matching session's owned process group |

These are trusted application APIs, not an unrestricted RPC surface for models. Missing executables, malformed JSON/framing, oversized frames, server exit and owner loss are explicit errors. Typical reasons include `:protocol_executable_unavailable`, `:protocol_timeout`, `:protocol_closed`, `:protocol_request_limit` and `:event_unavailable`. See [language intelligence](language-intelligence.md) for checked LSP/DAP operations and coordinate conventions.

## Connect a browser

The library supplies a checked request/response contract, **not a browser engine**. Implement `OhMyJido.Extensions.Browser` and bind your implementation under `:browser`. It must own real pages and enforce approved origins, redirects, popups, downloads and cleanup.

| `operation` | Required fields | Optional fields | Sensitive approval |
|---|---|---|---|
| `"navigate"` | Credential-free HTTP(S) `url` | Existing `page_id` | Yes |
| `"snapshot"` | `page_id` | None | No extra sensitive flag |
| `"click"` | `page_id`, `selector` | None | Yes |
| `"fill"` | `page_id`, `selector`, `value` | None | Yes |
| `"close"` | `page_id` | None | No extra sensitive flag |

All operations still need `:browser`. Common request options are `timeout_ms: 15_000` (`1..30_000`) and `max_output_bytes: 8_192` (`64..131_072`), further capped by `limits.browser_output_bytes` (default `131_072`). Page IDs are opaque nonempty strings up to 256 bytes; selectors up to 512 bytes; fill values up to 8,192 bytes and may be empty.

For navigate/snapshot/click/fill, your adapter returns:

```elixir
%{page_id: page_id, url: actual_url, title: title, content: utf8_text, truncated: false}
```

`title` and `truncated` are optional. The actual URL must be valid credential-free HTTP(S), at most 4,096 bytes. If the request names a page, the reply must name the same page. The Action projects only the checked fields, caps the title at 512 bytes, clips text at a UTF-8 boundary and returns `trust: :untrusted`, `truncated` and the effective limits.

Close must release the actual requested page and return `%{page_id: requested_id, closed: true}`. An uncertain close is `:browser_cleanup_unconfirmed`, not successful release. Invalid replies return `{:invalid_host_response, :browser}`. Handle creation interrupted before a reply remains your adapter's cleanup responsibility.

No arbitrary JavaScript, cookies, headers or RPC method is admitted by the core browser tool. Page text cannot become instructions or permissions. URL syntax validation alone is not an origin/egress security policy.

## Connect research search and reading

Implement `OhMyJido.Extensions.Research` and bind your real service under `:research`. The core does not ship a search provider or credentialed network client. Every call needs `:research` and sensitive external approval, including reads.

| `operation` | Request | Adapter response |
|---|---|---|
| `"search"` | Nonempty `query` up to 4,096 bytes; `limit: 5` by default, range `1..20` | `%{results: [%{url: url, title: title, snippet: text}]}` |
| `"read"` | Credential-free HTTP(S) `url` up to 4,096 bytes | `%{url: actual_url, title: title, content: text}`; title may be omitted |

Both accept `timeout_ms: 15_000` (`1..30_000`) and `max_output_bytes: 8_192` (`64..131_072`), further capped by `limits.research_output_bytes` (default `131_072`). A search cannot include a read URL, and a read cannot include a search query. No headers, cookies, shell command, tool-discovery selector or RPC method is exposed.

The Action returns the checked search/read shape with `operation`, `trust: :untrusted`, `truncated` and effective limits. Provider `truncated: true` is retained. Search titles and snippets share the requested text budget; each URL has its own 4,096-byte bound. Read title/content share the text budget. Invalid replies return `{:invalid_host_response, :research}`.

Your service must enforce egress, redirects, approved origins and provider/credential policy, honor deadlines, and release real request/connection resources. Credential-free URL syntax is not an SSRF boundary: it does not by itself prevent requests to internal services. Content is evidence, not host policy.

## Inspect local artifacts

The supplied `OhMyJido.Extensions.Artifact.Local` reads regular confined files without execution or network access:

| Input | What it returns | What it does not establish |
|---|---|---|
| UTF-8 text without NUL bytes | Bounded text, byte count and SHA-256 | No execution or instruction authority |
| Recognized PNG/GIF headers | Media type and width/height, plus file identity | No pixel/frame decoding, full image validity, OCR or semantic image interpretation |
| Other binary data | Byte count and SHA-256 | No document interpretation or invented decoder output |

Header-only image inspection is the default binding:

```elixir
adapters: %{artifact: {OhMyJido.Extensions.Artifact.Local, []}}
```

| Field or option | Default / contract |
|---|---|
| `operation` | Required `"inspect"` or `"read_text"` |
| `path` | Required existing regular file inside the workspace |
| `kind` | `"auto"` by default; `"image"`, `"text"`, `"binary"` also accepted |
| `max_input_bytes` | `8_388_608` (8 MiB); request maximum `33_554_432` (32 MiB), capped by `artifact_input_bytes` |
| `max_output_bytes` | `8_192` (8 KiB); request range `64..131_072`, capped by `artifact_output_bytes` |
| File limit | The local adapter also obeys the shared complete-file `max_file_bytes` limit, default 8 MiB |
| Result | Relative `path`, `media_type`, bounded `summary`/`content`, projected `width`, `height`, `sha256`, `bytes` when supplied, `limitations`, `truncated`, `trust: :untrusted`, effective limits |
| Unsupported explicit image | `{:unsupported_artifact_format, :image}`; auto mode may instead classify unrecognized bytes as text or binary |
| Other common errors | `:artifact_not_regular`, `:artifact_not_text`, `{:artifact_too_large, size, cap}` |

`"read_text"` accepts only `kind: "auto"` or `"text"`. Other decoders must be real application-supplied bindings with their own security and resource limits. Adapter requests carry the confined absolute path, relative display path, stat size and effective bounds. Recheck confinement at the actual file-open boundary, enforce limits and release readers/decoder resources before returning. The artifact permission covers local reading, not network upload or code execution; obtain separate approval for those effects.

Results deliberately omit arbitrary decoder metadata. Limitations are projected as a bounded text list. ContextPolicy's projected-byte budget also counts content; admitting a file does not exempt it from the conversation budget.

### Send an approved image to a model

If your application approves disclosing image bytes to its selected model, enable the trusted option:

```elixir
adapters: %{artifact: {OhMyJido.Extensions.Artifact.Local, model_inputs: true}}
```

For a recognized image, the local adapter creates a native `ReqLLM.Message.ContentPart.image/2` part in the real tool exchange. The artifact boundary accepts at most one image part, within approved input bytes. A model-supplied request flag cannot turn this on. The adapter's `__content_parts__` field carries that native part; it is not arbitrary decoder metadata.

This is not a separate uploader or vision engine. Subsequent native inference sends approved context through the account and model your application already selected. Choose an approved image-capable model and obtain disclosure/billing permission first. Header dimensions alone are not semantic evidence about an image. See [models and accounts](models-and-accounts.md) and [security](security.md).

## Review actual Git changes

The `"review"` Action gives bounded risk hints about actual tracked workspace changes, not model-supplied diff text. Built-in capture uses Git and requires both `:review` and `:git`, not arbitrary `:exec`.

```elixir
{:ok, review_session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:review, :git],
    tools: [OhMyJido.Tools.Review]
  )

{:ok, review} =
  OhMyJido.execute_tool(review_session, "review", %{
    operation: "diff", paths: ["lib/my_app/counter.ex"], staged: false
  })
```

| Option | Default | Contract |
|---|---|---|
| `operation` | `"diff"` | The only operation |
| `source` | `"git"` | `"host"` uses your approved `:review` binding to capture a real confined Git diff |
| `staged` | `false` | Choose tracked staged or unstaged changes |
| `paths` | `[]` | At most 20 selected paths; empty means the selected diff scope, not untracked files |
| `enrich` | `false` | Ask an approved review service about the captured diff under fresh sensitive external approval |
| `timeout_ms` | `15_000` | Request range `1..30_000` |
| `max_diff_bytes` | `65_536` (64 KiB) | Request range `256..262_144`, capped by `review_diff_bytes` |
| `max_findings` | `50` | Request range `1..100`, capped by `review_findings` |

Built-in capture disables external diff and text conversion through the existing Git boundary. A host capture request uses `operation: :diff` with confined workspace, paths, staged selector, timeout and diff bound. It must return `%{source: :workspace_git, diff: bytes, truncated: boolean}` from a real operation. Untracked additions are not part of a tracked diff.

Rules flag possible credentials/private keys, dynamic execution and destructive operations with concrete changed path/line locations. Detection includes common GitHub/AWS/OpenAI-style tokens, credential assignments and private-key markers; dynamic execution/unsafe deserialization/atom creation; and destructive filesystem, database or Git commands. Findings are limited heuristics, not proof that a secret is live or code is exploitable.

### Add approved review enrichment

Bind your `OhMyJido.Extensions.Review` implementation under `:review` and set `enrich: true`. Its `operation: :review` request contains the actual bounded captured `diff`, `diff_sha256`, `diff_truncated`, `staged`, `paths`, `max_findings` and `timeout_ms`. It does not receive an arbitrary model-supplied diff or unrelated workspace files.

**The captured diff can contain secrets.** Enrichment requires fresh sensitive external approval naming its hash and byte count before disclosure. Output redaction is not a claim that outbound diff text is safe to share.

Return `%{findings: findings}` with optional `truncated` and `limitations`. Each suggestion must cite an actual changed `path`, positive `line` and `side` (`:new` by default, or `:old`), with `category`, `risk` and `message`. Accepted categories are `:secret`, `:dynamic_execution`, `:destructive_effect`, `:correctness`; accepted risks are `:medium`, `:high`, `:critical` (string forms are also accepted). Invalid or unanchored suggestions are omitted with an explicit limitation. Messages are bounded and sanitized; host findings remain untrusted suggestions.

| Result field | Meaning |
|---|---|
| `source`, `evidence_origin` | `:workspace_git` and actual process/approved-host capture origin |
| `diff_sha256`, `diff_bytes`, `diff_truncated` | Identity, size and completeness of captured bytes |
| `findings`, `findings_truncated` | Bounded changed-location hints and whether some were omitted |
| `risk` | Highest observed hint risk, or `:none`; not an overall security verdict |
| `approval_required` | Hints indicate effects needing review; this does not itself approve or deny a later effect |
| `security_certainty` | Always `:limited` |
| `risk_assessment` | `:incomplete` or `:observed_diff_only` |
| `limitations`, `scope`, `limits`, `trust` | What was inspected, effective bounds, and `:untrusted` status |

Redaction tracks every distinct detected secret within the bounded captured diff, including a truncated final line. Later matches do not evict earlier ones after 100 matches. Enrichment messages and limitations are sanitized against that complete detected set before publication. Detection remains pattern-limited: it does not recognize every possible secret. Partial final lines, binary content and combined merge diffs are not claimed as complete reviewed text.

Review/advisor [child agents](subagents.md) can add recommendations under parent control. Neither local hints, enrichment nor a child review approves deployment or the reviewed effect.

## Exercise a real integration

Smoke helpers are opt-in application calls that exercise real services. Nothing below runs automatically, installs a service, bypasses approval or turns a fixture result into proof about a live integration.

| Helper | Explicit inputs and behavior |
|---|---|
| `OhMyJido.Extensions.Browser.smoke(context, url, expected_content, options)` | Requires `human_initiated: true` and a real browser binding; navigate, observe expected content and confirm actual page close |
| `OhMyJido.Extensions.Research.smoke(context, query, expected_url, expected_content, options)` | Requires `human_initiated: true` and a real research binding; verifies actual search/read observations |
| `OhMyJido.Extensions.Artifact.smoke(context, path, options)` | Requires `human_initiated: true`; inspects an actual confined file through the configured adapter |
| `OhMyJido.Extensions.Review.smoke(context, options)` | Requires `human_initiated: true`; reviews actual selected workspace Git changes |
| `OhMyJido.Intelligence.LSP.smoke(context, server_options, path, position)` | Explicit real server; initializes, opens source and observes navigation/diagnostics |
| `OhMyJido.Intelligence.DAP.smoke(context, server_options, plan)` | Explicit real adapter and program/source/line/variable plan; breakpoint/step/variable workflow using deferred launch, not GDB's order |
| `OhMyJido.Extensions.MCP.smoke(context, server_options, plan)` | Explicit real server, allowlisted tool/resource and expected text plan |

The first four return `:human_initiated_required` without the flag. LSP/DAP/MCP require explicit real server options/plans and normal sensitive host authorization instead. These low-level helpers do not create a managed session's durable journal. Keep expected observations and permissions narrow, and inspect cleanup receipts.

## Limits

- Browser and research require real application bindings. Core request validation does not supply a browser, search index, SSRF defense or network isolation.
- External page/tool/provider output and artifact/review text remain untrusted data, never a source of permissions or host policy.
- Timeouts or lost replies can leave external effects uncertain. Never automatically replay them; see [sessions and recovery](sessions-and-recovery.md).
- Permissions and workspace checks are library policy, not an OS sandbox. Use appropriate process, container, filesystem and network isolation for untrusted work.

## Related

- [Tool selection and custom Actions](tools.md)
- [Permissions and approvals](permissions-and-approvals.md)
- [Security boundaries](security.md)
- [Language servers, AST and debuggers](language-intelligence.md)
- [Observer and Tidewave](live-applications.md)
- [Models and accounts](models-and-accounts.md)
- [Configuration reference](../reference/configuration.md)
- [Public API reference](../reference/api.md)
- [Compatibility and verification status](../project-status.md)
