# Oh-My-Jido in the browser

This example runs the whole Oh-My-Jido agent in a browser tab. The runtime, sessions, the Jido.AI ReAct loop, ReqLLM, the tools and the Eval kernels all run on [Popcorn](https://popcorn.hexdocs.pm/) 1.0, the Erlang/OTP 29 VM compiled to WebAssembly. The server only sends static files.

The agent can change the page it is running in: ask it to rename the heading or restyle the page, and it does so with a JavaScript Eval cell against the live DOM.

## What runs where

| Part | Where it runs |
|---|---|
| Oh-My-Jido runtime, sessions, ReAct loop, ReqLLM, tools | The tab's BEAM (Popcorn, in a Web Worker) |
| Model HTTP | The page's `fetch()`, through `WebLLM.Popcorn.FetchStream` from `packages/web_llm` |
| JavaScript Eval | The page itself, through `new Function` |
| Python Eval | [Pyodide](https://pyodide.org/) in its own Web Worker, one per kernel |
| Local models | [WebLLM](https://github.com/mlc-ai/web-llm) in a Web Worker, on WebGPU |
| Workspace files | An in-memory directory in the BEAM, lost on reload |
| Server | `mix oh_my_jido_browser.serve`: static files on `127.0.0.1` only |

## Models

Pick the model in the page.

- **OpenRouter: `openai/gpt-6-luna`, low reasoning.** Paste an OpenRouter API key into the page. It is encrypted with AES-GCM under a non-extractable WebCrypto key and kept in this browser's IndexedDB, so it survives reloads; **Forget key** deletes it. It is sent only to `openrouter.ai`.
- **Local models through WebLLM.** Qwen3 (1.7B, 4B, 8B), Qwen2.5 7B, Llama 3.1 8B and Hermes 3 run on your GPU; prompts stay in the browser. Local models are keyless: no account or credential resolver is used. The first load downloads the weights from Hugging Face (1–5 GB) and the browser caches them. WebLLM needs WebGPU (current Chrome or Edge).

The WebLLM bridge, fetch transport and ReqLLM `:web_llm` provider come from [`packages/web_llm`](../../packages/web_llm). `WebLLM.model(id)` selects the provider and its OpenAI-compatible endpoint at `https://web-llm.invalid/v1`. That host never resolves: the shared JavaScript bridge answers the request inside the page, streaming OpenAI server-sent events back from the WebLLM engine. Tool calls use the `<tool_call>{json}</tool_call>` format Qwen and Hermes models are trained on. WebLLM's own `tools` option is not used, because it forbids a custom system prompt and fails whenever the model answers in plain text instead of calling a tool.

**Self-hosted models.** List extra WebLLM model records in `public/models/models.json` (ignored by Git); their `model` and `model_lib` URLs are relative to that file. WebLLM fetches weights from `<model>/resolve/main/<file>`, so put or symlink each MLC build at `public/models/<id>/resolve/main/`. The page offers every listed model and loads its weights from this origin, not from Hugging Face. [Build a model](#build-a-model) shows how.

**Sign in with ChatGPT is not offered.** OpenAI serves its OpenID discovery document and signing keys without CORS headers, and its streaming inference responses carry no `Access-Control-Allow-Origin` header, so the browser refuses to let the page read them (`MissingAllowOriginHeader`). An experiment that bundled the discovery document and keys completed sign-in, but inference still failed.

## Tools

| Tool | In the browser |
|---|---|
| `eval` | `javascript` cells run in the page with its full authority (DOM, styles, `window`, `fetch`); `python` cells run in Pyodide. State persists across cells. `console.log`/`print` output is captured, `display(value)` adds a display value, and `await tool(name, parameters)` calls the session's other tools. |
| `read`, `edit`, `write` | Files in the in-memory workspace |
| `question` | Questions appear as cards with answer buttons |

Shell commands, search (ripgrep), Git, language servers, debuggers and MCP stdio servers need operating-system processes, so they are not available. Elixir Eval needs a separate ERTS, which this example does not provide. See the [capability classification](../../docs/oh-my-jido/BROWSER_PORT.md).

## Run it

The example pins OTP 29 and Elixir 1.20.4 in `mise.toml`; run Mix through `mise exec` (or an activated mise shell).

```sh
cd examples/browser
npm ci                                  # Pyodide, WebLLM, Playwright
mise exec -- mix deps.get
mise exec -- mix oh_my_jido_browser.assets   # copy Pyodide, WebLLM and the shared bridge into public/
MIX_ENV=prod mise exec -- mix popcorn.cook   # build public/out
mise exec -- mix oh_my_jido_browser.serve    # http://127.0.0.1:4010/
```

Open <http://127.0.0.1:4010/>. The server sets the cross-origin isolation headers Popcorn needs (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`) and a content security policy that allows the page's own scripts, `eval` (Popcorn and JavaScript Eval need it), WebAssembly, and connections only to OpenRouter and the Hugging Face and GitHub hosts WebLLM downloads from.

The cooked bundle is about 37 MB compressed. It keeps debug and documentation chunks, because Popcorn's default stripping also removes the module attributes ReqLLM uses to find its providers (`config :popcorn, strip: false`). Pyodide adds about 12 MB the first time Python runs.

## Test it

```sh
npx playwright install chromium-headless-shell   # once
mise exec -- mix ci
```

`mix ci` compiles with warnings as errors, checks formatting, runs Credo, Dialyzer, ExDNA and Reach, and runs `test/browser_test.exs`. That test cooks the end-to-end build (`MIX_ENV=e2e`), serves it on a free loopback port and runs `e2e/browser.spec.js` in headless Chromium:

1. The agent reads the page title in a JavaScript cell, asks which accent color to use, computes a value in a Python cell that writes it to the workspace, edits that file, and rewrites the live title and accent from JavaScript. The model turns are scripted (`e2e/fixture/fixture.ex`); everything else is real.
2. A local WebLLM model drives a tool call through the in-page bridge. A stand-in engine replaces WebGPU inference, but ReqLLM, the streaming transport, the bridge, the ReAct loop and the Eval kernel are real.
3. The OpenRouter key is stored encrypted, survives a reload and can be forgotten.
4. The in-browser capability probes (`e2e/fixture/probes.ex`, `e2e/fixture/eval_probes.ex`) exercise sessions, control, recovery, delegation, memory, custom tools and Eval safety inside the browser VM.

## How it works

The library changes this example relies on are small and general:

- **Streaming without sockets.** ReqLLM normally streams through Finch. `config :req_llm, finch_stream_adapter: WebLLM.Popcorn.FetchStream` makes it use the shared package's `Finch.stream/5` transport through the page's `fetch()`. `config :web_llm, transport: WebLLM.Popcorn.FetchStream` selects the same transport for the local provider. Provider request hooks still run first.
- **Host Eval backends.** `eval: [backends: %{javascript: [backend: Module]}]` plugs any `OhMyJido.Eval.Backend` into the standard Eval tool. The kernel controller still owns deadlines, cancellation, output budgets, redaction and tool callbacks.
- **Filesystems without hard links.** Creating a file publishes it with a hard link so it never overwrites. The browser's in-memory filesystem has no hard links, so the write tool reserves the name exclusively and then renames the staged content over the reservation.

`OhMyJidoBrowser.UI` renders the transcript and controls with `Popcorn.JS`. It only touches the status line, model picker, transcript, question cards and key form, so changes the agent makes to the rest of the page stay in place.

`public/app.js` creates one shared `createBridge` instance and installs its `webLLMFetch` shim before starting Popcorn. The small `window.ohMyJidoLocalModels` adapter keeps the model picker and progress messages connected to Elixir. The assets task copies the shared bridge and worker into `public/vendor/web_llm/`, alongside the inference engine in `public/vendor/web-llm/`, so all scripts load from the page's own origin.

## Build a model

WebLLM runs MLC builds: quantized weights plus a WebGPU model library. A model library must match the WebLLM runtime that loads it. These steps produce Qwen3.8 27B ("heretic-ara") at `q3f16_1` (3-bit) for WebLLM 0.2.86. A Qwen3.5 0.8B library compiled the same way loaded and answered correctly on an RTX 5090 Laptop GPU in Chrome.

1. **Use the toolchain the runtime was built with.** `binary-mlc-llm-libs/web-llm-models/v0_2_86/build-manifest.json` names TVM `akaashrp/tvm@be03dc94`, MLC-LLM `akaashrp/mlc-llm@42fa8558` and Emscripten 3.1.56. Build TVM with LLVM (`cmake -G Ninja -DUSE_LLVM=llvm-config-18 -DUSE_CUDA=OFF`, then `ninja`); install its `3rdparty/tvm-ffi` from source (`SETUPTOOLS_SCM_PRETEND_VERSION=0.1.14.post1 pip install --no-build-isolation`); run `make` in `tvm/web` and `mlc-llm/web` under Emscripten 3.1.56. If another Emscripten is active, unset `EM_LLVM_ROOT`, `LLVM_ROOT`, `EM_BINARYEN_ROOT`, `BINARYEN` and `EMCC_CACHE` first, or the old `emcc` silently uses the newer LLVM.
2. **Run MLC from source** with `PYTHONPATH=tvm/python:mlc-llm/python`, `TVM_LIBRARY_PATH=tvm/build/lib` and `SKIP_LOADING_MLCLLM_SO=1` (compilation needs no MLC C++ library). Python needs `numpy`, `ml_dtypes`, `tqdm`, `pydantic` and `requests`; reading BF16 safetensors with `numpy` and `ml_dtypes` avoids installing PyTorch.
3. **Write `mlc-chat-config.json`** from WebLLM's Qwen3.5 configuration with the model's dimensions, `"quantization": "q3f16_1"`, `context_window_size` 16384, `prefill_chunk_size` 1024 and the tokenizer's real stop tokens (`<|im_end|>` 248046, `<|endoftext|>` 248044; Qwen3.5's 248,320-token vocabulary does not use Qwen2's ids).
4. **Compile the library:** `python -m mlc_llm compile mlc-chat-config.json --device webgpu --overrides prefill_chunk_size=1024 -o model-webgpu.wasm`. For the 27B model MLC estimates 11.6 GB of parameters, 1.2 GB of buffers and 0.25 MB of KV cache per context token.
5. **Quantize the weights:** `python -m mlc_llm convert_weight <hugging-face-dir> --quantization q3f16_1 --model-type qwen3_5 --device cpu -o <output-dir>`, then add the record to `public/models/models.json`.

## Security

- **JavaScript Eval has the page's full authority.** It can read and change anything on the page, call `fetch` (limited by the content security policy to the hosts above) and decrypt the saved API key through `window.ohMyJidoSecrets`. Only give the agent tasks you would run in your own browser console.
- **File changes need no approval.** The workspace lives in memory and disappears on reload. Agent questions still wait for your answer.
- **The key stays in the browser.** It is never logged, never sent to the static server, and redacted from Elixir crash reports.
