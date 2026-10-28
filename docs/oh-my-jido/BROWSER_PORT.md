# Oh-My-Jido in the browser

This document classifies every row of the [capability matrix](CAPABILITY_MATRIX.md) for the browser port. Each row is either **verified in the browser**, with the test or recorded run that shows it, or **unavailable**, with the browser limit that rules it out.

The browser port has three parts:

| Part | What it is |
|---|---|
| [`examples/browser`](../../examples/browser) | The library running entirely inside a web page: Oh-My-Jido, Jido, ReqLLM and their dependencies in an OTP 29 BEAM compiled to WebAssembly (Popcorn 1.0). The agent edits its own live page through JavaScript Eval. |
| [`packages/web_llm`](../../packages/web_llm) | WebLLM (in-browser WebGPU inference) as a keyless ReqLLM provider. A BEAM in the page reaches it through `fetch`; a BEAM on a server reaches it through the user's Phoenix LiveView socket. |
| [`examples/phoenix_webgpu`](../../examples/phoenix_webgpu) | A server-side Oh-My-Jido agent that delegates a subagent to the user's browser GPU; the subagent acts on the user's page. |

## Evidence

| Label | Source |
|---|---|
| S1 | `examples/browser/e2e/browser.spec.js`, "the agent changes its own page through JavaScript and Python Eval": scripted model; JavaScript and Python cells, `read`/`write`/`edit` through Eval, a question answered in the page, the title and accent changed in the same document. |
| S2 | Same file, "a local WebLLM model drives tool calls through the in-page bridge": the real ReqLLM streaming path into the WebLLM bridge with a fake GPU engine; asserts the system prompt, offered tools, tool-call round trip and usage. |
| S3 | Same file, "the OpenRouter key is stored encrypted, survives a reload and can be forgotten". |
| S4 | Same file, "the library's capability probes pass inside the browser VM": the probes in `examples/browser/e2e/fixture/probes.ex` and `eval_probes.ex` run through the public API inside the page VM and must all pass. Probe IDs match matrix rows. |
| D | `examples/phoenix_webgpu/e2e/demo.spec.js`: a server parent delegates to the GPU of the requesting tab only, over the LiveView socket; the child changes that page. |
| R1, R2, R3 | Recorded real runs in [`evidence/browser-port-20261028.json`](evidence/browser-port-20261028.json): R1 OpenRouter `openai/gpt-6-luna` in the page; R2 Llama 3.1 8B on WebGPU in the page; R3 server parent on OpenRouter delegating to Qwen3 8B on the user's WebGPU. |

S1 to S4 run in `examples/browser`'s `mix ci`; D runs in `examples/phoenix_webgpu`'s `mix ci`. Both use headless Chromium and need no credentials or network.

## Browser limits

| Limit | Meaning |
|---|---|
| L1 No processes | WebAssembly in a page cannot start executables: no ripgrep, Git, shells, language servers, debug adapters, separate ERTS nodes, MCP stdio servers or the Claude Code CLI. Probe L1 (S4) checks that these tools fail closed in the page: each call returns a typed error and the session stays usable. |
| L2 Cross-origin reads | A page can only read responses that carry CORS headers for its origin. OpenAI's sign-in and inference endpoints, search engines and arbitrary web pages do not. |
| L3 No sockets | No TCP, so no Erlang distribution to other nodes. |
| L4 No procfs | No `/proc` or Linux process accounting. |

## Classification

| ID | Capability | In the browser | Evidence or limit |
|---|---|---|---|
| A01 | Embeddable package | Verified | `OhMyJidoBrowser.Application` supervises `{OhMyJido, options}` inside the page VM; every spec boots it (S1–S4). |
| A02 | Jido agent runtime | Verified | Native Jido.AI ReAct runs in S1 and S2, and with real models in R1 and R2. |
| A03 | Multi-instance isolation | Verified | Probe A03 (S4). |
| A04 | Typed events | Verified | The page renders only from session events: S1 asserts the question card, five tool messages and the streamed answer; probe F03 observes run telemetry. |
| A05 | Control | Verified | Probe A05: steering, cancellation, suspension and resume (S4). |
| A06 | Durable sessions | Verified | Probe A06: checkpoint, worker replacement and resume from ETS storage in the VM (S4). Storage lasts as long as the page. |
| A07 | Fault recovery | Verified | Probe A07 (S4). |
| A08 | Bounded concurrency | Verified | Probe A08 (S4). |
| B01 | Provider transport | Verified | ReqLLM streams through the page's `fetch` (`WebLLM.Popcorn.FetchStream`): R1 (OpenRouter SSE with tool calls and usage), S2 and R2 (WebLLM). |
| B02 | Model roles | Verified | Probe B02 (S4). |
| B03 | Account switching | Verified | One page switches between the explicit OpenRouter account and keyless local models (S2, S3); R1 ran on the OpenRouter account. |
| B04 | Codex subscription | Unavailable | L2: `POST https://api.openai.com/v1/responses` answers 200 without `Access-Control-Allow-Origin` (Chromium reports `MissingAllowOriginHeader`), and OpenID discovery and JWKS on `auth.openai.com` lack CORS headers, so a page can neither sign in nor read inference. |
| B05 | Claude authorization | Unavailable | L1: authorization belongs to the official Claude Code executable. |
| B06 | API credentials | Verified | S3: the OpenRouter key is entered explicitly, kept AES-GCM-encrypted in IndexedDB under a non-extractable key, survives a reload and can be forgotten. R1 used only that account. |
| B07 | Model guidance | Verified | S2 asserts the selected model's identity in the system prompt it receives; the recorded prompt carries guidance for a model without parallel tool calls or image input (evidence `system_prompt_guidance`). |
| B08 | Usage and limits | Verified | S2 asserts aggregated usage in the page; R1 reports tokens and cost; R3 reports the GPU child's tokens. Plan limits are subscription metadata (B04). |
| B09 | Context policy | Verified | Probe B09: a small message budget forces extractive compaction and retained facts survive it (S4). |
| B10 | Project instructions | Verified | Probe B10: host instructions outrank approved project instructions; unapproved project text and task metadata gain no authority (S4). S2's prompt carries the trusted host instructions. |
| B11 | Role-aware tool guidance | Verified | S2 asserts that only granted tools (`edit`, `eval`, `question`, `read`, `write`) are offered and that `shell`, `search`, `git`, `list`, `lsp` and `browser` are not. |
| C01 | File reading | Verified | S1: a JavaScript cell reads a workspace file with `tool("read")`. |
| C02 | Safe writing | Verified | S1: a Python cell creates a file with `tool("write")`. The in-memory filesystem has no hard links; `OhMyJido.Files` now falls back to an exclusive create for create-without-overwrite. |
| C03 | Precision editing | Verified | S1: a snapshot-guarded `edit`. |
| C04 | Search | Unavailable | L1: search runs ripgrep. In the page, a call returns `{:capability_unavailable, :ripgrep}` (probe L1). |
| C05 | Shell/process | Unavailable | L1. In the page, a call returns `{:executable_not_found, "sh"}` (probe L1). |
| C06 | Git workflows | Unavailable | L1: Git is an executable. In the page, a call returns `:enoent` (probe L1). |
| C07 | Structural code work | Verified | Probe C07: ExAST search in the VM (S4). |
| C08 | LSP | Unavailable | L1: language servers are separate processes. |
| C09 | DAP | Unavailable | L1: debug adapters are separate processes. |
| C10 | Test-driven edits | Unavailable | L1: the project's test command runs through Shell. |
| C11 | Image/artifact inputs | Verified | Probe C11 (S4). |
| C12 | Security and review | Unavailable | L1: review reads tracked Git changes, and the sensitive effects it guards (shell, Git mutation) cannot occur. The approval path itself works (S1). |
| C13 | Headless live Observer | Verified | Probe C13 against the page VM (S4). Remote targets need distribution (L3). |
| C14 | Live runtime tools | Unavailable | L1: Tidewave is reached through an MCP client process. |
| D01 | Subagents | Verified | Probe D01 (S4); D and R3 run a subagent whose model is the user's GPU. |
| D02 | Parallel exploration | Verified | Probe D02 (S4). |
| D03 | Worktree isolation | Unavailable | L1: Git worktrees. |
| D04 | Parent control | Verified | Probe D04 (S4). |
| D05 | Checkpoints | Verified | Probe D05 (S4). |
| D06 | Task memory | Verified | Probe D06 (S4). |
| D07 | Skills and rules | Verified | Probe D07 (S4). |
| D08 | Custom tools | Verified | Probe D08 (S4). The JavaScript and Python Eval backends are host-supplied modules (`eval: [backends: [...]]`, root test `test/eval_host_backend_test.exs`). |
| D09 | MCP integration | Unavailable | L1: the shipped binding starts MCP servers over stdio. |
| D10 | Browser integration | Unavailable | L2: the Browser action drives a host-owned browser through an adapter; a page cannot open or script other sites. The agent acts on its own page through JavaScript Eval instead (S1, R1, R2), and a server agent can act on a user's page through `web_llm` (D, R3). |
| D11 | Human questions | Verified | S1: the agent asks which accent to use and the answer from the page continues the run. |
| D12 | Review and advisor | Unavailable | L1: the review action reads Git changes. The role and subagent mechanics advisors use are verified (B02, D01). |
| D13 | Goal and plan workflows | Unavailable | L1: completing a goal requires the effect IDs of successful Shell checks. |
| D14 | Iterative experiments | Verified | Probe D14 (S4). |
| D15 | Research and external search | Unavailable | L2: search engines and arbitrary pages do not send CORS headers to the app's origin. |
| E01 | Unified Eval | Verified | S1: one `eval` tool runs JavaScript and Python cells in one session; probes E05 and E06. |
| E02 | Elixir Eval | Unavailable | L1: the backend isolates cells in a separate ERTS. |
| E03 | JavaScript Eval | Verified | With a host backend that runs cells in the page (`OhMyJidoBrowser.Eval.JavaScript`) instead of QuickBEAM, a native library a WebAssembly BEAM cannot load: S1, probe E05. |
| E04 | Python Eval | Verified | With a Pyodide backend in a Web Worker (`OhMyJidoBrowser.Eval.Python`) instead of Snakepit's Python processes: S1, probes E05 and E06. |
| E05 | Eval output | Verified | Probe E05: stdout, display values, errors, truncation and state across cells (S4). |
| E06 | Eval safety | Verified | Probe E06: permission check, hard timeout of a busy cell, invalidation and reset (S4). |
| E07 | Host tools in Eval | Verified | S1: Python `await tool("write", ...)` and JavaScript `await tool("read", ...)`. |
| F01 | Standard Elixir configuration | Verified | `config/config.exs` (`import Config`) selects the fetch transport, the WebLLM transport, logging and the test fixture inside the cooked VM; every spec depends on it. |
| F02 | Testability | Verified | S1–S4 and D run without credentials or network, with scripted models and a fake GPU engine. |
| F03 | Observability | Verified | Probe F03: attached telemetry receives run events, then detaches (S4). |
| F04 | Density benchmark | Unavailable | L1 and L4: the harness measures populations with real Linux subprocesses and procfs. |
| F05 | Platform support | Verified | The browser is a new platform: headless Chromium on Linux runs every spec; Chrome on Windows with an NVIDIA RTX 5090 Laptop GPU ran R2 and R3 on WebGPU. |
| F08 | End-to-end coding task | Unavailable | L1: "passing tests" means running the project's tests through Shell. The page agent completes multi-tool tasks without them (S1, R1). |
| F09 | Documentation | Verified | [Browser guide](../guides/browser.md), [`examples/browser`](../../examples/browser/README.md), [`packages/web_llm`](../../packages/web_llm/README.md), [`examples/phoenix_webgpu`](../../examples/phoenix_webgpu/README.md) and this document. |

43 rows are verified in the browser and 19 are unavailable: 16 because a page cannot start processes, and 3 because of cross-origin reads (B04, D10, D15).

## Substitutions and changes

Running in a page required these replacements, each covered above:

| Native piece | Browser replacement |
|---|---|
| Finch sockets | `WebLLM.Popcorn.FetchStream` streams through `fetch`; ReqLLM accepts a configured or per-request stream transport (vendored ReqLLM change, proposed upstream). |
| QuickBEAM JavaScript Eval | Cells run in the page itself. |
| Snakepit Python Eval | Pyodide in a Web Worker. |
| Hard-link create in `OhMyJido.Files` | Exclusive create, then rename, when the filesystem has no hard links. |
| Subscription sign-in (B04) | OpenRouter API key, stored encrypted in the browser. |
| Hosted models only | WebLLM models on the user's GPU, keyless: OhMyJido skips credential resolution for providers that declare `credentials_required?/0` false. |
