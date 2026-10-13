# Elixos as the principal host

## Integration goal

Elixos embeds Oh-My-Jido as its OS-native coding-agent engine.
The library remains independent from Elixos and can run in ordinary Elixir applications.
The host provides existing OS services through narrow library contracts.

The reference repository is https://github.com/mattneel/elixos.
Inspect its current revision before implementing integration code.
Do not assume that any historical code or integration test remains unchanged.

## Existing Elixos services

| Elixos service | Proposed adapter responsibility |
|---|---|
| `Elixos.Agents` | Host agent lifecycle, snapshots, and restore policy |
| `Elixos.Session` | Caller-specific working directory without global `cwd` changes |
| `Elixos.Ask` | Human questions, confirmation, and GUI/SSH/REPL replies |
| `Elixos.Browser` | Existing headless browser and browser process lifecycle |
| `Elixos.Image` | Durable generation state and restore boundaries |
| `Elixos.Candidate` | Candidate builds, validation, provenance, and deployment |
| `Elixos.Privileges` | Explicit OS capability grants when needed |

Do not replace these services with internal copies.
Elixos retains final ownership of operating-system policy and deployment.
Oh-My-Jido supplies task execution and evidence through its public API.

## Safety boundaries

Elixos shares one main BEAM among the userland applications.
Never change its global working directory or environment for an agent session.
Never load agent-authored working-tree modules directly into that BEAM.

Keep agent-generated changes in a separate workspace or candidate tree.
Build and test candidate code through the established child ERTS or peer process mechanisms.
Use the existing NEXT, boot, health, COMMIT, and fallback flow for OS changes.
Do not bypass the image generation machinery to accelerate deployment.

The host must enforce the authority boundary for system configuration, credentials, device access, and external side effects.
Agent autonomy does not grant implicit permission to mutate privileged OS state.

## Host demonstration

1. Start an Oh-My-Jido runtime beneath an Elixos supervisor.
2. Bind a coding session to one Elixos workspace and one permission policy.
3. Send a small requirement from IEx or an existing Elixos interface.
4. Let the Jido agent inspect, edit, and test code through its library tools.
5. Route any human question through the existing `Elixos.Ask` service.
6. Build and evaluate the candidate through `Elixos.Candidate`.
7. Verify a normal generation promotion after all health checks succeed.
8. Verify fallback from a deliberately defective candidate.
9. Inspect provenance and recoverable evidence through Elixos APIs.

This demonstration belongs to the integration acceptance gate.
Do not require every library consumer to implement Elixos image generations.

## Repository ownership

Keep the Oh-My-Jido implementation in the `oh_my_jido` repository.
Create an Elixos adapter or integration test fixture only after the core package API stabilizes.
Request human approval before changing the actual Elixos repository.
Do not copy the archived QuickBEAM tool host or prior compatibility runtime into Oh-My-Jido.
