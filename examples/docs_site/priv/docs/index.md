# Oh-My-Jido

Oh-My-Jido is an Elixir library that puts a coding agent inside your own Elixir or Phoenix application. Use it to explain a repository, make guarded edits, run commands and tests, or build a review-and-approval workflow like this site's studio.

Jido manages agents and their OTP lifecycle. Jido.AI runs the loop that lets a model choose tools and use their results. ReqLLM connects that loop to model providers. Your application chooses the workspace, tools, permissions, model, paying account and actions that need approval.

## What can you build?

| Need | What Oh-My-Jido provides |
|---|---|
| Repository assistance | File reads, search, directory listings, snapshot-guarded writes and edits. |
| Coding workflows | Commands, tests, Git, structural Elixir refactors, language-server and debugger integration. |
| Application-specific agents | Your own Jido Actions, explicit service adapters, subagents and optional Elixir/JavaScript/Python evaluation. |
| Work that survives a restart | Durable session identities, checkpoints and a tool-effect journal. Interrupted effects are not blindly rerun. |
| Human control | Ordered events, questions, approval requests, steering, cancellation and suspension. |

Supervising the library starts no session or model request. There is no separate CLI, daemon or sidecar, and no Node/Bun process is required to embed it.

## Start with one file read

After installing the library, add this runtime to your application's supervision tree:

```elixir
children = [{OhMyJido, name: MyApp.Coding}]
```

Once your supervisor has started it, open a session in an existing project directory:

```elixir
{:ok, session} =
  OhMyJido.start_session(MyApp.Coding,
    workspace: "/path/to/project",
    bundles: :read_only,
    permissions: [:read]
  )

{:ok, file} = OhMyJido.execute_tool(session, "read", %{path: "mix.exs"})
```

This makes no model call and needs no provider key. `bundles:` is a session option: it selects available tools, not permission to use them. A session starts with no permissions unless you supply them.

## Read next

| Page | What you will learn |
|---|---|
| [Getting started](/docs/getting-started) | Install the right branch, make your first tool call and submit an AI task. |
| [Runtime and sessions](/docs/runtime) | Supervise sessions, consume events and restore saved context. |
| [Tools and safety](/docs/tools) | Select tools, edit safely and decide which effects need approval. |
| [The docs studio](/docs/studio) | See a Phoenix app take source from an agent edit through review and publication. |

Version 0.1.0 is a pre-release and is not published on Hex. This documentation follows `jido-v3-preview`, the native Jido 3 preview branch. For the full guides, use the [repository documentation](https://github.com/mattneel/oh_my_jido/blob/jido-v3-preview/docs/README.md).
