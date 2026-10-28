# Embeddable architecture

## Product boundary

Oh-My-Jido is a reusable Mix library. It does not own a terminal, an operating system, or a deployment environment.
The host owns supervision placement, capabilities, storage, permissions, and presentation.
Oh-My-Jido owns the coding-specific harness and its model-facing behavior.
Jido and OTP provide generic agent execution and lifecycle primitives.

```text
Phoenix / any Elixir host
  Host-provided permission, workspace, persistence, approvals and UI adapters
  |
  +-- OhMyJido.Runtime (ordinary supervised child)
        |
        +-- Jido agent servers and bounded subagent supervisors
        +-- OhMyJido coding profiles, prompt composer, model role selection
        +-- Jido Actions for code-aware tools
        +-- Session and context policy over pluggable storage
        +-- Typed event stream and control interface
        +-- Optional Eval runtime boundary
              +-- Elixir: separate ERTS with restricted host bridge
              +-- JavaScript: QuickBEAM in a crash-isolated peer process
              +-- Python: Snakepit workers and optional SnakeBridge
```

Do not add custom scheduler or process registry code where Jido or standard OTP already satisfies the contract.
A host can start multiple independent library instances with distinct configuration and credentials.
Each agent must maintain an explicit workspace root and capability set.

## Public API target

The following calls express design intent. They are not claims about existing APIs.
Finalize the signatures against current Jido APIs before implementation.

```elixir
# Application supervision example.
children = [
  {OhMyJido.Runtime, name: MyApp.Coding, host: MyApp.Coding.Host}
]

# Target API shape, subject to actual Jido conventions.
{:ok, session} = OhMyJido.start_session(MyApp.Coding,
  workspace: "/srv/projects/demo",
  role: :coding,
  permissions: [:read, :edit, :exec]
)

:ok = OhMyJido.subscribe(session, self())
{:ok, run_ref} = OhMyJido.prompt(session, "Fix the failing test")
:ok = OhMyJido.steer(session, run_ref, "Preserve the public API")
:ok = OhMyJido.cancel(session, run_ref)
```

Prefer existing Jido lifecycle and signal methods where they meet this shape.
Keep adapters stable while internal Jido calls evolve.

## Host contracts

Expose behaviors or equivalent typed callback contracts for these capabilities:

| Host capability | Responsibility |
|---|---|
| Workspace | Resolve paths, grant roots, support snapshots and diffs |
| Effects | Authorize file, process, network, Git, and external effects |
| Approval | Collect human consent and policy decisions |
| Credentials | Return opaque account references and authorized tokens |
| Storage | Persist sessions, checkpoints, and bounded context records |
| Browser | Provide navigation and page interaction when enabled |
| Language intelligence | Provide or launch LSP, DAP, and structural code tools |
| Presentation | Consume events and display progress, output, and questions |
| Deployment | Evaluate and promote candidate code outside the library |

Ship reference adapters for normal Elixir projects.
The reference workspace adapter must enforce an explicit root even without an OS sandbox.

## Agent state and events

Keep durable session identities distinct from local process IDs.
Persist model-visible conversation state and checkpoints through the configured store.
Use Jido signals and telemetry for tool events, model turns, progress, and failures.
Publish a stable host-facing event shape with session ID, run ID, sequence, kind, and payload.
Keep secrets, complete token values, and unnecessary private workspace bytes out of event data.

Support tool-call status, partial output, completion, errors, approval requests, and subagent lifecycle.
Bound event buffers or apply backpressure when consumers are slow.
Support resume after a host process restart without replay of uncertain effects.

## Model and prompt layers

Use Jido.AI and ReqLLM for provider calls, tool execution strategies, and model aliases.
Add task-specific model roles through a small Oh-My-Jido configuration layer.
Define profiles for coding, planning, exploration, review, compaction, and advisor roles.
Compose prompts from goals, coding rules, project instructions, enabled tools, and active model capabilities.
Do not copy Oh My Pi's prompt renderer merely to preserve its internal template syntax.

## Tools and effects

Implement model-facing tools as Jido Actions with validated inputs and structured results.
Keep read, edit, search, Git, process, debugger, browser, and Eval permissions explicit.
Avoid accidental duplicate effects across retries, cancellation, and subagent work.
Preserve the distinction between a failed call and a call with uncertain side effects.

Advanced editing must use content snapshots or equivalent stale-write protection.
Test atomic replacement and conflicting concurrent changes.
Allow native acceleration after verification of correctness and measured need.

## Runtime budget

Use the BEAM for lightweight processes, deadlines, supervision, and queues.
Place strict admission limits on LLM calls, shells, browser contexts, native work, and Eval workers.
Monitor idle memory, active memory, run latency, queue time, and crash isolation.
Do not claim higher density before a controlled benchmark demonstrates it.
