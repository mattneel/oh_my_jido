# Model roles and authentication

## Model provider foundation

Use Jido.AI and ReqLLM for model calls, streaming, tool requests, and provider-specific transport.
Keep Oh-My-Jido-specific logic limited to model roles, account selection, credential brokerage, and harness policies.
Do not create a parallel generic HTTP/SSE model transport.

Read the installed Jido.AI and ReqLLM documentation before selecting provider names or model identifiers.
Use dynamic provider/model discovery when the installed packages expose it.

## Native configuration

Use `import Config` for defaults and role configuration.
Let host applications override configuration through normal Mix application configuration.
The following is a proposed role layer. Verify the installed Jido.AI syntax before code generation.

```elixir
import Config

config :jido_ai,
  model_aliases: %{
    fast: "provider:fast-model",
    capable: "provider:capable-model",
    review: "provider:review-model"
  }

config :oh_my_jido,
  default_role: :coding,
  model_roles: %{
    coding: :capable,
    planning: :capable,
    exploration: :fast,
    review: :review,
    advisor: :review,
    compaction: :fast
  }
```

Do not store raw credentials in Elixir source configuration or version control.
Resolve credentials at runtime through the host's credential service.

## Selection precedence

1. Explicit session selection.
2. Approved per-workspace or per-project selection.
3. User configuration.
4. Application defaults.

Project configuration can execute code if read as an Elixir script.
Do not evaluate untrusted project configuration without human trust approval.
Prefer host-provided declarative project overrides when the repository is untrusted.

## Account model

Use an opaque account reference in session state.
Support multiple identities per provider and independent expiration state.
Keep the refresh token in an encrypted or OS-protected credential store.
Use a single refresh operation per account when concurrent sessions need renewal.
Support account selection, logout, revocation, expiration, and explicit provider errors.
Prevent account tokens from appearing in logs, errors, telemetry, or serialized conversations.

## ChatGPT/Codex subscription

Implement the documented, authorized login route for eligible ChatGPT/Codex subscriptions.
Use PKCE or other required OAuth protections from the provider specification.
Validate state, redirect bindings, and approved scopes.
Use ReqLLM's supported provider route rather than a cloned Codex CLI backend.
Enforce documented plan-usage restrictions and return clear quota or eligibility errors.
Require an explicit user decision before any transition to separately billed API usage.

Build local mock OAuth tests. Keep live login tests opt-in and human initiated.
Do not assume the host already grants access to another application's credential files.

## Claude/Claude Code subscription

Treat authorized Claude subscription access as a required product objective with a provider-policy gate.
Do not impersonate an official client or extract another application's tokens without authorization.
Implement approved account login when Anthropic permits third-party use.
If official Claude Code delegation is the approved route, expose it as a separate integration with clear capability limits.
Do not misrepresent a delegated Claude Code agent as a native Jido agent loop.

Keep the core agent available through permitted Anthropic API credentials.
Do not report subscription parity when only metered API access works.
If authorization remains unavailable, preserve the blocker and request a human decision.

## Acceptance

Exercise model roles, account isolation, token refresh races, logout, redaction, and usage limits.
Verify correct tool responses and streaming with scripted providers.
Run one opt-in real coding session through each authorized subscription path.
Record the provider, access method, exact error shape, and billing behavior without raw tokens.
