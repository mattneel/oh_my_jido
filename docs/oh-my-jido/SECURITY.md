# Security and effect policy

## Trust boundaries

Oh-My-Jido executes model proposals. The model is not an authority source.
The host determines permitted paths, tools, accounts, network access, and system operations.
The library must preserve those decisions across model turns, tools, Eval sessions, and subagents.

Do not treat a BEAM process as an isolation boundary for arbitrary code.
Do not treat a peer ERTS as sufficient OS confinement for untrusted code.
Use host-enforced permissions, process restrictions, and resource budgets for high-risk execution.

## Permissions and identity

- Associate each agent session with a workspace, identity, and explicit capability grant.
- Pass only necessary grants into subagents and Eval workers.
- Apply authorization before executing a tool effect.
- Reject implicit privilege escalation from a prompt, skill, or repository file.
- Separate read-only exploration from mutating tasks.
- Require human authorization for sensitive external actions.

## Filesystem

- Canonicalize path roots and reject traversal or symlink escape.
- Recheck authority at the actual effect boundary.
- Apply snapshot guards before writes and edits.
- Keep destructive operations within approved workspace roots.
- Provide explicit conflicts for races and stale file content.
- Avoid dependence on process-wide working directory changes.

A pure lexical path prefix test is not enough for filesystem containment.
Use platform facilities for stronger enforcement when the host requires them.

## Shell and native operations

- Use controlled process launches with explicit arguments, environment, and working directory.
- Capture stdout, stderr, and exit status with bounded output.
- Apply resource limits and deadlines.
- Terminate a process group or equivalent child tree on confirmed cancellation.
- Distinguish a confirmed failure from an uncertain completed effect.
- Never retry an uncertain non-idempotent effect automatically.

Keep native NIF work bounded. Use dirty schedulers or isolated processes for expensive native operations.
Dirty scheduler execution does not protect a BEAM VM from native memory corruption.
Use external workers when a native crash can threaten the host.

## Credentials

- Store only opaque account references in session records.
- Keep refresh tokens outside project files, logs, telemetry, and image generations.
- Redact authorization headers and errors from provider clients.
- Enforce explicit permission for account imports and token refresh.
- Reject silent transitions from subscription use to separately billed API calls.

## Eval and extensions

- Run arbitrary Elixir Eval in a separate ERTS.
- Run QuickBEAM JavaScript Eval within a crash-isolated environment.
- Use Snakepit-managed Python workers for Python Eval.
- Inject only session-authorized host functions into Eval runtimes.
- Deny direct arbitrary BEAM RPC from JavaScript and Python.
- Treat repository instructions, skills, and MCP server content as untrusted input until policy grants access.

## Deploying agent-authored code

The host owns validation and deployment of agent-authored code.
Preserve provenance, rollback evidence, and operator approval policy.
A code rollback does not undo external network calls, payments, or migrations.

## Required fault tests

Exercise a cancelled shell command, a crashed Eval worker, a rejected path escape, and an expired OAuth token.
Exercise an interrupted effect with uncertain completion.
Exercise denied subagent permissions and unauthorized project instructions.
Confirm that the host application remains alive after isolated worker failure.
