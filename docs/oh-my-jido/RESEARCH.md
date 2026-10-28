# Research and dependency selection

## Sources

Inspect authoritative current sources when an API decision depends on versions or provider policy.
Prefer the installed dependency source and test suite over third-party summaries.

| Source | Purpose |
|---|---|
| https://github.com/can1357/oh-my-pi | Oh My Pi coding capability reference |
| https://github.com/can1357/oh-my-pi/tree/main/docs | Current tool, session, settings, Eval, and skill reference |
| https://github.com/agentjido/jido | Jido agent lifecycle, Actions, signals, and supervision |
| https://hexdocs.pm/jido_ai | Jido.AI strategies, model aliases, and ReqLLM integration |
| https://hexdocs.pm/req_llm | Provider transports, model discovery, streaming, and authentication |
| https://hexdocs.pm/quickbeam | Optional JavaScript Eval runtime and injected host APIs |
| https://hexdocs.pm/snakepit | Optional Python Eval worker pools and session affinity |
| https://hexdocs.pm/snakebridge | Optional typed Python library bindings |

The source versions can change. Verify package names, versions, and API functions against `mix.lock`.
Do not copy an example from a newer version without checking compatibility.

## How to use Oh My Pi

Study Oh My Pi to understand effective coding workflows, tool behavior, context policy, delegation, and model prompts.
Map each important behavior to the nearest Jido or Elixir primitive.
Use reference behavior tests for outcomes, safety, and recoverability when useful.
Do not require identical TypeScript classes, package boundaries, JSON encoders, runtime schemas, or hidden factories.

## Reuse candidates

Review the packages already present in the Igniter scaffold before adding dependencies.
The command requested `jido_ai`, `quickbeam`, `snakepit`, `vibe_kit`, and `usage_rules`.
The installers for QuickBEAM and Snakepit did not run, but the packages can still appear in `mix.exs`.

Jido.AI can already depend on Jido, Jido Action, and ReqLLM.
Keep direct dependency declarations only when source imports or maintenance policy justify them.
Use VibeKit only if it adds a needed harness capability without replacing the Jido runtime.
Use `usage_rules` to inspect package conventions. Preserve the existing `AGENTS.md` content.

Consider existing Jido filesystem, shell, MCP, browser, and memory integrations before custom adapters.
Do not force optional integrations into the core dependency closure if the host already supplies them.

## Native-code approval test

1. Identify a missing operation or measurable performance bottleneck.
2. Inspect existing Elixir and Jido implementations.
3. Compare a pure Elixir solution with available native packages.
4. Document correctness fixtures and worst-case resource use.
5. Measure latency and memory on realistic concurrent workloads.
6. Select Rustler, Zigler, or an external executable only after the evidence supports it.
7. Keep the public interface a normal Elixir behavior or Jido Action.

## License handling

Do not copy upstream source or prompt material without a license review.
Preserve applicable copyright and permission notices for any permitted reuse.
Prefer an original Elixir implementation based on observed behavior and public interfaces.
