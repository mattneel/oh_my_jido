# The docs studio

This is a working example of Oh-My-Jido embedded in Phoenix. The content is Markdown in `priv/docs`; the presentation is ordinary Phoenix source. There is no second database of page bodies.

## The complete loop

1. An authenticated operator starts a bounded, rooted agent run.
2. Native tools inspect and edit an isolated source workspace.
3. The operator can ask questions, steer, approve execution, or cancel work.
4. A candidate captures exact immutable source and a reviewable diff.
5. Real child processes run checks and build a separate Phoenix preview.
6. The operator approves the exact candidate digest, then publishes documentation or adopts code.
7. An explicitly configured deployment sends that reviewed source to Fly. Publication never evaluates generated code in the editor's running VM.

## Small public server, trusted editor

The public Fly deployment serves the built documentation only. It needs no model keys, deployment token, source compiler, SQLite studio database or agent runtime. The separate trusted editor owns source workspaces, native session storage, run history and approvals.

A browser reload reconnects to host-owned work. A host restart restores durable identities without automatically replaying uncertain effects. Concurrent human source edits invalidate stale approvals.

This is not an OS sandbox. Do not expose the editor or its source-execution authority as an anonymous public service.
