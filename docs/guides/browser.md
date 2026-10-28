# Run the agent in a browser

Oh-My-Jido runs inside a browser tab on [Popcorn](https://popcorn.hexdocs.pm/) 1.0, the Erlang/OTP 29 VM compiled to WebAssembly. The [browser example](../../examples/browser/README.md) is a complete application: the agent, its tools and its Eval kernels run in the tab, talk to OpenRouter or to a local WebLLM model, and change the page they run in. This guide lists what a browser host has to provide.

## What the browser changes

| Concern | In a browser |
|---|---|
| Model HTTP | No sockets: stream through the page's `fetch()` |
| Eval | No OS processes or dynamic NIFs: JavaScript and Python kernels come from the host |
| Files | An in-memory filesystem without hard links; contents are lost on reload |
| Shell, search, Git, LSP, DAP, MCP stdio | Unavailable: they start operating-system processes |
| Cross-origin requests | Only to services that send CORS headers |

## Build settings

Add Popcorn and a path dependency on `packages/web_llm` (adjust the path for your project). Keep module attributes in the bundle: ReqLLM finds its providers through `behaviour` attributes, which Popcorn's default stripping removes:

```elixir
# mix.exs: entries in deps/0
[
  {:popcorn, "1.0.0"},
  {:web_llm, path: "../../packages/web_llm"}
]

# config/config.exs
config :popcorn, strip: false
config :req_llm, load_dotenv: false, finch_stream_adapter: WebLLM.Popcorn.FetchStream
config :web_llm, transport: WebLLM.Popcorn.FetchStream
```

Build with the OTP version Popcorn's runtime was built for (OTP 29 for Popcorn 1.0) and `MIX_ENV=prod mix popcorn.cook`. Serve the output with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`. If you send a content security policy, it must allow `'unsafe-eval'` and `'wasm-unsafe-eval'`.

## Stream model responses through fetch

`config :req_llm, finch_stream_adapter: Module` makes ReqLLM call `Module.stream/5` instead of `Finch.stream/5` for streaming requests. The function receives the final `%Finch.Request{}`, after provider request hooks, and must deliver `{:status, status}`, `{:headers, headers}` and `{:data, chunk}` to the callback in order. It returns `{:ok, acc}` or `{:error, exception, acc}`. `WebLLM.Popcorn.FetchStream` from `packages/web_llm` provides this transport using `Popcorn.JS` and the browser's `fetch()`, and aborts the browser request when the calling process exits. It uses the shared bridge's `globalThis.webLLMFetch` shim for local inference and ordinary `fetch()` for other requests.

Only providers that answer with CORS headers work from a page. OpenRouter does. OpenAI's Sign in with ChatGPT inference responses do not.

## Run local models with WebLLM

The WebLLM bridge, fetch transport and ReqLLM `:web_llm` provider all come from [`packages/web_llm`](../../packages/web_llm). Use `WebLLM.model(model_id)` as the session's model spec. Local models are keyless: omit the account; no credential resolver or placeholder API key is needed. The provider targets `https://web-llm.invalid/v1`, which the bridge answers in the page without sending prompts to a server.

Copy `priv/static/web_llm.js` and `priv/static/web_llm_worker.js` from the `:web_llm` dependency into the site's `vendor/web_llm/` directory, and the `@mlc-ai/web-llm` inference engine into `vendor/web-llm/index.js`. The browser example's `mix oh_my_jido_browser.assets` task does both. Initialize a single bridge before starting Popcorn:

```javascript
import { createBridge } from "./vendor/web_llm/web_llm.js";

const bridge = createBridge({
  moduleUrl: new URL("./vendor/web-llm/index.js", location.href),
  workerUrl: new URL("./vendor/web_llm/web_llm_worker.js", location.href),
});
bridge.installFetchShim();
```

Keep both URLs on the page's origin when the content security policy allows only self-hosted scripts. `bridge.catalog()` is asynchronous; await its `{webgpu, models}` result before rendering the model picker. `bridge.load(model_id, onProgress)` can warm a model and report download progress; requests also load their model on demand. Inference needs WebGPU, and the first load downloads and caches the model weights.

## Provide Eval kernels

Select a host backend per language:

```elixir
{OhMyJido,
 name: MyApp.Coding,
 eval: [
   backends: %{
     javascript: [backend: MyApp.PageJavaScript],
     python: [backend: MyApp.Pyodide, boot_timeout: 120_000]
   }
 ]}
```

A backend implements `OhMyJido.Eval.Backend`. See [Supply your own backend](eval.md#supply-your-own-backend) for the contract. The example's backends run JavaScript in the page through `new Function` and Python in Pyodide workers, and forward output and tool calls through the kernel's bridge.

## Files and sessions

Point the session's workspace at a directory in the browser VM's in-memory filesystem, for example `/home/web_user/workspace`, and copy any starting files from your application's `priv` directory at boot. The write tool creates files without hard links on such filesystems: it reserves the name exclusively, then renames the staged content over it.

The default `Jido.Storage.ETS` storage keeps sessions across worker restarts inside the tab. Nothing survives a page reload unless you supply a `Jido.Storage` adapter backed by browser storage.

## Credentials

Do not put API keys in the application config: Popcorn ships config to the browser. For remote providers such as OpenRouter, ask for the key in the page and resolve it per request from a credentials resolver, as the example's `OhMyJidoBrowser.Credentials` does. That module keeps the key encrypted in IndexedDB under a non-extractable WebCrypto key. Local `:web_llm` models need neither a key nor an account.
