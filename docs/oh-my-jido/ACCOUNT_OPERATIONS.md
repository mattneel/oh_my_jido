# Accounts, subscription access and explicit API billing

Models, accounts and billing modes are different decisions. Selecting a model or granting `:exec` does not authorize enrollment, token import, paid API usage or another application's credential files. Oh-My-Jido obtains inference credentials from its configured host **per native model turn**. Only an opaque account reference belongs in the session.

The native implementation is Jido.AI ReAct → `Models.Transformer` → ReqLLM. The transformer validates model/tool choices, rejects inline credentials, obtains fresh host credentials, registers transient known-secret redaction, applies the native subscription profile where selected and compacts context. It is not a new HTTP/SSE client.

## Choose roles and accounts without a billing fallback

The six roles and selection precedence are in [configuration](RUNTIME_CONFIGURATION.md#six-native-model-roles-and-account-selection). A host may select another approved account/model on a subsequent prompt:

```elixir
{:ok, run} =
  OhMyJido.prompt(session, "Review the current change without editing it",
    role: :review,
    account: "host-approved-review-account"
  )
```

The account must already exist in the host service and match the selected provider/access method. Using a review role does not remove edit grants; narrow tools/grants explicitly. Account failure, plan limits or subscription ineligibility never choose a metered API key or another identity. Switching to API billing is a new host/user decision with an explicitly selected API account.

Do not pass `api_key`, OAuth token, Authorization header, credential map or credential-file path in `start_session/2`, `prompt/3`, a model input or repository configuration. Inference options must not contain refresh/identity tokens, OAuth lifecycle records or credential-file imports. Do not serialize or log `Auth.credentials/2` results.

## Supervise the OAuth broker explicitly

`OhMyJido.Auth` delegates account lifecycle to `Auth.Broker`. The host supplies an actual `Auth.Vault` and a `Task.Supervisor`; nothing reads existing Codex/Claude authentication files. This complete host supervisor accepts trusted vault/provider configuration rather than inventing a secret service:

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
       provider_options: Keyword.fetch!(options, :provider_options)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

The reference vault configuration is `{OhMyJido.Auth.FileStore, path: private_directory, key: host_key_provider}`. `host_key_provider` is a zero-argument function returning the **same random 32-byte encryption key** from the host's secret service across restarts. A literal 32-byte key is accepted by the implementation but is inappropriate in repository configuration or a visible child specification. The reference vault uses AES-256-GCM, account-reference authenticated data, atomic mode-0600 files and a mode-0700 directory. It neither derives a password key nor persists the key. Wrong-key, renamed-record, tampered-ciphertext and permission failures fail closed.

Keep that vault separate from `Jido.Storage.File`, repositories, build artifacts and Elixos generation images. Protect host backups and the secret service. Auth.Vault callbacks/handles are privileged host data; the model sees no vault API.

Source defaults for the broker are provider `Auth.OpenAI`, `refresh_before: 60` seconds, `operation_timeout: 30_000` milliseconds and `max_pending: 256`. The default clock is system time in seconds. `provider_options` belong to trusted host auth configuration; a task cannot override them. Discovery/login/refresh/revocation network work uses the supplied supervised-operation boundary; initial discovery is no longer performed inside the broker's call handler. Account refresh is single-flight per account. Logout persists a new generation/local invalidation before remote revocation so late login/refresh work cannot restore logged-out credentials.

Connect the broker to the Runtime's reference host with:

```elixir
host: {OhMyJido.Host.Local, credentials: {OhMyJido.Auth, broker: MyApp.AccountBroker}}
```

## Human-initiated OpenAI Sign in with ChatGPT

The implementation follows the documented [open-source token-sharing/SIWC route](https://developers.openai.com/siwc/token-sharing-open-source.md), not an official client's identity or the installed Codex `backend-api` endpoint. Authentication HTTP is confined to the OpenAI auth adapter; inference remains the public OpenAI Responses encoder/transport in ReqLLM.

The host owns the browser, loopback listener, user consent, account picker and callback handling. Before calling `begin_login/2`, start the listener and persist a stable opaque installation `host_id` in one of OpenAI's [accepted formats](https://developers.openai.com/siwc/token-sharing-open-source.md): an RFC 9278 JWK-thumbprint URI, `urn:uuid:` followed by a hyphenated UUIDv4, or `did:key:`. A bare label, unprefixed UUID, email or user ID is not a host ID for this flow. Reuse the identifier for the host's lifecycle; it is not a credential. Supply a human-readable `app_name`. The implemented redirect is an HTTP URL on literal `127.0.0.1`, an explicit port from 1–65,535 and a nonempty path, with no userinfo/query/fragment. `localhost`, another address and HTTPS callback URLs are not this adapter's contract.

```elixir
{:ok, attempt} =
  OhMyJido.Auth.begin_login(MyApp.AccountBroker,
    app_name: "MyApp coding assistant",
    host_id: persisted_host_id,
    redirect_uri: "http://127.0.0.1:4010/callback"
  )
```

This example assumes the host listener actually owns that endpoint. `attempt` is `%{attempt_ref: reference, authorization_url: url}`. Display/open the URL only in the approved human interface, and retain the attempt reference privately. Beginning login does not open a browser, receive consent or choose an account on behalf of the user. An authorization URL may contain identity hints on returning login: it is not routine telemetry.

After receiving the actual callback at the exact bound listener, pass the **unmodified callback** to `complete_login/3`. A callback map must contain the exact `redirect_uri`; a URL callback must begin with the exact registered redirect. The provider validates one-shot attempt consumption, expiry, state, S256 PKCE, nonce, issuer, audience/client, subject and host/redirect bindings. New sign-in uses dynamic registration; returning sign-in/refresh retain the issued client and host identity. Requested scopes are `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`; resource is `https://api.openai.com/v1`. Attempt validity is 600 seconds.

| Auth call | Result/ownership |
|---|---|
| `begin_login(broker, options \\ [])` | `{:ok, %{attempt_ref: ref, authorization_url: url}}` or typed error |
| `complete_login(broker, ref, actual_callback)` | `{:ok, allowlisted_account_metadata}` or typed error; callback consumed once |
| `cancel_login(broker, ref)` | `:ok`; cancels unused/in-flight attempt without logging out existing accounts |
| `list_accounts(broker)` | `{:ok, sorted_metadata_list}`; no tokens, raw identity tokens or vault records |
| `credentials(broker, account_ref)` | Privileged fresh explicit native options or typed error; never expose this result to agents/UI |
| `logout(broker, account_ref)` | Separately reports local logout and remote revocation/not-requested/error; a local success is not a remote-revocation assertion |

For another account, begin a separate human sign-in attempt. For returning login, supply `account_ref` selecting the existing account; `consent: true` requests consent when needed. Revocation/expiry/consent errors remain specific failures, not billing-switch triggers. Hosts must keep login/callback UI responsive while network work completes; do not treat the broker as an interactive UI or a web server.

Both `resource.invoke` and `chatgpt.tokens.use.direct` must remain granted at login and refresh; incomplete consent never becomes an active inference account. A validated login-only `host_id` is retained in the protected account record and used for later refresh/revocation when no startup binding was configured. An explicit configured binding is authoritative: conflicts or invalid values fail closed, rather than being overwritten. Transient login HTTP options are not persisted.

### Subscription inference profile and limits

The broker returns `Models.Subscription.options/1` inside the privileged host boundary. `configure/3` uses ReqLLM's provider registry, public OpenAI Responses encoder, HTTP/SSE transport and existing request hook. The hook modifies an already encoded body; it does not send HTTP, implement SSE, refresh credentials or retry effects.

The preview profile is explicit: public `https://api.openai.com/v1`, OAuth access token, streaming HTTP/SSE, `store: false`, zero request retries and metadata-only telemetry. Function/custom tools are developer additional tools; model-call IDs and responses still come from ReqLLM. The profile supports the allowed native message/image/file parts and fails for unsupported original input before an encoder can drop it.

User-supplied unsupported preferences are errors, not silently erased. Examples include output-token caps, temperature/top-p, background/conversation/server continuation state, metadata, audio/modalities, unsupported built-in tools, stored responses, a different API base URL and WebSocket reuse. Generated generic Jido defaults are identified separately and removed where the preview disallows them. Do not copy a regular metered OpenAI request configuration into a subscription task and assume parity.

Safe diagnostics preserve allowlisted machine codes, HTTP status, request ID, retry-after, eligibility and quota when the provider actually supplies them. Examples include `:subscription_sharing_user_not_eligible`, `:subscription_sharing_usage_limit_exceeded`, `:subscription_sharing_unsupported_capability`, `:chatpass_v2_scope_not_authorized`, `:credentials_expired`, `:consent_required` and `:reauth_required`. A statusless stream failure remains statusless; no HTTP success is fabricated. `retryable: true` is a diagnostic, not automatic retry permission.

Local fixtures alone do not establish live eligibility or access. An actual authorized native SIWC run now passed human consent, authenticated HTTP200 catalog lookup and Jido→ReqLLM→`gpt-6-luna` real Read of an unpredictable on-disk challenge absent from the prompt. This catalog response uses a `models` list, not the ordinary API `data` assumption. The model was selected from actual returned/installed IDs. Aggregate usage was2006 input/46 output tokens, pricing unknown; no metered API fallback. Coding/cleanup outcomes and the exact current gate remain in [PROGRESS.md](PROGRESS.md); this single account/model observation is not universal eligibility or future route availability.

The same authorized native subscription also completed a disposable repository repair: observed test failure exit2, real Read/Edit/Shell, exact intended source change with unchanged tests/configuration, and independent final tests exit0. Aggregate22318 input/431 output tokens, reasoning42 reported, pricing unknown. Final isolated logout reported local logged_out/remote revoked and the host exited0. [Sanitized observed evidence](evidence/openai-subscription-20261018.json) retains outcomes without tokens, callback codes, authorization URLs or account identity.

## Explicit metered API accounts

A host credential resolver implementing `resolve(%OhMyJido.Context{}, opaque_account, options)` can return explicit ReqLLM inference options for an API account. The implementation requires a nonempty `api_key` and no OAuth access token for API mode; OAuth mode requires a nonempty access token and no API key. Refresh/identity records remain outside either inference option set.

For an API resolver, retrieve the selected account's key from the host secret service, then return it as the privileged per-request `api_key` option. Do not call `ReqLLM.put_key/2`, enable ambient `.env` discovery for session selection, or inspect the credential-bearing options. Host-returned generation preferences must be approved for the selected provider. If billing consent is absent, return an error; do not search environment variables or another application's auth cache for a fallback.

The authorized OpenRouter `openai/gpt-6-luna` low-reasoning requests are **metered API evidence**, not SIWC/Claude subscription evidence. The current actual native coding-repair scenario passed its failing-before/edit/passing-after and independent final test observations, with canonical aggregate usage 21,299 input / 427 output tokens and reported price USD 0.002873. See [the observed repair and limits](OPERATIONS_AND_EVIDENCE.md#other-exercised-observations-and-limits). A paid API response or repair cannot close a required subscription acceptance row or establish future pricing. No API key appears in these examples.

## Official Claude Code: a separate agent boundary

Anthropic's [legal/compliance policy](https://code.claude.com/docs/en/legal-and-compliance) is a gate: this library does not broker third-party Claude.ai OAuth tokens or impersonate Claude Code. Native Jido use of a permitted Anthropic API account remains separate and metered. The approved subscription integration is `OhMyJido.Tools.ClaudeCode`, delegating a finite task to the user's **unmodified official binary**.

Host adapter options must contain:

- Absolute `executable`, host-reviewed executable `sha256`, and `official_binary: true`.
- An explicit subset of official `tools`: `Read`, `Glob`, `Grep` require `:read`; `Edit`, `Write` require `:edit`; `Bash` requires `:exec`. Unknown tools fail closed. Default is no tools.
- Optional trusted `model`; `max_turns` defaults to 8 (valid 1–100), `timeout` to 120,000 ms and `max_output_bytes` to 262,144. Runtime/process ceilings can shorten those bounds.

Bind `{OhMyJido.Tools.ClaudeCode, trusted_options}` under `adapters.claude_code`, register/select the Action and grant `:claude_code` plus any intended tool grants. The model request is only `%{prompt: binary}`. Binary hash approval checks bytes since host approval, **not vendor provenance**; the host verifies the installation/distribution and administrator policy.

The installed official CLI must support the flags documented by the adapter (`--restricted` and `--permission-prompts`, v2.1.259+). Before delegation the adapter runs the official `auth status`; only `claude.ai` subscription authentication is accepted. API key/helper/cloud/imported-token methods are rejected. It initiates no login and does not read/import the CLI's credential files or tokens. The official binary necessarily manages its own authenticated OS-user state; `Context.account` and this library's OAuth vault are not its login selector. Multi-user hosts must isolate that OS identity.

Each child clears the documented metered/provider override environment variables without mutating the host environment. Invocation uses restricted/safe mode, print JSON output, no session persistence, **manual** permission mode, permission prompts set to `none`, strict empty MCP configuration, no MCP tools, no slash commands and no Chrome. The previously used `default` permission mode was rejected by the actual official 2.1.282 CLI; the implementation now uses its supported `manual` value. That client's documented model aliases include `fable`, `sonnet` and `opus`; the host selects an actually supported model, not an assumed CLI `haiku` alias. Missing permission-prompt responders cause denial, never approval bypass. Status/delegation subprocesses are sensitive host-approved effects.

The exact host-approved tool subset is passed as both native available tools and the native permission allowlist. This authorizes only those already granted/reviewed tools in manual mode; it does not enable all-tools permission bypass or override administrator deny policy. A completed delegate answer is not proof a requested edit happened: the integration owner independently checks actual source and tests.

This is not Claude's tool calls routed through Jido, not a native Jido subscription loop and not full third-party Claude subscription parity. Its own turn accounting, permission behavior and output are reported as a separate agent. A deliberate timeout/cancellation cannot undo its earlier files or network effects. The authorized actual2.1.282 Read proof was followed by a separately approved **Read+Edit-only coding repair**: unpredictable challenge read, genuine source repair, independent native tests failing before/passing after, unchanged tests/config and preserved existing claude.ai login. No Bash/MCP/network tools or API fallback were enabled. The [safe coding report](evidence/claude-coding-20261019.json) records the actual scoped proof; protocol fixtures cannot substitute for it.

## Diagnostic and credential ownership

The source-pinned native patches are required because ordinary status/crash/HTTP-failure logging can expose request secrets before a facade redacts them. [Permissions and recovery](PERMISSIONS_AND_RECOVERY.md#native-diagnostic-snapshots) documents their scope, Apache-2.0/MIT notices and **original-source** hashes. They are not global logger suppression or proof that arbitrary custom/native services never log private data.

Credential-bearing production turns force ReqLLM telemetry `payloads: :none`, overriding request/host/global payload preferences, and use model-bound safe error normalization. Keep all UI/log exporters metadata-only and protect the host-only inspection and session store. Signed native continuation tokens are not credentials to publish or durable evidence to retain. Current verification and any privacy regression are reported separately in [operations and evidence](OPERATIONS_AND_EVIDENCE.md); no private-token, live-provider or full-release gate is declared complete here.
