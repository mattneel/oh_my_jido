# Configuration reference

Use runtime configuration for application-wide policy, session options for one workspace and identity, and prompt options for one run. This page lists the defaults and merge rules; [models and accounts](../guides/models-and-accounts.md) explains model selection and credentials.

## Configuration layers

`OhMyJido.Runtime` merges three keyword lists, in this order:

1. Built-in defaults.
2. `Application.get_all_env(:oh_my_jido)`, normally supplied with `import Config`.
3. Options on the supervised runtime child.

The merge is shallow, not recursive. A child-supplied `eval`, `context_policy`, `model_roles`, or `limits` replaces the entire application-level value. Each subsystem then fills in its own missing-key defaults. For example, a child's `context_policy: [max_messages: 40]` uses the other built-in ContextPolicy defaults, not other values from the application's `context_policy` list.

`bundles:` expands to Action modules independently at each layer, before merging. A child's bundle therefore replaces application-level tool availability. `tools:` and `bundles:` in the same layer conflict. Tool availability is separate from permissions; see [permissions and approvals](../guides/permissions-and-approvals.md).

```elixir
import Config

config :req_llm, debug: false, load_dotenv: false

config :oh_my_jido,
  max_sessions: 100,
  max_active: 4,
  context_policy: [max_messages: 60, keep_recent: 12]
```

ReqLLM debugging must be off before production credentials are resolved. Explicit `debug: false` overrides `REQ_LLM_DEBUG`; `load_dotenv: false` disables ReqLLM's default startup `.env` import. These are dependency application settings, not runtime-specific options. See [credential setup](../guides/models-and-accounts.md#configure-reqllm-before-making-requests).

## Run independent instances

`{OhMyJido, options}` is the public supervisor child form; `OhMyJido.Runtime` is the underlying OTP supervisor. Choose a non-`nil`, non-boolean atom for each name from a finite application-authored set. Never create runtime-name atoms from user or model input.

```elixir
children = [
  {OhMyJido,
   name: MyApp.ReaderCoding,
   credentials: {OhMyJido.Auth, broker: MyApp.ReaderAccounts},
   storage: {Jido.Storage.File, path: "/srv/my_app/reader_sessions"},
   tools: [OhMyJido.Tools.Read, OhMyJido.Tools.Search],
   model_roles: %{coding: "openai:gpt-6-luna"},
   max_sessions: 20,
   max_active: 2},
  {OhMyJido,
   name: MyApp.WriterCoding,
   credentials: {OhMyJido.Auth, broker: MyApp.WriterAccounts},
   storage: {Jido.Storage.File, path: "/srv/my_app/writer_sessions"},
   bundles: [:read_only, :editing],
   model_roles: %{coding: "openai:gpt-6-luna"},
   max_sessions: 10,
   max_active: 1}
]
```

The two OpenAI account brokers must already be supervised by your application. Select an account from the matching broker when opening each session. For API-key accounts, use your own resolver instead; see [models and accounts](../guides/models-and-accounts.md).

Each runtime owns a Jido instance, a session Registry, bounded supervisors for active work, and an Eval manager. Runtimes can have different host policies, credential services, storage, tools, adapters, and limits. This is library-instance separation, not OS-user isolation. Jido aliases, ReqLLM provider registration, and optional Snakepit infrastructure remain application-level facilities. Use provider-qualified inputs in each instance's `model_roles` for model differences; do not change global aliases during a run.

## Runtime options

These are source defaults, not measured capacity guarantees. Times are milliseconds unless a row says otherwise; byte limits count bytes, not characters. Options described as absent have no runtime-supplied value; the consuming subsystem uses the fallback shown.

### Identity, storage, and services

| Option | Default | Meaning |
|---|---|---|
| `name` | Required | Non-`nil`, non-boolean atom naming this supervised instance |
| `host` | `{OhMyJido.Host.Local, []}` | Host policy; no credential service or optional adapter is supplied by default |
| `credentials` | Absent | `{ResolverModule, keyword_options}` exporting `resolve/3`; shortcut for `Host.Local` only |
| `storage` | `{Jido.Storage.ETS, table: instance_specific_table}` | Session checkpoint store; ETS survives session-worker restart, not host VM restart |
| `tools` | Absent; managed sessions use `OhMyJido.Tools.default/0` | Explicit Action module list; the managed fallback is the complete registry, with no permissions or services implied |
| `bundles` | Absent | Named availability bundles expanded through `OhMyJido.Tools.select/1`; conflicts with `tools` in the same layer |
| `adapters` | `%{}` | Capability atoms mapped to `{AdapterModule, keyword_options}` exporting `invoke/3` |
| `metadata` | `%{}` | Trusted metadata map used when constructing session contexts |
| `limits` | `%{}` | Tool-budget map; merged over integer runtime options to form `Context.limits` |
| `eval` | `[backends: %{}, max_kernels: 8]` | Eval manager options; no language backend is enabled by default |
| `max_jido_tasks` | `1_000` | Native Jido task budget; dependency validation applies |

The `credentials:` shortcut is normalized into the local host options. It checks the resolver's module and callback but does not obtain credentials at startup. A custom host plus this shortcut is rejected instead of overriding that host's credential policy. Configure a custom host's own `credentials/3` callback instead.

Use `storage: {Jido.Storage.File, path: "/srv/my_app/coding_sessions"}` or your durable adapter for restarts across VM lifetimes. The path must be application-owned, writable, and outside editable repositories. Session stores contain private conversation and tool data; the file adapter does not encrypt them and is not a credential vault.

On master, custom session storage implements the native `Jido.Storage` checkpoint contract. The V3 preview uses a different byte/CAS persistence contract; do not assume the two branches share a storage format.

See [sessions and recovery](../guides/sessions-and-recovery.md) for checkpoint/restore usage and [Eval](../guides/eval.md) for the nested `eval:` options, backend prerequisites, and separate Eval limits.

### Model selection and instructions

| Option | Default | Meaning |
|---|---|---|
| `default_role` | `:coding` | Role used when no higher-priority selection supplies one |
| `role` | Absent | Optional direct role selection; takes precedence over `default_role` in the same selection layer |
| `model` | Absent | Direct ReqLLM model input for its matching role; otherwise a role mapping/default is used |
| `account` | Absent; selection is `nil` | Opaque account reference; production inference needs an explicit selected account |
| `model_roles` | Absent; six built-in role defaults | Map or keyword list of roles to model inputs or `%{model: input, account: reference}` entries |
| `session_selection` | Absent; empty layer | Retained selection input; normally maintained by the session coordinator |
| `project_config` | `%{}` | Declarative project selection map or `%{approved: true, config: map}` envelope |
| `project_approved` | `false` | Trusted approval for plain project configuration and plain project instructions |
| `user_config` | `%{}` | Selection layer below approved project configuration and above runtime defaults |
| `instructions` | `[]` | Trusted application instruction text or list of texts |
| `system_prompt` | `[]` | Additional trusted instruction text or list; composed with native system guidance |
| `project_instructions` | `[]` | Text/list approved by `project_approved: true`, or `%{approved: true, instructions: text}` / `%{approved: true, body: text}` |
| `skills` | `[]` | Explicit approved skill wrappers used by the prompt composer and skill catalog |
| `skill_roots` | `[]` | Explicit approved roots for skill discovery; no implicit repository scan |
| `request_transformer` | `OhMyJido.Models.Transformer` | Per-request model/tool/credential policy boundary; replacing it is trusted application code |
| `allow_test_scripts` | `false` | Allows explicit native ReAct test scripts to bypass production credentials; neither request options, ambient scripts, nor the Mix environment authorize this |

On master, bare role defaults use Jido aliases, and the installed `:capable`, `:planning`, and `:thinking` aliases point at a retired Sonnet model. Select an active provider-qualified model or configure the needed roles/aliases explicitly before inference. The repository's own role/alias configuration is not imported by consuming applications.

See [model roles](../guides/models-and-accounts.md#model-roles) for all six defaults and guidance, and [selection precedence](../guides/models-and-accounts.md#selection-precedence) for the full model/account rules. Role guidance does not change session permissions. ContextPolicy makes no automatic compaction-model request.

Skill roots use approved wrappers such as `%{approved: true, path: "skills"}` for workspace-relative discovery or `%{approved: true, path: "/srv/my_app/skills", scope: :host}` for an application-approved absolute root. Skill modules/specs use wrappers such as `%{approved: true, skill: MyApp.ReviewSkill}`. Project files are data; no repository configuration is evaluated. See [tools and skills](../guides/tools.md) for the skill workflow.

### Capacity, history, and timeouts

| Option | Default | Scope |
|---|---|---|
| `max_sessions` | `500` | Concurrent supervised sessions per runtime |
| `max_active` | `8` | Active-run slots per runtime, held through model and tool work |
| `max_processes` | `8` | Scoped subprocess slots per runtime |
| `max_subagents` | `16` | Tracked child-task slots per runtime |
| `max_resources` | `64` | Owned process/Eval resources per session |
| `max_runs` | `128` | Retained run-history entries per session |
| `max_effects` | `1_024` | Effect-journal entries per session |
| `max_secrets` | `256` | Transient known-secret values per session; each value is at most 16,384 bytes |
| `event_limit` | `256` | Retained application-event ring entries per session |
| `subscriber_limit` | `128` | Default pending-mailbox bound per subscriber PID; observes the entire PID mailbox, not only this session's events |
| `max_pending_questions` | `8` | Simultaneously waiting questions per session |
| `question_timeout_ms` | `300_000` | How long a question or approval waits for an answer. The wait does not use `tool_timeout_ms`. |
| `tool_timeout_ms` | `30_000` | Tool budget: fallback ceiling for each command's deadline. A tool call, agent-started or direct, is stopped after `tool_timeout_ms` plus `question_timeout_ms`; a context without a session uses `tool_timeout_ms` alone. |
| `run_timeout_ms` | `300_000` | Active-run deadline, including time spent waiting for answers |
| `max_iterations` | `40` | Jido.AI ReAct iteration ceiling; a prompt cannot raise it |
| `context_policy` | `[]` | Options for each new session's extractive ContextPolicy; defaults below |

All numeric capacity/history/deadline options in this table except the nested `context_policy` value must be positive integers; Runtime validates them at startup. Eval and native task options retain their own subsystem validation.

Active-run, process, and subagent saturation is immediate: `{:error, {:capacity, kind}}`, where `kind` is `:model`, `:process`, or `:subagent`. There is no implicit queue or retry. Session admission uses `:sessions`; full run/effect histories use `:run_history` and `:effect_history`. Stopping and restoring a session does not erase its history. Apply your application's archive/retention policy and start a new identity when appropriate.

## Session options

Pass these trusted options to `OhMyJido.start_session(runtime, options)`. Options are a keyword list.

| Option | Default | Meaning |
|---|---|---|
| `workspace` | Required | Existing directory; canonicalized before session creation |
| `id` | Generated by Jido | Binary session ID of 1–128 bytes |
| `permissions` | `[]` | Permission atoms as a list or `MapSet`; runtime tool availability does not grant them |
| `role` | Selection layers, normally `:coding` | One of the six model roles |
| `model` | Selection layers/role default | Explicit ReqLLM model input, never credentials |
| `account` | Selection layers, otherwise `nil` | Opaque account reference |
| `goal` | `nil` | Initial task goal |
| `tools` | Runtime selection or `Tools.default/0` | Explicit session Action list; replaces runtime availability |
| `bundles` | Absent | Session availability bundles; replaces runtime selection and conflicts with session `tools` |
| `host` | Runtime host | Per-session host policy |
| `adapters` | `%{}` overrides | Merged over runtime adapters by capability name |
| `metadata` | `%{}` overrides | Merged over runtime metadata by key |

The model selector also accepts trusted `default_role`, `model_roles`, `session_selection`, `project_config`, and `project_approved` inputs at this explicit selection layer. Their meaning is the same as in the runtime table. Persisted state retains the resolved selection, not a durable copy of these input maps.

Session adapter/metadata maps override same-named runtime entries; they do not recursively merge the values under a key. The coordinator supplies its own runtime, coordinator, and Eval handles. Supplying `limits:` to `start_session/2` is not a per-session budget override: managed budgets come from runtime configuration.

New and restored managed contexts use `Context.new/1` field validation. Malformed permission values, host/service bindings, and Action modules fail with field-specific configuration errors rather than starting a half-configured agent. Session `tools` and `bundles` together return `{:error, {:conflicting_options, [:bundles, :tools]}}`; an invalid ID returns `{:error, :invalid_session_id}`. Native startup may wrap configuration failures; see the [API reference](api.md).

The standalone `OhMyJido.Context.new/1` constructor has a narrower default: `bundles: [:read_only]`. Do not confuse that with the managed session's full `Tools.default/0` fallback. Neither default grants permissions.

### Per-prompt configuration

A prompt can explicitly choose a role, model, and account; the new selection is retained for follow-up work. `tools:` may only narrow the session's registered list, otherwise it fails with `:tool_escalation`. `max_iterations:` is capped by the runtime ceiling.

Only `llm_opts`, `req_http_options`, `output`, `file_references`, and `file_ids` are forwarded as native request options. The transformer rejects inline credentials and credential lifecycle/file options. A prompt cannot replace runtime host/service policy. See [running tasks](../guides/running-tasks.md) for task-control APIs.

## What survives restore

A checkpoint preserves the session identity and its conversation, selected role/model/account, goal, plan, child records, run history, effect journal, retained events, agent checkpoint, and ContextPolicy state. It does not replay interrupted work.

| Configuration/state | Restore behavior |
|---|---|
| `workspace`, `permissions`, `role`, `account`, `model`, `goal`, `tools` | Retained as durable session options; the latest resolved selection is also retained |
| Resolved bundle Actions | Saved as `tools`, so a new runtime bundle does not silently change the session's availability |
| Metadata keys `git_repository_root`, `git_worktree_roots`, `delegation_roots`, `delegation_depth`, `project_instructions`, `skills`, `skill_roots` | Retained; other per-session metadata is not |
| ContextPolicy options, retained facts, summary, and tool records | Restored from the policy checkpoint; new runtime policy settings do not replace that saved policy |
| Per-session host/adapters, service PIDs, callback functions, arbitrary metadata, per-request options | Not persisted; rebuild service policy from current runtime configuration or your identity-based host/resolver |
| Subscribers, waiting callers/questions, active process/Eval resources, transient secret registry | Not restored as live handles |

Keep durable service configuration on the runtime or in your application's identity-based resolver. An adapter PID from a prior VM is not usable after restart. The saved metadata field `project_instructions` is not, by itself, the prompt composer's approved input: use trusted runtime `project_instructions` and `project_approved` settings.

See [sessions and recovery](../guides/sessions-and-recovery.md) for interrupted effects, reconciliation, and ContextPolicy checkpoint compatibility.

## ContextPolicy defaults

ContextPolicy compacts context extractively, without calling a model. Supply its options as a keyword list or map under runtime `context_policy:`. All six values must be positive integers.

| Option | Default | Meaning |
|---|---|---|
| `max_messages` | `80` | Compaction trigger, not a hard cap that can split exchanges |
| `keep_recent` | `16` | Recent messages protected during compaction; complete associated exchanges are also protected |
| `max_bytes` | `120_000` | Final projected-context byte budget |
| `summary_bytes` | `12_000` | Bounded archived transcript excerpts |
| `max_retained_bytes` | `64_000` | Budget for mandatory retained task facts |
| `max_tool_records` | `1_024` | Completed plus pending tool-identity/evidence records |

Mandatory facts and complete exchanges are protected. If they cannot fit, ContextPolicy fails instead of silently truncating them: `:context_budget_exceeded`, `:retained_context_too_large`, or `:context_tool_ledger_full`. Invalid options return `:invalid_context_policy_options`. See [sessions and recovery](../guides/sessions-and-recovery.md) for retained facts, exchange protection, and restore rules.

## Tool budgets

Set tool ceilings in runtime `limits: %{...}`. Integer runtime options form the initial `Context.limits`; the explicit `limits` map overrides same-named values. That map requires non-`nil`, non-boolean atom keys and non-negative integer values. Individual tools apply their own valid ranges, often requiring a positive value, and may impose a hard maximum. A request can lower its effective ceiling, not raise it.

These keys do not create a global memory quota, change the runtime's supervisor capacities, or provide OS containment.

### Files and subprocesses

| Key | Default | Scope |
|---|---|---|
| `max_file_bytes` | `8_388_608` | Complete file input or mutation |
| `max_read_bytes` | `262_144` | Returned read slice |
| `process_timeout_ms` | `tool_timeout_ms` (`30_000` by default) | Subprocess deadline ceiling |
| `max_output_bytes` | `1_048_576` | Retained subprocess bytes per stream, not a combined stdout/stderr cap |

### Search and list

| Key | Default | Scope |
|---|---|---|
| `search_max_results` | `200` | Retained matches/list entries |
| `search_max_output_bytes` | `131_072` | JSON bytes of retained entries |
| `search_max_discovery_bytes` | `1_048_576` | Discovery output |
| `search_max_files` | `10_000` | Files searched |
| `search_max_scan_bytes` | `33_554_432` | Total scan budget |
| `search_max_line_bytes` | `2_048` | Result line bytes |
| `search_timeout_ms` | `10_000` | Search deadline |
| `search_max_pattern_bytes` | `4_096` | Pattern bytes |
| `search_max_walk_entries` | `100_000` | Ignore-boundary traversal entries |
| `search_max_depth` | `64` | Ignore-boundary traversal depth |

### Language intelligence and extensions

| Key | Default | Scope |
|---|---|---|
| `ast_file_bytes` | `1_048_576` | Structural input; hard maximum is also 1,048,576 bytes |
| `ast_result_bytes` | `65_536` | Structural result bytes |
| `ast_max_results` | `1_000` | Structural ceiling; Action request default is 100 and hard maximum is 1,000 |
| `rename_max_files` | `128` | Elixir rename inventory files; also the hard maximum |
| `rename_max_bytes` | `8_388_608` | Elixir rename inventory bytes; also the hard maximum |
| `rename_max_file_bytes` | `1_048_576` | Elixir rename bytes per file; also the hard maximum |
| `rename_max_candidates` | `2_000` | Elixir rename candidate/semantic-query bound; also the hard maximum |
| `extension_input_bytes` | `32_768` | MCP and Tidewave request input |
| `extension_result_bytes` | `65_536` | Structured extension/tool result bytes; individual adapters may add hard ceilings |
| `protocol_frame_bytes` | `1_048_576` | Stdio LSP/DAP/MCP frame ceiling |
| `protocol_timeout_ms` | `10_000` | Stdio protocol request timeout |
| `protocol_pending_timeout_ms` | `300_000` | Pending asynchronous protocol-request lifetime |
| `artifact_input_bytes` | `33_554_432` | Artifact input ceiling; Action request default is 8,388,608 bytes |
| `artifact_output_bytes` | `131_072` | Artifact output ceiling; Action request default is 8,192 bytes |
| `browser_output_bytes` | `131_072` | Browser text ceiling; Action request default is 8,192 bytes |
| `research_output_bytes` | `131_072` | Research text ceiling; Action request default is 8,192 bytes |
| `review_diff_bytes` | `262_144` | Review diff ceiling; Action request default is 65,536 bytes |
| `review_findings` | `100` | Review finding ceiling; Action request default is 50 |
| `skill_bytes` | `262_144` | Loaded skill guidance |

### Delegation and experiments

| Key | Default | Scope |
|---|---|---|
| `max_experiment_trials` | `8` | Experiment trial count; each trial executes once |
| `max_subagent_depth` | `2` | Child-depth guard; child permissions remove `:delegate` |
| `claude_prompt_bytes` | `65_536` | Official Claude Code delegation prompt |
| `claude_timeout_ms` | `120_000` | Claude subprocess deadline ceiling, further constrained by process/runtime limits |
| `claude_output_bytes` | `262_144` | Claude output ceiling per stream, further constrained by the process ceiling |

QuickBEAM's engine budgets and Eval's separate keyword limits are not set by this map. See [Eval](../guides/eval.md). Tool-specific request limits and truncation/result behavior are described in [tools](../guides/tools.md), [language intelligence](../guides/language-intelligence.md), and [integrations](../guides/integrations.md).

## Limits

- Runtime configuration is trusted application authority. Do not evaluate repository files as configuration or let a prompt replace host/service settings.
- A default is not a capacity promise. Choose limits for your deployment and apply OS isolation separately when needed.
- Session persistence is not credential storage. Keep the account vault and encryption key service separate from session data.

## Related

- [Getting started](../getting-started.md)
- [Models and accounts](../guides/models-and-accounts.md)
- [Sessions and recovery](../guides/sessions-and-recovery.md)
- [Permissions and approvals](../guides/permissions-and-approvals.md)
- [Eval](../guides/eval.md)
- [API reference](api.md)
- [Production operations](../operations.md)
