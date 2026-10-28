# Choose models and accounts

Choose the model that does the work, the account that authorizes it, and the billing mode your application allows. Use a credentials resolver for API keys, the account broker for OpenAI Sign in with ChatGPT, or the official Claude Code adapter to delegate to a separate agent.

## Keep three decisions separate

| Decision | What you select | What it does not do |
|---|---|---|
| Model | A ReqLLM model input, such as `"anthropic:claude-sonnet-4-6"` | Sign in, choose an account, or approve spending |
| Account | An opaque reference, such as `"anthropic"`, that your resolver understands | Carry an API key, token, or credential-file path |
| Billing mode | An API account or an eligible subscription account that your application has authorized | Fall back to another account or billing mode when a request fails |

Oh-My-Jido uses Jido.AI for the model/tool loop and ReqLLM for provider encoding and transport. Before every production model request, `OhMyJido.Models.Transformer` validates the selection and obtains fresh credentials from your application's host policy. Direct tool calls and idle sessions need no provider account. Starting a runtime does not enroll an account or send a model request.

An account reference can be a nonempty string, a non-boolean/non-`nil` atom, an integer, or a nonempty tuple of those values. Maps, PIDs, and credential records are rejected. `nil` can explicitly select no account, but a production model request then fails with `:account_required`.

Account failure, exhausted plan limits, or subscription ineligibility never select a different identity or a metered API key. If the user approves API billing instead, your application must explicitly select the API account and a matching model.

## Use an API-key account

A credentials resolver is your module with `resolve(context, account, options)`. It returns explicit ReqLLM inference options for the selected account. This is the resolver from [getting started](../getting-started.md#5-connect-a-model): it supports one application-approved Anthropic API account and reads the key from an environment variable.

```elixir
defmodule MyApp.ModelCredentials do
  def resolve(_context, "anthropic", _options) do
    {:ok, [api_key: System.fetch_env!("ANTHROPIC_API_KEY")]}
  end

  def resolve(_context, _account, _options), do: {:error, :unknown_account}
end
```

Configure the resolver on the supervised runtime:

```elixir
children = [
  {OhMyJido, name: MyApp.Coding, credentials: {MyApp.ModelCredentials, []}}
]
```

Then select the model and account when you open a session:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    permissions: [:read],
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic"
  )
```

The module and account names are application-specific. Return an atom such as `:unknown_account` to refuse an account: the run fails with that reason. Atom errors and `OhMyJido.Auth.Error` values pass through, the latter in sanitized form. A raised exception, such as `System.fetch_env!/1` finding no variable, or any other error value becomes `:credential_service_failed`. Each account your application offers needs its own clause. In a multi-account application, look the account up in your own secret service and return an error when it is unavailable or billing consent is absent. Do not search for a fallback key. The example reads the environment because the resolver chooses to; Oh-My-Jido never discovers credentials itself.

### Pass options to the resolver

The second element of the `credentials:` tuple reaches `resolve/3` as `options`. For example, to choose the environment variable in configuration rather than code:

```elixir
defmodule MyApp.ModelCredentials do
  def resolve(_context, "anthropic", options) do
    case System.get_env(Keyword.fetch!(options, :api_key_env)) do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, [api_key: key]}
      _missing -> {:error, :credentials_required}
    end
  end

  def resolve(_context, _account, _options), do: {:error, :unknown_account}
end

# In your supervision tree:
{OhMyJido, name: MyApp.Coding, credentials: {MyApp.ModelCredentials, api_key_env: "MYAPP_ANTHROPIC_API_KEY"}}
```

The runtime checks that the resolver exports `resolve/3`, but does not call it at startup. The `credentials:` option is a shortcut for `OhMyJido.Host.Local`; the equivalent nested setting is `host: {OhMyJido.Host.Local, credentials: {MyApp.ModelCredentials, options}}`. Combining the shortcut with a custom host raises an `ArgumentError`. A custom host supplies credentials through its own `credentials/3` callback instead; see [permissions and approvals](permissions-and-approvals.md).

### Return one credential mode

| Mode | Resolver result | Rule |
|---|---|---|
| API key | `{:ok, [api_key: key]}` | A nonempty key; `auth_mode: :api_key` is the default |
| OAuth | `{:ok, [auth_mode: :oauth, access_token: token]}` | A nonempty access token and explicit OAuth mode |

Never return both an API key and an OAuth access token. Keep refresh tokens, identity tokens, client secrets, expiry/lifecycle records, and credential-file imports in your account service, not in inference options. Resolver-returned generation preferences must also be appropriate for the selected provider. For OpenAI subscription use, prefer the broker below: it returns the additional subscription-profile options, not only an access token.

Do not pass secrets, Authorization headers, credential maps, or auth-file paths through `start_session/2`, `prompt/3`, a model input, or project configuration. Do not call `ReqLLM.put_key/2` to select a session account, or log/serialize resolver results or `OhMyJido.Auth.credentials/2` results.

### Use a provider that needs no credential

A ReqLLM provider that never sends a credential declares it by exporting `credentials_required?/0` returning `false`. [`web_llm`](../../packages/web_llm/README.md)'s `:web_llm` provider, which runs models on the user's GPU, is one. Requests to such a provider skip account selection and the resolver entirely, so no key is resolved, registered or sent, even when the session's account belongs to another provider:

```elixir
OhMyJido.start_session(MyApp.Runtime,
  workspace: "/srv/workspace",
  model: WebLLM.model("Qwen3-8B-q4f16_1-MLC")
)
```

Every other provider still needs an explicit credential from your resolver. A provider that does not declare `credentials_required?/0` is never treated as keyless, so ReqLLM cannot fall back to an ambient key.

### Configure ReqLLM before making requests

Set these application-level options in your own configuration:

```elixir
import Config

config :req_llm, debug: false, load_dotenv: false
```

The production transformer requires `ReqLLM.Debug.enabled?() == false` before it resolves credentials. Explicit `debug: false` also overrides `REQ_LLM_DEBUG` in the environment. ReqLLM otherwise defaults to loading a `.env` file at application startup; `load_dotenv: false` prevents that import. These are application-wide dependency settings, not per-session switches. See [security](security.md) for the diagnostic and redaction boundary.

## Choose a model for a session or prompt

Use `model:` for a specific selection. Provider-qualified model strings avoid reliance on global aliases. A later application-submitted prompt can explicitly select another approved model/account pairing:

```elixir
{:ok, run_id} =
  OhMyJido.prompt(session, "Review the current change without editing it",
    role: :review,
    model: "anthropic:claude-sonnet-4-6",
    account: "anthropic-review"
  )
```

That account must already exist in your credential service, have its own clause in your resolver, and match the model's provider and access method. The selected role, model, and account are retained for follow-up work. Changing to a review role does not remove editing permission; configure the session's tools and permissions separately. See [running tasks](running-tasks.md) for the rest of the run lifecycle.

**On master, explicitly select an active model before inference.** The bare Jido 2.4-stack aliases `:capable`, `:planning`, and `:thinking` still resolve to `"anthropic:claude-sonnet-4-20250514"`, which the installed catalog marks retired with no capability metadata. `:fast` resolves to `"anthropic:claude-haiku-4-5"`. Use an active provider-qualified model or configure all needed roles/aliases at startup. Oh-My-Jido does not silently rewrite dependency aliases.

## Model roles

A role supplies task guidance and selects a configured model. `OhMyJido.Models.roles/0` returns the six roles below. Roles do not grant or remove permissions.

| Role | Guidance | Bare-library default on this branch |
|---|---|---|
| `:coding` | Implement targeted changes; inspect existing patterns and report checks actually run | `:capable` |
| `:planning` | Find integration boundaries, dependencies, risks, and acceptance criteria | `:planning` |
| `:exploration` | Investigate read-only and report concrete code paths, evidence, and unknowns | `:fast` |
| `:review` | Report concrete findings in severity order; separate defects from style | `:capable` |
| `:advisor` | Explain trade-offs and consequences without taking control of the task | `:thinking` |
| `:compaction` | Preserve goals, constraints, facts, memory, unresolved work, and effect records | `:fast` |

Configure role models in your application's `config/config.exs`, or put the same options on a runtime child for instance-specific choices:

```elixir
import Config

config :oh_my_jido,
  default_role: :coding,
  account: "anthropic",
  model_roles: %{
    coding: "anthropic:claude-sonnet-4-6",
    planning: "anthropic:claude-sonnet-4-6",
    exploration: "anthropic:claude-haiku-4-5",
    review: "anthropic:claude-sonnet-4-6",
    advisor: "anthropic:claude-sonnet-4-6",
    compaction: "anthropic:claude-haiku-4-5"
  }
```

Each `model_roles` entry can instead be `%{model: input, account: reference}` to associate a role with an account. The map or a keyword list can hold the role entries. A direct `model:` takes precedence over a role entry in the same layer when it applies to the selected role.

The repository's own configuration uses optional aliases: `:capable` for coding, planning, review, and advisor; `:fast` for exploration and compaction. A consuming application does not import this repository's configuration. To use those aliases, configure them in your application:

```elixir
config :jido_ai,
  model_aliases: %{
    capable: "anthropic:claude-sonnet-4-6",
    fast: "anthropic:claude-haiku-4-5"
  }
```

ContextPolicy is an extractive compactor: it keeps important facts and complete tool exchanges without another model call. Configuring a `:compaction` model does not cause automatic compaction-model requests.

### Selection precedence

Role, model, and account selection use the following layers, from highest to lowest priority. Model and account are selected independently, so explicitly choose both when changing providers or billing modes.

| Priority | Layer |
|---|---|
| 1 | Explicit session or prompt options |
| 2 | Retained `session_selection`, normally the session's previous selection |
| 3 | Approved declarative `project_config` |
| 4 | Runtime `user_config` |
| 5 | Application/runtime defaults, then the bare-library role defaults above |

A retained direct model only applies to its matching role. An explicit account, including `nil`, can override a role entry's account. Invalid selected models or aliases fail instead of falling through to a lower-priority selection.

Approve a project selection through trusted runtime configuration, for example:

```elixir
config :oh_my_jido,
  project_config: %{
    approved: true,
    config: %{
      model_roles: %{
        review: %{
          model: "anthropic:claude-sonnet-4-6",
          account: "anthropic-review"
        }
      }
    }
  }
```

The `"anthropic-review"` account also needs its own resolver clause. Without `approved: true`, the envelope is ignored. A plain declarative project map instead needs the trusted `project_approved: true` setting. Project configuration cannot contain executable callbacks or process handles. The selector never reads or evaluates a repository's `config.exs`, grants account access, or queries a provider's live model catalog. `Models.resolve/1` and `Models.describe/1` validate installed Jido/ReqLLM metadata; local recognition does not guarantee current provider access.

## Use OpenAI Sign in with ChatGPT

The OpenAI broker implements the documented [open-source token-sharing route](https://developers.openai.com/siwc/token-sharing-open-source.md). It does not impersonate an official client, import a Codex login, or use the installed Codex `backend-api` endpoint. `OhMyJido.Auth.OpenAI` performs authentication HTTP; inference still uses ReqLLM's public OpenAI Responses encoder and HTTP/SSE transport.

Your application owns the browser UI, loopback callback listener, consent, and account picker. Supervise the broker explicitly before connecting it to a runtime.

### Supervise the broker and credential vault

This supervisor accepts a vault configuration and trusted provider options from your application:

```elixir
defmodule MyApp.AccountSupervisor do
  use Supervisor

  def start_link(options), do: Supervisor.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    children = [
      {Task.Supervisor, name: MyApp.AccountTasks},
      {OhMyJido.Auth,
       name: MyApp.AccountBroker,
       task_supervisor: MyApp.AccountTasks,
       store: Keyword.fetch!(options, :store),
       provider_options: Keyword.get(options, :provider_options, [])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

The reference vault is `OhMyJido.Auth.FileStore`. Supply `vault_key_provider`, a zero-argument function that retrieves the same random 32-byte encryption key from your secret service across restarts. Also supply `persisted_host_id`, the stable installation identifier described in the next section:

```elixir
children = [
  {MyApp.AccountSupervisor,
   store: {OhMyJido.Auth.FileStore,
     path: "/srv/my_app/account_vault", key: vault_key_provider},
   provider_options: [host_id: persisted_host_id]},
  {OhMyJido,
   name: MyApp.OpenAICoding,
   credentials: {OhMyJido.Auth, broker: MyApp.AccountBroker}}
]
```

Those variables are values supplied by your application, not library defaults. `MyApp.AccountBroker` is your chosen supervised name. Starting it or the runtime does not begin login.

FileStore uses AES-256-GCM with the account reference as authenticated data, atomic mode-0600 files, and a mode-0700 directory. It does not derive a key from a password or persist the encryption key. The implementation accepts a literal 32-byte key, but do not put one in repository configuration or a visible child specification. Wrong keys, renamed records, tampered ciphertext, and unsafe file permissions fail rather than exposing an account.

Keep the vault separate from the `Jido.Storage.File` session store, editable repositories, build artifacts, and deployment images. The session store contains private conversation data; it is not a credential vault and does not encrypt itself. Protect backups and the key service. Vault handles and callbacks are privileged application data, not agent tools.

| Broker option | Default | Meaning |
|---|---|---|
| `name` | Unnamed | OTP name used by your application |
| `store` | Required | `{VaultModule, options}` implementing `OhMyJido.Auth.Vault` |
| `task_supervisor` | Required | Your supervised `Task.Supervisor` for network operations |
| `provider` | `OhMyJido.Auth.OpenAI` | Authentication adapter |
| `provider_options` | `[]` | Trusted auth configuration; startup values override same-named login options |
| `clock` | System time in seconds | Zero-argument clock function |
| `refresh_before` | `60` seconds | Refresh credentials this long before expiry |
| `operation_timeout` | `30_000` ms | Supervised network-operation deadline |
| `max_pending` | `256` | Bound on pending attempts/operations and joined refresh waiters |

Discovery, login, refresh, and revocation run outside the broker's GenServer, under the supplied task supervisor. Concurrent refresh requests for the same account share one operation. Your UI still needs to remain responsive while calls complete; the broker is not a web server or interactive login UI.

### Begin and complete a human login

Before beginning login:

1. Start and own the loopback listener that will receive the callback.
2. Persist a stable opaque `host_id` for the installation. Use one of the provider's accepted formats: an RFC 9278 JWK-thumbprint URI, `urn:uuid:` followed by a hyphenated UUIDv4, or `did:key:`. A label, bare UUID, email, or user ID is not a substitute. Your application is responsible for choosing that format; the adapter checks nonempty values and binding consistency, not the full host-ID format.
3. Supply a human-readable `app_name` and the actual callback URL.

Bind an explicit port from 1–65,535. The adapter accepts an HTTP callback on literal `127.0.0.1` with a nonempty path and no userinfo, query, or fragment. `localhost`, other addresses, and HTTPS callbacks are not supported. Reuse the installation ID across restarts; it is an identity binding, not a credential.

```elixir
{:ok, attempt} =
  OhMyJido.Auth.begin_login(MyApp.AccountBroker,
    app_name: "MyApp coding assistant",
    host_id: persisted_host_id,
    redirect_uri: "http://127.0.0.1:4010/callback"
  )
```

`attempt` contains `%{attempt_ref: reference, authorization_url: url}`. Display or open that URL only in the approved human interface, and keep `attempt_ref` private. Beginning login neither opens a browser nor gives consent or chooses an account for the user. Returning-login URLs can contain identity hints, so do not put them in routine telemetry.

When the real callback arrives at that listener, pass it unmodified to the broker:

```elixir
{:ok, account} =
  OhMyJido.Auth.complete_login(MyApp.AccountBroker, attempt.attempt_ref, actual_callback)

{:ok, accounts} = OhMyJido.Auth.list_accounts(MyApp.AccountBroker)
```

`actual_callback` is the received callback URL or a callback map. A URL must use the exact registered redirect before its query string; a map must include that exact `redirect_uri`. The broker consumes the attempt once. The provider checks expiry, state, S256 PKCE, nonce, issuer, audience/client, subject, and host/redirect bindings. Attempts last 600 seconds. New login uses dynamic registration; returning login and refresh retain the issued client and host identity.

Requested scopes are `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`; the resource is `https://api.openai.com/v1`. Both `resource.invoke` and `chatgpt.tokens.use.direct` must remain granted at login and refresh. An incomplete grant produces a `:consent_required` account, not active inference access. For returning login, pass `account_ref: existing_reference`; add `consent: true` when requesting consent again. Use a separate human login attempt to add another account.

A host ID supplied only at login is retained in the protected record for later refresh and revocation. An explicitly configured startup binding remains authoritative: conflicts or invalid values fail rather than replacing it. Transient login HTTP options are not persisted.

After the returned account is active, use its opaque reference in a session:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.OpenAICoding,
    workspace: "/path/to/project",
    permissions: [:read],
    model: "openai:gpt-6-luna",
    account: account.account_ref
  )
```

The model must be recognized locally and available to that account. The broker's credential resolver applies the subscription profile automatically.

### List accounts, cancel login, and log out

| Call | Result |
|---|---|
| `Auth.begin_login(broker, options \\ [])` | `{:ok, %{attempt_ref: ref, authorization_url: url}}` or `{:error, %Auth.Error{}}` |
| `Auth.complete_login(broker, ref, actual_callback)` | `{:ok, account_metadata}` or `{:error, %Auth.Error{}}`; the callback is consumed once |
| `Auth.cancel_login(broker, ref)` | `:ok`; cancels an unused/in-flight attempt without logging out an existing account |
| `Auth.list_accounts(broker)` | `{:ok, sorted_metadata_list}`; no tokens or vault records |
| `Auth.credentials(broker, account_ref)` | `{:ok, inference_options}` or typed error; privileged application use only |
| `Auth.logout(broker, account_ref)` | `{:ok, logout_result}` or typed local failure |

Here `Auth` means `OhMyJido.Auth`. Account metadata is limited to `account_ref`, `provider`, `access_mode`, `status`, `expires_at`, `generation`, and `scopes`.

```elixir
{:ok, logout_result} = OhMyJido.Auth.logout(MyApp.AccountBroker, account.account_ref)
```

Logout first persists a new generation with local credentials invalidated, so late login/refresh work cannot restore them. Inspect both fields of `logout_result`: `local: :logged_out` is separate from `remote: :revoked`, `:not_requested`, or `:unconfirmed`. An unconfirmed remote result includes an `error`. Local success is not proof of remote revocation.

### Subscription request limits

A subscription account accepts the inputs and options below. It uses ReqLLM's streaming OpenAI Responses support, but does not accept every option available to a metered API-key account.

| Setting or capability | Subscription behavior |
|---|---|
| Endpoint and authentication | Public `https://api.openai.com/v1`, OAuth access token; no alternate API base URL |
| Transport and state | Streaming HTTP/SSE, `store: false`, zero request retries, metadata-only telemetry; no WebSocket reuse or server continuation state |
| Tools | Registered function tools, with schemas, call IDs and results handled by ReqLLM; unsupported built-in tools are errors |
| Input | Text, image and file parts supported by ReqLLM; unsupported media/input is rejected rather than silently omitted |
| Generation preferences | Explicit output-token caps, temperature/top-p, background/conversation state, metadata, audio/modalities, unsupported built-in tools, and stored responses are errors |
| Omitted generation preferences | You can leave them unset. The library removes its own incompatible defaults, but rejects explicit unsupported preferences instead of silently discarding them. |

Do not copy a metered OpenAI request configuration into a subscription task and assume feature parity. Safe failures retain allowlisted machine codes and any supplied HTTP status, request ID, retry-after, eligibility, and quota. A stream failure with no observed HTTP status stays statusless. `retryable: true` is diagnostic information, not permission to retry automatically.

Examples of specific failures include `:subscription_sharing_user_not_eligible`, `:subscription_sharing_usage_limit_exceeded`, `:subscription_sharing_unsupported_capability`, `:chatpass_v2_scope_not_authorized`, `:credentials_expired`, `:consent_required`, and `:reauth_required`.

## Delegate to official Claude Code

Use `OhMyJido.Tools.ClaudeCode` when the user wants a finite task handled by their unmodified official Claude Code installation. This is a separate agent, not a Claude subscription account inside the native Jido model loop. Oh-My-Jido does not broker third-party Claude.ai OAuth tokens or impersonate Claude Code; review Anthropic's [legal and compliance policy](https://code.claude.com/docs/en/legal-and-compliance). Native Anthropic API inference remains a separate, metered choice.

Approve the installation and record its executable SHA-256 outside model input. This configuration exposes a read-only delegation tool:

```elixir
claude_options = [
  executable: "/opt/claude/claude",
  sha256: approved_sha256,
  official_binary: true,
  tools: ["Read", "Glob", "Grep"],
  max_turns: 8,
  timeout: 120_000,
  max_output_bytes: 262_144
]

children = [
  {OhMyJido,
   name: MyApp.ClaudeCoding,
   tools: [OhMyJido.Tools.ClaudeCode],
   adapters: %{claude_code: {OhMyJido.Tools.ClaudeCode, claude_options}},
   tool_timeout_ms: 120_000}
]

{:ok, session} =
  OhMyJido.start_session(MyApp.ClaudeCoding,
    workspace: "/path/to/project",
    permissions: [:claude_code, :read],
    model: "anthropic:claude-sonnet-4-6"
  )

{:ok, delegated} =
  OhMyJido.execute_tool(session, "claude_code", %{prompt: "Summarize this project's structure"})
```

`approved_sha256` is the 64-hex-character digest reviewed by your application administrator; the path is your installed executable. A matching hash checks that bytes have not changed since approval, not vendor provenance. Your application must verify the complete installation/distribution and administrator policy. Configure [approval handling](permissions-and-approvals.md) before invoking the tool: status and delegation subprocesses are sensitive effects.

| Adapter option | Default | Meaning |
|---|---|---|
| `executable` | Required | Absolute path to the official executable |
| `sha256` | Required | Host-reviewed SHA-256, 64 hexadecimal characters |
| `official_binary` | Must be `true` | Your application's explicit attestation |
| `tools` | `[]` | Exact subset in the table below; unknown tools fail |
| `model` | Unset | Optional nonempty model name supported by the installed CLI, not a ReqLLM model input |
| `max_turns` | `8` | CLI turn bound, valid from 1 to 100 |
| `timeout` | `120_000` ms | Requested subprocess deadline |
| `max_output_bytes` | `262_144` | Requested retained output cap per stream |

Runtime/process limits can shorten the requested deadline and output cap. In an otherwise default runtime, the process deadline falls back to the 30,000 ms `tool_timeout_ms`. The example explicitly raises that runtime setting to 120,000 ms. See [tool budgets](../reference/configuration.md#tool-budgets) for the additional `claude_*` ceilings.

| Official tool | Required session permission in addition to `:claude_code` |
|---|---|
| `Read`, `Glob`, `Grep` | `:read` |
| `Edit`, `Write` | `:edit` |
| `Bash` | `:exec` |

The agent request contains only `%{prompt: binary}`. Executable, digest, tools, and model come from trusted adapter configuration. Before delegating, the adapter runs the official `auth status` and accepts only `claude.ai` subscription authentication. API-key, helper, cloud-provider, and imported-token methods are rejected. It starts no login and reads/imports no CLI credential files or tokens. The official binary uses its own current OS-user login; neither `Context.account` nor the OpenAI vault selects that login. Isolate that OS identity in a multi-user application.

The CLI must support `--restricted` and `--permission-prompts` (v2.1.259+). Tested with Claude Code 2.1.282; its documented aliases include `fable`, `sonnet`, and `opus`, so do not assume a `haiku` CLI alias. Invocation uses restricted/safe mode, JSON print output, no session persistence, manual permission mode, permission prompts set to `none`, strict empty MCP configuration, no MCP tools, no slash commands, and no Chrome. The exact approved tool subset is passed both as available tools and as the permission allowlist. Administrator deny policy still applies, and unanswered permission prompts are denied rather than bypassed.

Each child removes the known metered/provider environment overrides without changing your application's environment, including API-key/token overrides, provider/base-URL/model overrides, cloud-provider switches, and fallback-model settings. The complete list is in the [adapter source](../../lib/oh_my_jido/tools/claude_code.ex).

A successful result reports `integration: :official_claude_code`, `native_jido_loop: false`, `auth_method: :claude_ai`, the selected tools, the answer, and allowlisted usage counts. Claude's tool calls are not routed through Jido. Its turn accounting, permissions, and output remain those of a separate agent. A completed answer is not proof that an edit happened: check the resulting files and relevant tests independently. A timeout or cancellation cannot undo earlier file or network effects.

## Common setup failures

These are the underlying reason codes; the calling API may wrap them. See the [API reference](../reference/api.md) for complete return shapes.

| Reason | What to fix |
|---|---|
| `:invalid_role`, `:invalid_model`, `:invalid_model_roles` | Choose a supported role and a locally valid model/role mapping |
| `:invalid_account_reference`, `:account_required` | Select an opaque account reference, not credentials or `nil` |
| `:credentials_required` | Configure a resolver and provision the selected account |
| `:explicit_credentials_required` | Return one valid API-key or OAuth mode |
| `:credentials_must_come_from_host` | Remove inline credentials from request/model configuration |
| `:credential_lifecycle_options_not_allowed` | Keep refresh/identity/file records in the account service |
| `:unsafe_model_debug_configuration` | Disable ReqLLM debug before resolving credentials |
| `:credential_service_failed`, `:secret_registration_failed` | Repair the configured credential service or managed secret-registry boundary |
| `:claude_subscription_login_required` | Sign in through the official CLI using its accepted subscription method |
| `:official_claude_code_required`, `:claude_binary_changed` | Review the official installation and its configured digest |

## Subscription encoding reference

These details matter when calling `OhMyJido.Models.Subscription` directly or inspecting its wire format:

| Contract | Behavior |
|---|---|
| Request hook | Reshapes an already encoded Responses body. ReqLLM still owns the HTTP client, SSE decoder, tool schemas, call IDs and responses. The hook does not refresh credentials or retry effects. |
| Wire tools | Function/custom wire tools are sent as developer additional tools. This wire representation does not grant permission or add tools to the session. |
| Generated defaults | Jido's generic defaults are removed only when identified separately through `generated_options:` and disallowed by the subscription configuration. Explicit user preferences are validated, not silently erased. |

## Limits

- Local model metadata is not a provider availability or subscription-eligibility guarantee. Check the selected account's access before offering a model to users.
- The OpenAI subscription profile is narrower than the metered Responses API. Subscription access and metered API access are not interchangeable.
- Official Claude Code delegation is not full third-party Claude subscription parity or a native Jido subscription loop.
- Credentials and account lifecycle are application infrastructure, not model-facing tools. Keep their results out of conversations, UI exports, and routine logs.

## Related

- [Runtime configuration and defaults](../reference/configuration.md)
- [Running tasks](running-tasks.md)
- [Permissions and approvals](permissions-and-approvals.md)
- [Security](security.md)
- [Session persistence and recovery](sessions-and-recovery.md)
- [API reference](../reference/api.md)
- [Current verification status](../project-status.md)
