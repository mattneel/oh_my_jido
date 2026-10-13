# Eval design: Elixir, JavaScript, and Python

## Purpose

Eval is a model-facing Jido Action. It executes scoped user or agent code in an isolated language session.
Eval offers interactive state, computation, output, and authorized host-tool access.
It does not implement the agent loop or the core coding tools.

## Backend contract

The host chooses enabled backends through `import Config` and capability policies.
One Eval session belongs to one coding session and one language backend.
An Eval request carries language, source, timeout, output budget, and optional cell identity.
An Eval result carries status, display value, stdout, stderr, diagnostics, artifacts, and resource usage where available.

Expose stable operations such as `open`, `execute`, `interrupt`, `reset`, and `close` through one backend behavior.
Select exact Elixir function names after inspection of the installed Jido tool API.

## Elixir: a first-class backend

Use an isolated, supervised ERTS for arbitrary Eval code.
A BEAM process inside the host VM is not a security boundary for untrusted Elixir code.
A peer node separates runtime crashes but requires additional OS access controls for untrusted code.

Preserve bindings and reusable named values across successful cells in the same Eval session.
Capture normal values, IO, exceptions, compiler diagnostics, and output artifacts.
Provide a narrow RPC bridge for explicitly granted Jido tools and host capabilities.
Expose useful standard Elixir modules within the granted execution environment.
Prevent Eval code from changing global host code paths, environment, or working directory.

## JavaScript: QuickBEAM Eval only

Use QuickBEAM as an optional JavaScript execution engine behind the Eval behavior.
Keep QuickBEAM and any native engine in a crash-isolated ERTS or separate host process.
Preserve the Eval session's JavaScript context across cells.

QuickBEAM can inject APIs that bridge JavaScript calls into Elixir host operations.
Implement only the Bun- or Node-shaped interfaces that actual Eval tasks require.
Use Oh My Pi JavaScript Eval behavior as a reference for API semantics, not implementation reuse.
Do not create a general-purpose Bun runtime or reuse Oh My Pi's TypeScript tool bundle.

The injected API must use a permission-checked dispatcher rather than arbitrary host RPC.
Expose bounded filesystem, process, data, and tool functions as separately granted capabilities.
Audit each injected function for effect ownership, output size, and cancellation.

## Python: Snakepit with optional SnakeBridge

Use Snakepit for managed Python execution and session affinity.
Use SnakeBridge only when typed access to Python libraries improves an actual Eval requirement.
Keep Python workers outside the host BEAM and bound their resource use.
Expose authorized host tools through the existing worker bridge or a minimal adapter.
Do not create another custom CPython process manager, package resolver, or inference runtime.

## Runtime safety

- Isolate Eval workers from the main host VM.
- Limit concurrent kernels and worker memory where the platform provides enforcement.
- Apply deadlines to execution and host callbacks.
- Close workers after session termination or idle expiry.
- Redact credentials and host secrets from all outputs.
- Prevent unrestricted OS access through injected APIs.
- Refuse effects outside the session's granted workspace and permissions.
- Record uncertain effects after worker failure; never retry them blindly.
- Distinguish resource limits from operating-system security isolation.

## Tests

Test persistent variables or bindings across two cells for every language.
Test errors, long output, timeouts, worker crashes, and explicit session reset.
Test host callback authorization and denied calls.
Test concurrent sessions with separate variable scopes.
Test JavaScript injected API semantics against small behavior examples from Oh My Pi.
Test Elixir code in a separate ERTS and confirm host survival after deliberate worker termination.
