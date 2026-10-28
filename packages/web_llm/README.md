# WebLLM for ReqLLM

`web_llm` makes [WebLLM](https://webllm.mlc.ai) models, which run on the user's GPU through WebGPU inside a web page, ordinary [ReqLLM](https://github.com/agentjido/req_llm) models. The provider is `:web_llm`. It needs no API key: requests never leave the user's browser.

Elixir code reaches the page in one of two ways:

| Where your BEAM runs | Transport | Example |
|---|---|---|
| In the page (Popcorn, WebAssembly) | `WebLLM.Popcorn.FetchStream` through the page's `fetch` | [`examples/browser`](../../examples/browser) |
| On a server | `WebLLM.Live.Transport` through the user's Phoenix LiveView socket | [`examples/phoenix_webgpu`](../../examples/phoenix_webgpu) |

Either way the page runs the JavaScript bridge in `priv/static/web_llm.js`. It loads the model, translates OpenAI chat-completion requests for WebLLM and streams the answer back. Tool calls work with models that lack WebLLM's native function calling: tools are described in the system prompt and `<tool_call>` blocks come back as OpenAI `tool_calls`. Thinking (`<think>...</think>`) comes back as `reasoning_content`, separate from the answer.

This is a staging library. Some pieces are meant to become ReqLLM changes; see [Upstream](#upstream).

## Install

```elixir
def deps do
  [
    {:web_llm, path: "packages/web_llm"},
    # Optional, for the LiveView component and transport:
    {:phoenix_live_view, "~> 1.1"}
  ]
end
```

`web_llm` needs the ReqLLM change that lets a request choose its stream transport. This repository's vendored ReqLLM (`vendor/req_llm`) has it.

## Models

```elixir
model = WebLLM.model("Qwen3-8B-q4f16_1-MLC")
{:ok, response} = ReqLLM.stream_text(model, "Hello!", receive_timeout: 300_000)
```

`WebLLM.model/2` returns a ReqLLM model spec. The id is any WebLLM model id, from WebLLM's prebuilt list or from extra records you give the bridge. Options:

| Option | Default | Meaning |
|---|---|---|
| `:client` | none | The LiveView client that runs the model (server use) |
| `:context_window` | `16_384` | Context the page engine is configured for |
| `:max_output` | `4_096` | Output token limit |
| `:reasoning` | `false` | Whether the model is treated as a reasoning model |

A local model can stay silent for a long time during prefill, or while it thinks on a slow GPU. ReqLLM's `receive_timeout`, 30 seconds by default, bounds each wait for the next update. Set it higher for WebLLM requests.

`WebLLM.Provider` declares `credentials_required?/0` as `false`. Hosts that resolve a credential per request, such as Oh-My-Jido, skip resolution for these models.

## In the page (Popcorn)

Route every ReqLLM request through the page's `fetch`; a BEAM compiled to WebAssembly has no sockets:

```elixir
# config/config.exs
config :req_llm, finch_stream_adapter: WebLLM.Popcorn.FetchStream
config :web_llm, transport: WebLLM.Popcorn.FetchStream
```

Serve `priv/static/web_llm.js` and `web_llm_worker.js` with your page, and install the bridge before the VM starts:

```js
import { createBridge } from "./vendor/web_llm/web_llm.js";

const bridge = createBridge({
  moduleUrl: new URL("./vendor/web-llm/index.js", location.href), // @mlc-ai/web-llm 0.2.86
  workerUrl: new URL("./vendor/web_llm/web_llm_worker.js", location.href),
});
bridge.installFetchShim(); // sets globalThis.webLLMFetch for https://web-llm.invalid
```

`WebLLM.Popcorn.FetchStream` calls `globalThis.webLLMFetch`, which answers `https://web-llm.invalid` from the bridge and passes every other URL to `fetch`. The page's own `fetch` is unchanged. Requests load their model on demand. Call `bridge.load(model, onProgress)` to warm a model up front and show progress.

## On a server (Phoenix LiveView)

Render the component in the user's LiveView. Give each page its own client id:

```heex
<.live_component
  module={WebLLM.Live.Component}
  id="web-llm"
  client={@client}
  model="Qwen3-8B-q4f16_1-MLC"
  preload={false}
/>
```

```elixir
def mount(_params, _session, socket), do: {:ok, assign(socket, client: WebLLM.new_client())}
```

Register the hook in `app.js`. With esbuild, `NODE_PATH` already resolves dependencies (`import {WebLLMHook} from "web_llm"`). Without a bundler, serve `priv/static` (`plug Plug.Static, at: "/deps/web_llm", from: {:web_llm, "priv/static"}`) and map `web_llm` in an import map:

```js
import { WebLLMHook } from "web_llm";
const liveSocket = new LiveSocket("/live", Socket, { hooks: { WebLLM: WebLLMHook } });
```

`WebLLMHook` loads `@mlc-ai/web-llm` from `https://esm.run/@mlc-ai/web-llm@0.2.86`. To serve it yourself, for example under a strict content security policy, build the hook with `createWebLLMHook({moduleUrl: "/vendor/web-llm/index.js"})`.

Any server process can now use that browser's GPU:

```elixir
model = WebLLM.model("Qwen3-8B-q4f16_1-MLC", client: client)
ReqLLM.stream_text(model, "Summarise this page", receive_timeout: 300_000)
```

You can also choose the browser per request instead of in the model, with a header:

```elixir
req_http_options: [headers: [{WebLLM.client_header(), client}]]
```

The request fails with a transport error if the browser is not connected, if its LiveView process exits, or if no update arrives within `receive_timeout`. A timeout, or the calling process exiting, stops generation in the page. `WebLLM.Live.Transport` logs the reason, because ReqLLM reports every transport failure the same way.

### Run JavaScript in the page

`allow_eval={true}` lets server code run JavaScript in that page:

```elixir
{:ok, "Hello"} = WebLLM.Live.eval(client, ~s|document.querySelector("h1").textContent = "Hello"|)
```

A single expression returns its value; anything else runs as the body of an async function and returns what it returns. Results come back JSON-encoded. The code runs with the page's full authority. Only pass source that trusted server code chooses, or that a model you deliberately granted this capability produced. Never pass user-supplied text.

## Wire protocol

Both transports exchange the same messages with the bridge. A request is a JSON object with `id`, `method`, `url`, `headers` and `body`, the JSON text of an OpenAI chat-completion request. The bridge answers with events carrying the request `id` and a `type`: `status`, `headers`, zero or more `data` (OpenAI SSE text, or one JSON completion when `stream` is false), then `done`. An `error` event can end a request at any point. A cancel message carries the request `id`.

## Testing

Set `globalThis.webLLMEngineFactory = async (model, progress) => engine` in the page to replace the GPU engine with a fake one; the Playwright suites in both examples do this. `mix ci` runs the ExUnit tests (provider, transport and component behaviour), the JavaScript tests (`node --test 'test/js/*.test.mjs'`), Credo, Dialyzer, ExDNA and Reach.

## Upstream

These pieces are meant to become ReqLLM changes:

- **Per-request stream transport.** ReqLLM's streaming client calls `Finch.stream/5` directly. The vendored change lets a provider name a transport in the Finch request's private `:req_llm_stream_transport`, or the application configure `:finch_stream_adapter`. Non-streaming requests already accept a Req adapter.
- **Keyless providers.** ReqLLM has no way for a provider to say it needs no credentials. `credentials_required?/0` is a candidate.
- **Reasoning records per chunk.** ReqLLM's default response builder keeps one `reasoning_details` record per streamed reasoning chunk. A model that streams `reasoning_content` token by token grows the conversation by about 150 bytes per token. The bridge batches reasoning to avoid this.

The provider, the transports, the LiveView component and the bridge can live in this package or move into ReqLLM.
