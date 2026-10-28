// Browser WebGPU inference exposed as OpenAI chat completions and LiveView events.
// WebLLM is imported lazily so this module also loads in Node without DOM globals.
const DEFAULT_MODULE_URL = "https://esm.run/@mlc-ai/web-llm@0.2.86";
const TOOL_CALL = "<tool_call>";
const THINK = "<think>";
let sequence = 0;

function uniqueId() {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${++sequence}`;
}

function webgpuAvailable() {
  return Boolean(globalThis.navigator && "gpu" in globalThis.navigator);
}

function messageText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => (typeof part === "string" ? part : (part?.text ?? ""))).join("");
  }
  return String(content);
}

function argumentsObject(value) {
  if (typeof value !== "string") return value ?? {};
  try {
    return JSON.parse(value);
  } catch (_error) {
    return {};
  }
}

function toolInstructions(tools) {
  return [
    "# Tools",
    "",
    "You may call one or more functions to assist with the user query.",
    "",
    "You are provided with function signatures within <tools></tools> XML tags:",
    "<tools>",
    tools.map((tool) => JSON.stringify(tool)).join("\n"),
    "</tools>",
    "",
    "For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:",
    "<tool_call>",
    '{"name": <function-name>, "arguments": <args-json-object>}',
    "</tool_call>",
    "",
    "When an action is needed, reply with the tool call itself. Never describe an action you are about to take without calling the tool in the same reply.",
  ].join("\n");
}

// WebLLM requires a single leading system turn, string assistant content and a
// final user/tool turn. Tool results are user turns in the model's XML protocol.
function localMessages(messages, tools) {
  const system = [];
  const turns = [];
  for (const message of messages) {
    if (message.role === "system" || message.role === "developer") {
      system.push(messageText(message.content));
    } else if (message.role === "assistant") {
      const calls = (message.tool_calls ?? []).map((call) =>
        `${TOOL_CALL}\n${JSON.stringify({
          name: call.function?.name,
          arguments: argumentsObject(call.function?.arguments),
        })}\n</tool_call>`,
      );
      turns.push({
        role: "assistant",
        content: [messageText(message.content), ...calls].filter(Boolean).join("\n"),
      });
    } else if (message.role === "tool") {
      turns.push({ role: "user", content: `<tool_response>\n${messageText(message.content)}\n</tool_response>` });
    } else {
      turns.push({ role: "user", content: messageText(message.content) });
    }
  }
  if (tools.length > 0) system.push(toolInstructions(tools));
  const merged = [];
  for (const turn of turns) {
    const previous = merged.at(-1);
    if (previous?.role === turn.role) previous.content += `\n\n${turn.content}`;
    else merged.push({ ...turn });
  }
  if (merged.at(-1)?.role !== "user") merged.push({ role: "user", content: "" });
  const leading = system.filter(Boolean).join("\n\n");
  return leading === "" ? merged : [{ role: "system", content: leading }, ...merged];
}

function localRequest(request) {
  const options = {
    messages: localMessages(request.messages ?? [], request.tools ?? []),
    stream: true,
    stream_options: { include_usage: true },
    extra_body: { enable_thinking: true },
  };
  for (const field of ["temperature", "top_p", "seed", "stop", "presence_penalty", "frequency_penalty"]) {
    if (request[field] != null) options[field] = request[field];
  }
  const maxTokens = request.max_completion_tokens ?? request.max_tokens;
  if (maxTokens != null) options.max_tokens = maxTokens;
  return options;
}

function visible(output, final = false) {
  const trimmed = output.trimStart();
  // Hold incomplete opening tags too, so a token boundary cannot leak thinking.
  if (!final && trimmed.length > 0 && THINK.startsWith(trimmed)) return null;
  if (!trimmed.startsWith(THINK)) return trimmed;
  const end = trimmed.indexOf("</think>");
  return end < 0 ? null : trimmed.slice(end + "</think>".length).trimStart();
}

const CLOSE_THINK = "</think>";
const REASONING_BATCH_CHARS = 400;
const REASONING_BATCH_MS = 1500;

// The thinking text produced so far, minus a trailing partial "</think>".
function thinking(output, final = false) {
  const trimmed = output.trimStart();
  if (!trimmed.startsWith(THINK)) return "";
  const body = trimmed.slice(THINK.length);
  const end = body.indexOf(CLOSE_THINK);
  if (end >= 0) return body.slice(0, end);
  if (final) return body;
  for (let keep = Math.min(body.length, CLOSE_THINK.length - 1); keep > 0; keep--) {
    if (CLOSE_THINK.startsWith(body.slice(-keep))) return body.slice(0, body.length - keep);
  }
  return body;
}

function toolCalls(output) {
  const calls = [];
  for (const match of output.matchAll(/<tool_call>\s*([\s\S]*?)\s*<\/tool_call>/g)) {
    const call = JSON.parse(match[1]);
    if (typeof call?.name !== "string") throw new Error("A tool call has no name.");
    calls.push({
      index: calls.length,
      id: `call_${uniqueId().replaceAll("-", "")}`,
      type: "function",
      function: { name: call.name, arguments: JSON.stringify(call.arguments ?? {}) },
    });
  }
  return calls;
}

async function relay(chunks, model, emit, cancelled) {
  const base = {
    id: `chatcmpl-${uniqueId()}`,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model,
  };
  const delta = (value) => emit({
    ...base,
    choices: [{ index: 0, delta: value, finish_reason: null }],
  });
  let output = "";
  let mode = "undecided";
  let sent = 0;
  let reasoned = 0;
  let reasonedAt = Date.now();
  let finish = "stop";
  let usage;
  // Thinking streams as reasoning_content, so callers see progress during long
  // silent reasoning and it never mixes with the answer or tool calls. It goes
  // out in batches: consumers may keep one record per delta, and thousands of
  // token-sized records would swamp a conversation's context budget.
  const reason = (flush) => {
    const closed = flush || output.includes(CLOSE_THINK);
    const text = thinking(output, closed);
    const pending = text.length - reasoned;
    if (pending <= 0) return;
    if (!closed && pending < REASONING_BATCH_CHARS && Date.now() - reasonedAt < REASONING_BATCH_MS) return;
    delta({ reasoning_content: text.slice(reasoned) });
    reasoned = text.length;
    reasonedAt = Date.now();
  };
  delta({ role: "assistant" });
  for await (const chunk of chunks) {
    if (cancelled()) return;
    if (chunk.usage) usage = chunk.usage;
    const choice = chunk.choices?.[0];
    if (!choice) continue;
    if (choice.finish_reason) finish = choice.finish_reason;
    output += choice.delta?.content ?? "";
    reason(false);
    const shown = visible(output);
    if (shown === null || mode === "tools") continue;
    if (mode === "undecided") {
      if (shown.startsWith(TOOL_CALL)) mode = "tools";
      else if (shown.length > 0 && !TOOL_CALL.startsWith(shown)) mode = "content";
    }
    if (mode === "content" && shown.length > sent) {
      delta({ content: shown.slice(sent) });
      sent = shown.length;
    }
  }
  if (cancelled()) return;
  reason(true);
  const shown = visible(output, true) ?? "";
  let calls = [];
  if (mode !== "content" && shown.startsWith(TOOL_CALL)) {
    try {
      calls = toolCalls(shown);
    } catch (_error) {
      calls = [];
    }
  }
  if (calls.length > 0) {
    delta({ tool_calls: calls });
    finish = "tool_calls";
  } else if (shown.length > sent) {
    delta({ content: shown.slice(sent) });
  }
  const usageFields = usage ? {
    usage: {
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
    },
  } : {};
  emit({ ...base, choices: [{ index: 0, delta: {}, finish_reason: finish }], ...usageFields });
}

function completionCollector() {
  let result;
  return {
    emit(chunk) {
      result ??= {
        id: chunk.id,
        object: "chat.completion",
        created: chunk.created,
        model: chunk.model,
        choices: [{ index: 0, message: { role: "assistant", content: "" }, finish_reason: null }],
      };
      const choice = chunk.choices[0];
      const target = result.choices[0];
      if (choice.delta.content) target.message.content += choice.delta.content;
      if (choice.delta.reasoning_content) {
        target.message.reasoning_content = (target.message.reasoning_content ?? "") + choice.delta.reasoning_content;
      }
      if (choice.delta.tool_calls) {
        target.message.tool_calls = choice.delta.tool_calls.map(({ index: _index, ...call }) => call);
        if (target.message.content === "") target.message.content = null;
      }
      if (choice.finish_reason) target.finish_reason = choice.finish_reason;
      if (chunk.usage) result.usage = chunk.usage;
    },
    result: () => result,
  };
}

/** Create an isolated engine bridge. catalog() and load() return promises. */
export function createBridge({
  moduleUrl = DEFAULT_MODULE_URL,
  workerUrl = new URL("./web_llm_worker.js", import.meta.url),
  appConfig,
  models = [],
  engineFactory,
  contextWindow = 16384,
  onProgress = () => {},
  onReady = () => {},
  onError = () => {},
} = {}) {
  let current;
  let engineModule;
  let loading = Promise.resolve();
  const active = new Map();
  const getModule = () => (engineModule ??= import(moduleUrl));
  const configFor = (webllm) => {
    const config = appConfig ?? webllm.prebuiltAppConfig;
    return { ...config, model_list: [...(config.model_list ?? []), ...models] };
  };

  async function catalog() {
    const config = appConfig ? configFor(null) : configFor(await getModule());
    return {
      webgpu: webgpuAvailable(),
      models: config.model_list.map((record) => ({
        ...record,
        id: record.model_id,
        vram_mb: Math.round(record.vram_required_MB ?? 0),
        context_window: contextWindow,
      })),
    };
  }

  // Loads `model` unless it is already current. Requests load their model on
  // demand, so callers only need `load` to warm a model up front.
  function load(model, listener = onProgress) {
    const next = loading.then(async () => {
      if (current?.model === model) return true;
      const progress = (report) => listener({
        ...report,
        progress: Math.max(0, Math.min(1, Number(report.progress ?? 0))),
        text: String(report.text ?? ""),
      });
      const factory = engineFactory ?? globalThis.webLLMEngineFactory;
      let engine;
      let worker;
      try {
        if (factory) {
          engine = await factory(model, progress);
        } else {
          if (!webgpuAvailable()) throw new Error("WebGPU is not available in this browser.");
          const webllm = await getModule();
          const url = new URL(workerUrl, import.meta.url);
          url.searchParams.set("module", String(moduleUrl));
          worker = new Worker(url, { type: "module" });
          engine = await webllm.CreateWebWorkerMLCEngine(
            worker,
            model,
            { initProgressCallback: progress, appConfig: configFor(webllm) },
            { context_window_size: contextWindow },
          );
        }
        await current?.engine.unload?.();
        current?.worker?.terminate();
        current = { model, engine, worker };
        onReady(model);
        return true;
      } catch (error) {
        worker?.terminate();
        onError(error);
        throw error;
      }
    });
    loading = next.catch(() => {});
    return next;
  }

  function cancel(id) {
    const state = active.get(id);
    if (!state || state.cancelled) return;
    state.cancelled = true;
    state.engine?.interruptGenerate?.();
  }

  async function request(payload, emit, signal) {
    const state = { cancelled: false, engine: current?.engine };
    active.set(payload.id, state);
    const abort = () => cancel(payload.id);
    const send = (event) => {
      if (!state.cancelled) emit({ id: payload.id, ...event });
    };
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
    try {
      if (state.cancelled) return;
      const body = JSON.parse(payload.body);
      if (typeof body.model === "string" && body.model !== "") await load(body.model);
      if (!current) throw new Error("No local model is loaded.");
      if (state.cancelled) return;
      const { engine, model } = current;
      state.engine = engine;
      const chunks = await engine.chat.completions.create(localRequest(body));
      if (state.cancelled) return;
      const streaming = body.stream === true;
      send({ type: "status", status: 200 });
      send({ type: "headers", headers: [["content-type", streaming ? "text/event-stream" : "application/json"]] });
      const collector = streaming ? null : completionCollector();
      await relay(chunks, body.model ?? model, (chunk) => {
        if (streaming) send({ type: "data", data: `data: ${JSON.stringify(chunk)}\n\n` });
        else collector.emit(chunk);
      }, () => state.cancelled);
      if (streaming) send({ type: "data", data: "data: [DONE]\n\n" });
      else if (!state.cancelled) send({ type: "data", data: JSON.stringify(collector.result()) });
      send({ type: "done" });
    } catch (error) {
      send({ type: "error", message: String(error?.message ?? error) });
    } finally {
      signal?.removeEventListener("abort", abort);
      if (active.get(payload.id) === state) active.delete(payload.id);
    }
  }

  // Popcorn uses this explicitly; normal page fetch traffic remains untouched.
  function installFetchShim(origin = "https://web-llm.invalid") {
    const localOrigin = new URL(origin).origin;
    const previous = globalThis.fetch;
    const networkFetch = previous.bind(globalThis);
    const shim = async (input, init) => {
      const url = new URL(
        typeof input === "string" || input instanceof URL ? input : input.url,
        globalThis.location?.href ?? localOrigin,
      );
      if (url.origin !== localOrigin || !/^\/(?:clients\/[^/]+\/)?v1\/chat\/completions\/?$/.test(url.pathname)) {
        return networkFetch(input, init);
      }
      const incoming = new Request(input, init);
      const id = uniqueId();
      const payload = {
        id,
        method: incoming.method,
        url: incoming.url,
        headers: Object.fromEntries(incoming.headers),
        body: await incoming.text(),
      };
      if (incoming.signal.aborted) throw incoming.signal.reason ?? new DOMException("Aborted", "AbortError");
      return new Promise((resolve, reject) => {
        const encoder = new TextEncoder();
        let controller;
        let status = 200;
        let resolved = false;
        let finished = false;
        const stream = new ReadableStream({
          start(value) { controller = value; },
          cancel() {
            finished = true;
            incoming.signal.removeEventListener("abort", abort);
            cancel(id);
          },
        });
        const fail = (error) => {
          if (finished) return;
          finished = true;
          incoming.signal.removeEventListener("abort", abort);
          controller.error(error);
          if (!resolved) reject(error);
        };
        const abort = () => {
          cancel(id);
          fail(incoming.signal.reason ?? new DOMException("Aborted", "AbortError"));
        };
        incoming.signal.addEventListener("abort", abort, { once: true });
        request(payload, (event) => {
          if (finished) return;
          if (event.type === "status") status = event.status;
          else if (event.type === "headers") {
            resolved = true;
            resolve(new Response(stream, { status, headers: event.headers }));
          } else if (event.type === "data") controller.enqueue(encoder.encode(event.data));
          else if (event.type === "done") {
            finished = true;
            incoming.signal.removeEventListener("abort", abort);
            controller.close();
          } else if (event.type === "error") fail(new Error(event.message));
        }, incoming.signal).catch(fail);
      });
    };
    globalThis.webLLMFetch = shim;
    return shim;
  }

  return { catalog, load, request, cancel, installFetchShim };
}

function jsonSafe(value) {
  if (value == null) return null;
  try {
    const encoded = JSON.stringify(value, (_key, item) => {
      if (typeof item === "bigint") return String(item);
      if (typeof globalThis.Node === "function" && item instanceof globalThis.Node) {
        return item.outerHTML ?? item.textContent ?? String(item);
      }
      return item;
    });
    return encoded === undefined ? null : JSON.parse(encoded);
  } catch (_error) {
    return String(value);
  }
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

// A cell that is a single expression returns its value, as in a console;
// anything else runs as the body of an async function and returns what it
// returns. Trailing semicolons do not turn an expression into a statement.
export function compileCell(source) {
  const expression = String(source).trim().replace(/;+$/, "");
  try {
    return new AsyncFunction(`return (${expression}\n);`);
  } catch (_error) {
    return new AsyncFunction(source);
  }
}

/** Build a Phoenix LiveView hook; eval is disabled unless data-allow-eval=true. */
export function createWebLLMHook(options = {}) {
  return {
    mounted() {
      this.webLLMRequests = new Map();
      this.webLLMDestroyed = false;
      this.webLLMClient = this.el.dataset.client ?? "";
      this.webLLMModel = this.el.dataset.model ?? "";
      this.webLLMAllowEval = this.el.dataset.allowEval === "true";
      const push = (event, payload) => {
        if (!this.webLLMDestroyed) this.pushEventTo(this.el, event, payload);
      };
      const status = (state, progress = 0, text = "") => push("web_llm:status", {
        webgpu: webgpuAvailable(), state, model: this.webLLMModel, progress, text,
      });
      // Requests load their model on demand; these callbacks report every load.
      this.webLLMBridge = createBridge({
        ...options,
        onProgress: (report) => status("loading", report.progress, report.text),
        onReady: (model) => {
          this.webLLMModel = model;
          status("ready", 1, "Model ready");
        },
        onError: (error) => status("error", 0, String(error?.message ?? error)),
      });
      const load = async (model) => {
        this.webLLMModel = model;
        status("loading", 0, "Loading model");
        await this.webLLMBridge.load(model).catch(() => {});
      };
      const handle = (event, callback) => this.handleEvent(event, (payload) => {
        if (!this.webLLMDestroyed && payload.target === this.el.id) return callback(payload);
      });
      handle("web_llm:request", async ({ request }) => {
        const controller = new AbortController();
        this.webLLMRequests.set(request.id, controller);
        try {
          await this.webLLMBridge.request(request, (event) => push("web_llm:event", event), controller.signal);
        } finally {
          this.webLLMRequests.delete(request.id);
        }
      });
      handle("web_llm:cancel", ({ id }) => {
        this.webLLMRequests.get(id)?.abort();
        this.webLLMBridge.cancel(id);
      });
      handle("web_llm:load", ({ model }) => load(model));
      handle("web_llm:eval", async ({ id, source }) => {
        try {
          if (!this.webLLMAllowEval) throw new Error("Page evaluation is disabled.");
          const value = await compileCell(source)();
          push("web_llm:eval_result", { id, ok: true, value: jsonSafe(value), error: "" });
        } catch (error) {
          push("web_llm:eval_result", { id, ok: false, value: null, error: String(error?.stack ?? error) });
        }
      });
      status("idle", 0, webgpuAvailable() ? "WebGPU available" : "WebGPU is not available in this browser.");
      if (this.el.dataset.preload === "true" && this.webLLMModel) load(this.webLLMModel);
    },
    destroyed() {
      this.webLLMDestroyed = true;
      for (const controller of this.webLLMRequests?.values() ?? []) controller.abort();
      this.webLLMRequests?.clear();
    },
  };
}

export const WebLLMHook = createWebLLMHook({});
