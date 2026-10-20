# Runtime configuration

This is the implemented configuration contract. See [embedding](USER_GUIDE.md) and [account operations](ACCOUNT_OPERATIONS.md) before enabling effects or provider requests.

## Configuration layers and independent instances

`OhMyJido.Runtime` merges, in order:

1. Its built-in defaults.
2. `Application.get_all_env(:oh_my_jido)` supplied through ordinary `import Config`.
3. The options of the supervised Runtime child.

This is a **shallow keyword merge**, not a recursive configuration merger. A child-supplied `:eval`, `:context_policy`, `:model_roles` or `:limits` replaces that application-level value. Each subsystem subsequently applies its own missing-key defaults. Runtime names are required non-nil atoms chosen by the host; use a finite set of host-authored names, never atoms made from model/user input.

`{OhMyJido, options}` is the short public supervisor child form; `OhMyJido.Runtime` remains the underlying OTP runtime. `:bundles` expands into tool modules independently at each configuration layer before the shallow merge, so an explicit child bundle replaces application-level tool availability. `:tools` and `:bundles` in the same layer conflict. Neither option grants capabilities.

```elixir
import Config

config :req_llm, debug: false, load_dotenv: false

config :jido_ai,
  model_aliases: %{
    capable: "anthropic:claude-sonnet-4-6",
    fast: "anthropic:claude-haiku-4-5"
  }

config :oh_my_jido,
  default_role: :coding,
  model_roles: %{
    coding: :capable,
    planning: :capable,
    exploration: :fast,
    review: :capable,
    advisor: :capable,
    compaction: :fast
  }
```

The role/alias part is the repository's `config/config.exs`. Explicit debug:false makes credential-bearing native calls admissible even when `REQ_LLM_DEBUG` is set; the production transformer checks it before resolving credentials. Explicit load_dotenv:false prevents ReqLLM's startup default from importing a source `.env` into the process environment. Dependency application-level settings belong to the host; do not mutate them per agent.

Independent children can use different hosts, account services, storage, tools, adapters and budgets:

```elixir
children = [
  {OhMyJido.Runtime,
   name: MyApp.ReaderCoding,
   host: {OhMyJido.Host.Local, credentials: {OhMyJido.Auth, broker: MyApp.ReaderAccounts}},
   storage: {Jido.Persistence.File, path: "/srv/my_app/reader_sessions"},
   tools: [OhMyJido.Tools.Read, OhMyJido.Tools.Search],
   max_sessions: 20,
   max_active: 2},
  {OhMyJido.Runtime,
   name: MyApp.WriterCoding,
   host: {OhMyJido.Host.Local, credentials: {OhMyJido.Auth, broker: MyApp.WriterAccounts}},
   storage: {Jido.Persistence.File, path: "/srv/my_app/writer_sessions"},
   max_sessions: 10,
   max_active: 1}
]
```

The brokers in this example must already be supervised by the host. Runtime creates a separate native Jido instance, session Registry, admission supervisors and Eval manager. This is library-instance separation, not OS-user isolation. Jido aliases, ReqLLM provider registration and optional Snakepit infrastructure are native application-level facilities. For per-instance model differences, use provider model inputs directly in each instance's `model_roles` instead of changing global aliases during a run.

## Runtime defaults

All values below are source defaults, not measured capacity guarantees. Milliseconds and bytes are literal units.

| Option | Default | Meaning |
|---|---|---|
| `host` | `{OhMyJido.Host.Local, []}` | No credential service or optional service is supplied |
| `credentials` | absent | Optional explicit `{ResolverModule, keyword_options}` exporting `resolve/3`; Host.Local shortcut only, never ambient credential discovery |
| `bundles` | absent | Explicit tool availability selection through `Tools.select/1`; no permission or service startup |
| `default_role` | `:coding` | Role used when no higher selection exists |
| `storage` | `{Jido.Persistence.ETS, table: instance-specific_table}` | Native binary/CAS adapter; worker restart only, not durable across host lifetime |
| `max_sessions` | `500` | Supervised session admission ceiling |
| `max_active` | `8` | Admitted active-run leases, held through native model/tool work |
| `max_processes` | `8` | Scoped Process leases |
| `max_subagents` | `16` | Tracked child-task leases |
| `max_resources` | `64` | Owned process/Eval resources per session |
| `max_runs` | `128` | Retained run-history admission bound per session |
| `max_effects` | `1_024` | Effect-journal admission bound per session |
| `max_secrets` | `256` | Transient registered secret-value bound per session |
| `allow_test_scripts` | `false` | Explicit native ReAct scripts are not production credentials |
| `event_limit` | `256` | Retained host-event ring per session |
| `subscriber_limit` | `128` | Subscriber mailbox admission bound; the entire PID mailbox is observed |
| `max_pending_questions` | `8` | Simultaneously waiting questions per session |
| `question_timeout_ms` | `300_000` | Structured question deadline |
| `tool_timeout_ms` | `30_000` | Default direct-tool timeout and process ceiling fallback |
| `run_timeout_ms` | `300_000` | Active run deadline |
| `max_iterations` | `40` | Native ReAct iteration ceiling |
| `context_policy` | `[]` | ContextPolicy applies the defaults below |
| `eval` | `[backends: %{}, max_kernels: 8]` | No language enabled by default |
| `max_jido_tasks` | `1_000` | Native Jido task budget when not supplied |

The runtime's declared positive-integer limits are validated at startup. Native task/options validation remains owned by the corresponding dependency. `max_active`, Process and subagent admission use `Task.Supervisor.max_children`: saturation is an immediate `{:error, {:capacity, kind}}`, **not** an implicit queue or retry. Run/effect histories also refuse new work when full; stopping/restoring a session does not erase its history. Archive it according to host retention policy and create a new identity when appropriate.

On this native V3 branch, custom storage implements `Jido.Persistence.Adapter`: binary values from `get/2`, opaque conditions and `compare_and_swap/4`. The library stores versioned session bytes under namespaced keys and retains native CAS conditions. `Jido.Persistence.File` is the supplied durable adapter. V2 `Jido.Storage` terms are not automatically converted; use separate compatible data roots or an explicit host migration.


Other trusted Runtime options include `tools`, `adapters`, `metadata`, `limits`, `instructions`, `system_prompt`, `project_instructions`, `project_config`, `project_approved`, `user_config`, `skills`, `skill_roots` and `request_transformer`. The default transformer is the native policy boundary `OhMyJido.Models.Transformer`; replacing it is trusted host code, not a model-facing preference.

With the reference local host, prefer `credentials: {MyApp.Credentials, options}` to manually nesting the resolver under `host:`. `OhMyJido.Auth` with `broker: MyApp.AccountBroker` is the existing broker resolver. The resolver is not called at startup. Combining this shortcut with a custom host is rejected rather than silently overriding its credential policy; configure that host's own callback instead.

`limits` must be a map of integer tool budgets. It is merged over integer Runtime options to form `Context.limits`. Individual tools enforce their own domains and effective ceilings. It is not a global memory quota or OS containment setting.

## Session options and restore

`start_session(runtime, options)` accepts an explicit existing `workspace`; an optional binary `id` of1–128 bytes; `permissions` (default`[]`); `role`, `model` and opaque `account`; a `goal`; either `bundles` or explicit `tools`; `host`; `adapters`; and `metadata`. Session tool selection replaces Runtime availability, never adds grants. With neither selection, the Runtime registry or `Tools.default/0` remains the managed default. Native model exposure is still intersected with permissions and model tool capability metadata.

Session metadata overrides runtime metadata. Session adapters override same-named runtime adapters. The session coordinator supplies its own runtime/Eval handles internally. Treat all of these options as host-authored authority; a repository file must never be evaluated as configuration.

Durable options retain `workspace`, `permissions`, `role`, `account`, `model`, `goal`, `tools` and only these metadata keys: `git_repository_root`, `git_worktree_roots`, `delegation_roots`, `delegation_depth`, `project_instructions`, `skills`, `skill_roots`. Per-session host/adapters, service PIDs, arbitrary metadata, callback functions and per-request options are **not** persisted. Restore rebuilds them from the current runtime configuration. Place durable service policy in that configuration or in your host's identity-based resolver. Do not assume an old adapter PID survives restart.

Resolved bundle Actions are retained as `:tools`, so restoring an identity does not silently replace its selected availability with a new Runtime bundle. New/restored managed contexts use the same field validation as `Context.new/1`; malformed grants, host/service bindings and tool modules return field-specific configuration failures rather than entering a half-configured agent.

For prompt composition, supply approved project instructions through the trusted runtime's `project_instructions`/`project_approved` settings. Retaining a `metadata.project_instructions` field is not, by itself, the composer's approval/input path.

## Six native model roles and account selection

`OhMyJido.Models.roles/0` returns `[:coding, :planning, :exploration, :review, :advisor, :compaction]`. Roles change prompt guidance and model selection, not permission grants.

| Role | Guidance | Bare-library default model | Repository configured alias |
|---|---|---|---|
| `coding` | Targeted implementation and observed verification | `anthropic:claude-sonnet-4-6` | `:capable` |
| `planning` | Integration boundaries, dependencies and acceptance | `anthropic:claude-sonnet-4-6` | `:capable` |
| `exploration` | Read-only evidence gathering | `anthropic:claude-haiku-4-5` | `:fast` |
| `review` | Severity-ordered concrete findings | `anthropic:claude-sonnet-4-6` | `:capable` |
| `advisor` | Consequences and trade-offs without taking control | `anthropic:claude-sonnet-4-6` | `:capable` |
| `compaction` | Preserve constraints and effect evidence | `anthropic:claude-haiku-4-5` | `:fast` |

Bare-library defaults are valid native ReqLLM model inputs: a consuming project need not import this repository's configuration or populate global Jido aliases to start a session and use authorized direct tools. This repository separately defines the optional `:capable`/`:fast` aliases shown above. Explicit model/alias selections and role overrides keep the precedence below; invalid selected inputs still fail instead of falling back. The installed catalog marks older `claude-sonnet-4-20250514` retired with no capabilities. These defaults do not grant credentials or authority to bill/enroll an account. ContextPolicy is extractive and never makes an automatic compaction-model request.

Model selection and account selection use the following layers independently:

1. Explicit session/task options.
2. A retained `session_selection` (the existing session selection on follow-up prompts).
3. An approved declarative `project_config`.
4. Runtime `user_config`.
5. Application/runtime defaults and bare-library default model inputs.

A `model_roles` value can be a ReqLLM model input or `%{model: input, account: reference}`. Direct `model` values apply to their matching selected role. Opaque accounts are nonempty strings, non-boolean/non-nil atoms, integers, or nonempty tuples of those values; maps, PIDs and credential records are rejected. `nil` can explicitly mean no account, but a production model turn then fails account admission.

An approved project envelope has this real shape:

```elixir
project_config: %{
  approved: true,
  config: %{
    model_roles: %{
      review: %{model: "anthropic:claude-sonnet-4-20250514", account: "approved-review-account"}
    }
  }
}
```

Without `approved: true` (or the trusted `project_approved: true` boolean for a plain declarative map), project overrides are ignored. The selector never reads/evaluates a repository `config.exs`, discovers live provider models, or grants an account. `Models.resolve/1` and `describe/1` validate against installed Jido/ReqLLM metadata; a locally valid identifier is not a live access guarantee.

On a subsequent host-submitted prompt, `role`, `model` and `account` can explicitly select a different approved pairing. The selected pairing is retained for follow-up work; no error selects an alternate account automatically. `tools` can only narrow the session's registered list. Forwarded native request options are `llm_opts`, `req_http_options`, `output`, `file_references` and `file_ids`; `max_iterations` cannot raise the runtime ceiling. Raw credentials and credential lifecycle/file options are rejected at the model boundary. Runtime/host configuration cannot be widened through prompt options.

## ContextPolicy and common tool ceilings

ContextPolicy defaults:

| Option | Default |
|---|---|
| `max_messages` | `80` (compaction trigger, not an exchange-splitting cap) |
| `keep_recent` | `16` |
| `max_bytes` | `120_000` |
| `summary_bytes` | `12_000` |
| `max_retained_bytes` | `64_000` |
| `max_tool_records` | `1_024` |

Mandatory retained content and complete exchanges are protected. If they cannot fit, the policy returns an explicit budget error instead of silently truncating them. See [ContextPolicy v2](PERMISSIONS_AND_RECOVERY.md#contextpolicy-version-2).

Selected tool-level defaults in `Context.limits` when not explicitly configured:

| Budget key | Default | Scope |
|---|---|---|
| `max_file_bytes` | `8_388_608` | Complete file input/mutation |
| `max_read_bytes` | `262_144` | Returned read slice |
| `process_timeout_ms` | `tool_timeout_ms` | Process deadline ceiling |
| `max_output_bytes` | `1_048_576` | Process retained bytes **per stream** |
| `search_max_results` | `200` | Retained search/list entries |
| `search_max_output_bytes` | `131_072` | JSON bytes of retained entries |
| `search_max_discovery_bytes` | `1_048_576` | Discovery output |
| `search_max_files` | `10_000` | Files searched |
| `search_max_scan_bytes` | `33_554_432` | Scan budget |
| `search_max_line_bytes` | `2_048` | Result line bytes |
| `search_timeout_ms` | `10_000` | Search deadline |
| `search_max_pattern_bytes` | `4_096` | Pattern bytes |
| `search_max_walk_entries` / `search_max_depth` | `100_000` / `64` | Ignore-boundary traversal |
| `ast_file_bytes` / `ast_result_bytes` | `1_048_576` / `65_536` | Structural input/result |
| `ast_max_results` | `1_000` | Structural ceiling; Action request defaults to 100 |
| `extension_input_bytes` / `extension_result_bytes` | `32_768` / `65_536` | MCP input and structured extension results |
| `protocol_frame_bytes` / `protocol_timeout_ms` | `1_048_576` / `10_000` | Stdio protocol bounds |
| `protocol_pending_timeout_ms` | `300_000` | Pending asynchronous protocol request |
| `artifact_input_bytes` / `artifact_output_bytes` | `33_554_432` / `131_072` | Host artifact ceilings; Action requests default to 8 MiB/8 KiB |
| `browser_output_bytes` / `research_output_bytes` | `131_072` / `131_072` | Host text ceilings; Action requests default to 8 KiB |
| `review_diff_bytes` / `review_findings` | `262_144` / `100` | Review ceilings; Action requests default to 64 KiB/50 |
| `skill_bytes` | `262_144` | Loaded skill guidance |
| `max_experiment_trials` | `8` | Each trial executes once |
| `max_subagent_depth` | `2` | Child-depth guard; child grants remove `:delegate` |

Requested tool limits are constrained by their effective host ceilings. Native QuickBEAM limits and Eval's separate keyword limits are documented in [Eval operations](EVAL_OPERATIONS.md); neither is implied by the numbers above.
