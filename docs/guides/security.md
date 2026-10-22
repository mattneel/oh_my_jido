# Protect your application and session data

Use this guide before giving a coding agent access to private repositories, credentials or executable code. Oh-My-Jido enforces library-level permissions and workspace checks; your application supplies the OS isolation and protects the data around it.

## Choose the execution boundary first

**Oh-My-Jido is not an OS sandbox.** Its workspace is the root for library file operations, not a restriction on everything a shell, compiler or language runtime can do.

| Oh-My-Jido provides | Your application still owns |
|---|---|
| Explicit session permissions and authorization before built-in tool effects. | Choosing trusted Actions and adapters, OS identities, credentials, permitted networks and deployment policy. |
| Canonical workspace paths and snapshot-guarded file changes. | A filesystem boundary against hostile processes racing path checks, and confinement of arbitrary executable code. |
| Limits on admitted work and retained input/output. | OS memory, CPU, process-tree and device limits. A byte quota is not a resource sandbox. |
| Durable effect ownership and records of uncertain outcomes. | Reconciling external effects. Stopping a process does not undo its earlier writes or network calls. |
| Supported private diagnostics and known-secret redaction. | Protecting storage and privileged process inspection, and reviewing custom programs or compiled extensions that may log private data. |

A normal BEAM process is not an isolation boundary for arbitrary Elixir. Elixir Eval runs in a separate ERTS, meaning a separate Erlang VM: this separates crashes, not filesystem or network authority. JavaScript Eval uses QuickBEAM in a separate worker VM; Python Eval uses Snakepit-managed workers. See [Eval](eval.md) for backend setup and limits. Compiled code called on a dirty scheduler can still corrupt or crash its VM.

Before you allow execution over untrusted input, apply real OS controls:

1. Use an unprivileged OS identity with no access to your application's secrets. Separate users' identities when an external service, such as official Claude Code, uses the current OS user's login.
2. Expose only the required mount roots, preferably through an appropriate container or other filesystem isolation. A working directory is not confinement.
3. Restrict network egress, destinations and redirects outside the model's control.
4. Keep credential vaults, token files, session stores and signing/deployment keys outside the worker's accessible filesystem and environment.
5. Apply process-tree or cgroup limits and appropriate memory, CPU and device restrictions. Account for deliberately detached children, not only ordinary subprocesses.

Shell commands, candidate builds and tests, language/debug servers, compiled image decoders and Python imports can all execute code under their OS identity. Give read-only exploration fewer permissions than mutating work, and pass only the permissions a subagent or Eval tool actually needs. A prompt saying “stay in the workspace” enforces none of these controls.

## Protect four separate data stores

Protect these independently, including their backups and any service that exports them:

| Store or surface | What it contains | How to treat it |
|---|---|---|
| Session storage | Private conversation, file/effect records and retained task facts. | Restrict access and encrypt/protect it as needed. `Jido.Storage.File` is not an encrypted credential vault. Redacted does not mean public. |
| Credential vault | Account-broker records, including refresh credentials. | Keep it separate from repositories, session storage, build artifacts and deployment/image generations. Restrict access to the broker and protect the stable application-owned encryption key and backups. |
| Native process state | Private callback options, handles, account context and in-flight request credentials. | Treat inspection and debugging access as trusted administration, not a public UI API. Do not export raw native state or whole session inspections. |
| UI, telemetry and logs | Events, error reports and operational metadata. | Export only the redacted fields needed by the recipient. Do not log callback URLs, credential options, request bodies or whole inspections. |

Store only opaque account references in session configuration, not API keys or OAuth records. Credential selection and account lifecycle remain trusted application decisions; neither a prompt nor `:exec` grants permission to import an account, refresh tokens or switch billing modes. See [models and accounts](models-and-accounts.md) for credential ownership and [operations](../operations.md) for protecting durable storage.

Signed native continuation tokens also need protection. They can encode recoverable private state without looking like a recognizable credential string. Do not publish them or preserve them as durable evidence.

## Use redaction without depending on secret discovery

`OhMyJido.Redact` removes recognized credential fields and replaces known secret values. For example, an application-owned projection can supply a known value explicitly:

```elixir
safe =
  OhMyJido.Redact.sanitize(
    %{authorization: "example-only-secret", detail: "failed for example-only-secret"},
    ["example-only-secret"]
  )

# Both the authorization field and the matching text in detail are redacted.
```

The recognized keys are case-insensitive atom or string names: `api_key`, `access_token`, `refresh_token`, `id_token`, `authorization`, `password`, `client_secret`, `token_secret`, `cookie` and `set-cookie`. Known-value replacement matches the supplied bytes; it does not discover unrelated secrets or arbitrary encodings.

| Boundary | Protection and limit |
|---|---|
| Events and bounded summaries | Recursive known-key/value sanitation. `Redact.sanitize/3` defaults to an 8,192-byte limit per binary and retains at most 100 list elements. This is not an aggregate payload or VM-memory limit. |
| Durable checkpoints | Structured cleanup clears inference option sets and process callbacks/handles, redacts known credentials, and removes signed continuation tokens from their typed checkpoint fields/events. Do not replace this with a verbatim native-state dump. |
| Production model requests | ReqLLM telemetry uses `payloads: :none`, overriding request, credential-resolver and global payload preferences. Failure normalization is bound to the actual selected model. |
| Native model debugging | ReqLLM debug must be disabled before credentials are obtained. Unsafe debug configuration is rejected with `:unsafe_model_debug_configuration`. |
| Custom fields and external diagnostics | Unknown strings, encoded values, custom fields, shell output and application-authored logs need their own policy. The library cannot prove that every third-party or custom service keeps private data out of logs. |

Keep useful failures visible. Global logger suppression hides problems and does not establish a privacy boundary. Review any exporter or adapter that can receive full private values before the library can redact them.

## Keep the bundled patched dependencies

Ordinary status reports, callback failures and HTTP/stream errors can expose secrets before a facade gets a chance to redact the result. The supported snapshots patch those original diagnostic paths. They keep Jido's agent runtime, ReqLLM's provider transport and Snakepit's process management; they are not replacement runtimes or a claim of a published upstream release.

Use the source overrides in [getting started](../getting-started.md). Stock packages without these boundaries are not interchangeable with the documented credential/privacy contract.

| Snapshot | Why its patch is required |
|---|---|
| Jido | Opted-in AgentServer status, callback failures and directive telemetry use metadata-only diagnostics, including Jido.AI ReAct workers. Private callback failures are caught before OTP can append original arguments or queued messages to a report. Safe shutdown reasons do not pretend a failed effect succeeded; ordinary non-private agents retain their behavior. |
| ReqLLM | Failure normalization runs before ReqLLM HTTP/stream diagnostics, including streaming transports and hooks, can expose request values. Safe errors retain the selected model's identity. |
| Snakepit, when Python Eval is enabled | Trusted worker configuration opts into private diagnostics. Supported SDK requests/completions and callback states use opaque message envelopes, keeping worker configuration, source and private request values out of status, callback-failure reports and OTP sys-debug history. |

The exact dependency-version checks and their failures are in [operations troubleshooting](../operations.md#troubleshoot-dependency-mismatches).

These protections are scoped, not global log filters. Arbitrary raw BEAM messages, function-environment extraction and introspection of your application's VM remain trusted administrative access. Do not supply provider credentials to Eval workers.

### Licenses and original-source digests

The manifests identify the unmodified upstream source. The hashes below are **not** hashes of the current patched files or loaded BEAM modules.

| Snapshot and source manifest | License to retain | Original-source manifest digest |
|---|---|---|
| Jido 2.4.0 — [`vendor/jido/UPSTREAM.json`](../../vendor/jido/UPSTREAM.json) | [Apache-2.0](../../vendor/jido/LICENSE) | `snapshot_sha256`: `d850dbd74d849d3deb1c7a9f8d6a130dbb7d1bc99a05ee0aabc8f81c3ff1e75c` |
| ReqLLM 1.28.0 — [`vendor/req_llm/UPSTREAM.json`](../../vendor/req_llm/UPSTREAM.json) | [Apache-2.0](../../vendor/req_llm/LICENSE) | `unmodifiedSnapshotDigest`: `be792b0751392cff0b9bf1098fb42cb4daddb84ac94a9ad06a4f4d43a10d4850` |
| Snakepit 0.14.0 — [`vendor/snakepit/UPSTREAM.json`](../../vendor/snakepit/UPSTREAM.json) | [MIT](../../vendor/snakepit/LICENSE) | `snapshot_sha256`: `aaa434dfb28d83f97b84606d9f0632a4a963fc42a11cdbe20f88227be82c0bf0` |

Retain each license, copyright notice, modified-source notice and the manifest's descriptions of local changes when you redistribute these snapshots. The manifests preserve original per-file hashes and byte lengths; Snakepit separately records a complete patched-source digest. Do not present original-source digests as measurements of your built application.

## Understand file, process and Git hardening

These controls reduce accidental or model-directed mistakes inside the library's supported operations. They do not replace the OS controls above.

| Boundary | What the implementation does | What it does not guarantee |
|---|---|---|
| Workspace paths | Canonicalizes the existing workspace and paths; rejects parent traversal and symlink escape; rechecks the root and path at filesystem effects. Configured Jido file roots remain an additional restriction. | A hostile OS process can race multiple filesystem system calls. A lexical prefix check alone would not be sufficient, and these rechecks are not an OS filesystem sandbox. |
| Guarded file writes/edits | Checks whole-file byte snapshots, preserves unrelated text/newline bytes during edits, rejects stale/overlapping/ambiguous targets, and serializes in-process writers by canonical path. Content and confinement are checked again before publishing. | External writers are rechecked, not locked. Shell writes do not automatically use the file adapter's snapshot guards. |
| Process launch | Uses an explicit executable and argument vector, workspace-relative working directory and child-only environment overrides. It never changes the working directory or environment of your application's VM per session. Output and deadlines are bounded. | The child's OS authority is not limited by its working directory. Child overrides are not a promise that the entire inherited environment is secret-free. |
| Process cleanup | Uses Linux `setsid`, procfs identity and owned-group checks to avoid signaling a reused PID. `cleanup: :confirmed` means no live member of the owned process group remains. | Deliberate daemonization or process-group escape needs a sandbox/cgroup. A kill cannot undo an earlier write, payment, migration or network call. |
| Git child hardening | Uses fixed argument lists; disables hooks, external diffs, text conversion, commit signing and fsmonitor. Strips ambient Git directory/index/config overrides and selected transport/helper overrides in the child only. | Malicious repository configuration is not proven harmless. A command allowed through Shell can bypass this specialized Git policy. |
| Git operation scope | Inspection uses `:git` rather than arbitrary `:exec`; mutation also needs `:edit`. Commits select explicit paths and approve staging and committing separately. No remote, publishing, force-removal or history-rewriting API is supplied. | Interrupted operations are not automatically rolled back or retried. A missing success response is not proof that no external effect occurred. |
| External adapters | Supported contracts track session ownership, deadlines, scoped resources and observable cleanup. Your adapters must constrain allowed origins and redirects. | An unsafe underlying API does not gain page isolation, OS confinement or rollback because an adapter returns a reassuring result. |

The process implementation requires Linux with `setsid`, `sh`, `mkfifo`, `cat`, `kill` and `/proc`; other operating systems fail closed. Uncertain effects are never automatically replayed. See [sessions and recovery](sessions-and-recovery.md) before deciding what to do after a crash or interrupted command.

## Limits

- Your trusted application, Action implementations and adapters are privileged code. The model, repository instructions, skills, web pages, tool output and MCP announcements cannot change permissions, credentials, billing or deployment policy.
- Crash separation is not secret isolation or OS confinement. It does not make arbitrary NIFs, imported modules or child programs safe.
- Redaction does not turn private conversations, source code or session records into public data. Protect all four stores even when known credentials have been removed.
- Approval and cleanup are not rollback. If your application deploys agent-authored code, it owns validation, promotion, operator approval and rollback; reverting code does not reverse external effects.
- Compatibility and verification status are recorded separately in [project status](../project-status.md). This guide describes the supported security contract, not a guarantee about arbitrary custom services.

## Related

- [Permissions and approvals](permissions-and-approvals.md)
- [Sessions and recovery](sessions-and-recovery.md)
- [Models and accounts](models-and-accounts.md)
- [Eval](eval.md)
- [Operations](../operations.md)
- [Canonical security specification](../oh-my-jido/SECURITY.md)
