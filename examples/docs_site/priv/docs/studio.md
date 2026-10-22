# Use the docs studio

The studio is a Phoenix example of Oh-My-Jido embedded in an application. It lets a trusted operator ask an agent to edit documentation or application source, review the exact diff, build a preview and choose what to publish.

The pages you are reading are Markdown under `examples/docs_site/priv/docs`. The presentation is Phoenix source. SQLite records runs, events and candidate history; it is not a second database of page bodies.

## Two roles, one application

| Role | Responsibilities |
|---|---|
| Trusted editor | Owns source workspaces, model credentials, session storage, review history, questions, approvals, builds and deployment controls. |
| Public renderer | Serves Markdown from a built release. It starts no agent runtime or studio database and needs no model key, Fly token, source compiler or editor toolchain. |

Production defaults to the public renderer. You run the editor separately with an explicit operator password hash and trusted source/toolchain configuration. There is no default password or public registration. See [Run the docs studio](https://github.com/mattneel/oh_my_jido/blob/master/examples/docs_site/README.md) for setup, environment variables and deployment instructions.

## Take a change through review

1. Sign in to your private editor and start a run. Choose **docs** for Markdown-only changes, or **coding** when you deliberately want application edits and Shell access.
2. Follow the saved events. Answer clarification and approval requests, steer the agent, or cancel/suspend work. Every agent-launched subprocess needs a fresh approval.
3. Prepare a candidate: an immutable copy of exact source bytes with a reviewable diff and digest.
4. Start checks. Real child processes compile, test and build a production release using copied dependencies and private build directories. Missing tools or artifacts are a failed/unavailable capability, not a passing check.
5. Open the separately built preview through the protected proxy. It uses a sandboxed frame and does not receive editor cookies.
6. Approve the exact successful candidate digest, then publish documentation or adopt code. Changed source invalidates stale authority.
7. Deploy to Fly only after configuring the target and explicitly requesting that external effect.

| Action | What changes |
|---|---|
| Publish docs | Adopts the reviewed Markdown as the source for future runs, then switches the editor's local publication pointer. |
| Adopt code | Creates a managed Git source version for future runs. It does not overwrite the seed checkout or load authored modules into the editor VM. |
| Deploy | Builds/deploys the reviewed repository source to the explicitly configured Fly app. Local publication alone does not update that app. |

Code reloading and asset watchers are disabled in the editor. New application code runs only in a separate built preview or a deployment. A partial publication/adoption failure retains its receipt and does not silently roll back or replay an effect.

## Reconnect and recover

Closing or reloading the browser does not cancel a run. The editor saves events independently and reconnects to application-owned work. A restart restores durable identities and context without repeating an interrupted model turn, command, publication or deployment.

If execution or cleanup is uncertain, publication stays blocked until the real resources and outcome are reconciled. The editor's trusted recovery console distinguishes an operator acknowledgement from an actual native stop receipt. Use the [recovery and backup instructions](https://github.com/mattneel/oh_my_jido/blob/master/examples/docs_site/README.md); do not delete a lease or retry an effect to guess what happened.

## Limits

- The editor is for trusted operators, **not an OS sandbox** or an anonymous public editing service. Authored code can use the editor OS user's files and network.
- One editor BEAM owns a source checkout/data directory. There is no multi-editor replication or cross-VM publication lock.
- Checks, previews and deployments share one candidate-effect slot. Stop an existing preview before another check or deployment.
- Published Markdown is sanitized, never evaluated as HEEx. Draft source and private run history are not public documentation.

## Related

- [What Oh-My-Jido does](/docs/index)
- [Getting started with the library](/docs/getting-started)
- [Runtime and sessions](/docs/runtime)
- [Tools and safety](/docs/tools)
