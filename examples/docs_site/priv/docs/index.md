# Oh-My-Jido

A host-controlled coding agent for ordinary Elixir and Jido applications.

Jido owns agent lifecycle, Jido.AI owns model turns, and ReqLLM owns provider transport. Your application owns workspaces, credentials, permissions and approval. No model request starts merely because the library is supervised.

## Choose your integration

- [Managed runtime](/docs/runtime): supervised sessions, durable effects, questions and recovery.
- [Native tools](/docs/tools): scoped reads, guarded edits, language intelligence and explicit processes.
- [The docs studio](/docs/studio): this site is its own real source-first example.

```elixir
children = [{OhMyJido, name: MyApp.Coding}]

{:ok, session} = OhMyJido.start_session(MyApp.Coding,
  workspace: "/srv/projects/demo",
  bundles: :read_only,
  permissions: [:read])

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

Tool availability never grants permission. Credentials and execution remain explicit host decisions.
