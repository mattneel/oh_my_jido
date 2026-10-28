import assert from "node:assert/strict";
import test from "node:test";
import { compileCell, createBridge, createWebLLMHook, WebLLMHook } from "../../priv/static/web_llm.js";

const MODEL = "fake-model";
const USAGE = { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 };
const tools = [{ type: "function", function: { name: "eval", parameters: { type: "object" } } }];

function payload(body = {}, id = "request-1") {
  return {
    id,
    method: "POST",
    url: "https://web-llm.invalid/v1/chat/completions",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: MODEL, messages: [{ role: "user", content: "Hello" }], stream: true, ...body }),
  };
}

function stream(pieces, usage = USAGE) {
  return (async function* () {
    for (const content of pieces) {
      yield { choices: [{ index: 0, delta: { content }, finish_reason: null }] };
    }
    yield { choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage };
  })();
}

async function fakeBridge(respond) {
  const requests = [];
  let interrupts = 0;
  const bridge = createBridge({
    engineFactory: async (_model, progress) => {
      progress({ progress: 1, text: "test engine ready" });
      return {
        interruptGenerate() { interrupts += 1; },
        chat: { completions: { async create(options) {
          requests.push(options);
          return respond(options);
        } } },
      };
    },
  });
  await bridge.load(MODEL);
  return { bridge, requests, interrupts: () => interrupts };
}

async function eventsFor(bridge, body = {}) {
  const events = [];
  await bridge.request(payload(body), (event) => events.push(event));
  assert.deepEqual(events[0], { id: "request-1", type: "status", status: 200 });
  assert.equal(events[1].type, "headers");
  assert.equal(events.at(-1).type, "done");
  return events;
}

function chunksFor(events) {
  return events.filter((event) => event.type === "data")
    .map((event) => event.data)
    .join("")
    .split("\n\n")
    .filter(Boolean)
    .map((frame) => {
      assert.ok(frame.startsWith("data: "));
      const data = frame.slice(6);
      return data === "[DONE]" ? data : JSON.parse(data);
    });
}

function contentFor(chunks) {
  return chunks.filter((chunk) => chunk !== "[DONE]")
    .map((chunk) => chunk.choices[0].delta.content ?? "")
    .join("");
}

test("an eval cell returns a lone expression's value, otherwise runs as a function body", async () => {
  globalThis.cellTarget = { text: "before" };
  assert.equal(await compileCell("globalThis.cellTarget.text = 'after';")(), "after");
  assert.equal(await compileCell("[1, 2, 3].map((n) => n * 2).join(', ')")(), "2, 4, 6");
  assert.equal(await compileCell("const n = 2;\nreturn n + 1;")(), 3);
  assert.equal(await compileCell("await Promise.resolve(5)")(), 5);
  assert.equal(await compileCell("globalThis.cellTarget.text = 'x'; globalThis.cellTarget.text += 'y'")(), undefined);
  assert.equal(globalThis.cellTarget.text, "xy");
  delete globalThis.cellTarget;
});

test("a request loads its model on demand and reports the load", async () => {
  const loads = [];
  const lifecycle = [];
  const bridge = createBridge({
    engineFactory: async (model, progress) => {
      loads.push(model);
      progress({ progress: 0.5, text: "half" });
      return { chat: { completions: { create: async () => stream(["ok"]) } } };
    },
    onProgress: (report) => lifecycle.push(["progress", report.progress, report.text]),
    onReady: (model) => lifecycle.push(["ready", model]),
  });

  assert.equal(contentFor(chunksFor(await eventsFor(bridge))), "ok");
  await eventsFor(bridge);
  assert.deepEqual(loads, [MODEL]);
  assert.deepEqual(lifecycle, [["progress", 0.5, "half"], ["ready", MODEL]]);
});

test("split tool protocol becomes OpenAI tool_calls deltas, usage and DONE", async () => {
  const call = JSON.stringify({ name: "eval", arguments: { source: "return 42" } });
  const { bridge, requests } = await fakeBridge(() => stream([
    "<tool_", `call>\n${call.slice(0, 20)}`, `${call.slice(20)}\n</tool_call>`,
  ]));
  const events = await eventsFor(bridge, { tools, max_completion_tokens: 256, temperature: 0.2 });
  assert.deepEqual(events[1].headers, [["content-type", "text/event-stream"]]);
  const chunks = chunksFor(events);
  assert.equal(chunks.at(-1), "[DONE]");
  assert.equal(chunks[0].choices[0].delta.role, "assistant");
  const calls = chunks.find((chunk) => chunk.choices?.[0].delta.tool_calls)?.choices[0].delta.tool_calls;
  assert.equal(calls.length, 1);
  assert.equal(calls[0].index, 0);
  assert.match(calls[0].id, /^call_/);
  assert.equal(calls[0].type, "function");
  assert.equal(calls[0].function.name, "eval");
  assert.deepEqual(JSON.parse(calls[0].function.arguments), { source: "return 42" });
  assert.equal(chunks.at(-2).choices[0].finish_reason, "tool_calls");
  assert.deepEqual(chunks.at(-2).usage, USAGE);
  assert.equal(contentFor(chunks), "");
  assert.equal(requests[0].stream, true);
  assert.deepEqual(requests[0].stream_options, { include_usage: true });
  assert.deepEqual(requests[0].extra_body, { enable_thinking: true });
  assert.equal(requests[0].max_tokens, 256);
  assert.equal(requests[0].temperature, 0.2);
  assert.equal(requests[0].tools, undefined);
  assert.match(requests[0].messages[0].content, /Never describe an action/);
});

test("thinking streams as reasoning_content, never as answer text, across split tags", async () => {
  const { bridge } = await fakeBridge(() => stream(["<think>\nweigh", " the options</th", "ink>\nDone."]));
  const chunks = chunksFor(await eventsFor(bridge)).filter((chunk) => chunk !== "[DONE]");
  const reasoning = chunks.map((chunk) => chunk.choices[0].delta.reasoning_content ?? "").join("");

  assert.equal(reasoning, "\nweigh the options");
  assert.equal(contentFor(chunks), "Done.");
  assert.ok(chunks.every((chunk) => !(chunk.choices[0].delta.reasoning_content ?? "").includes("<")));

  const { bridge: plain } = await fakeBridge(() => stream(["<think>\nweigh", " the options</think>\nDone."]));
  const events = [];
  await plain.request(payload({ stream: false }), (event) => events.push(event));
  const message = JSON.parse(events.find((event) => event.type === "data").data).choices[0].message;
  assert.deepEqual([message.reasoning_content, message.content], ["\nweigh the options", "Done."]);
});

test("plain content is emitted incrementally and thinking stays hidden across token boundaries", async () => {
  const { bridge } = await fakeBridge(() => stream(["<thi", "nk>private deliberation", "</thi", "nk>\nHello", " world"]));
  const chunks = chunksFor(await eventsFor(bridge));
  assert.equal(contentFor(chunks), "Hello world");
  assert.deepEqual(chunks.filter((chunk) => chunk.choices?.[0].delta.content)
    .map((chunk) => chunk.choices[0].delta.content), ["Hello", " world"]);
  assert.equal(chunks.at(-2).choices[0].finish_reason, "stop");
  assert.deepEqual(chunks.at(-2).usage, USAGE);
  assert.equal(chunks.at(-1), "[DONE]");
});

test("thinking followed by a split tool call is not leaked as text", async () => {
  const { bridge } = await fakeBridge(() => stream([
    "<", "think>private</think>\n<tool_", 'call>{"name":"eval","arguments":{}}</tool_call>',
  ]));
  const chunks = chunksFor(await eventsFor(bridge));
  assert.equal(contentFor(chunks), "");
  assert.equal(chunks.at(-2).choices[0].finish_reason, "tool_calls");
});

test("an unclosed thinking block is never returned", async () => {
  const { bridge } = await fakeBridge(() => stream(["<think>still thinking"]));
  assert.equal(contentFor(chunksFor(await eventsFor(bridge))), "");
});

test("a tool round trip normalizes system, assistant and tool response turns", async () => {
  const { bridge, requests } = await fakeBridge((options) => stream([
    options.messages.at(-1).content.includes("<tool_response>") ? "The answer is 42." : '<tool_call>{"name":"eval","arguments":{}}</tool_call>',
  ]));
  const first = chunksFor(await eventsFor(bridge, { tools }));
  const calls = first.find((chunk) => chunk.choices?.[0].delta.tool_calls).choices[0].delta.tool_calls;
  const second = chunksFor(await eventsFor(bridge, {
    tools,
    messages: [
      { role: "system", content: "Be helpful" },
      { role: "user", content: [{ type: "text", text: "Calculate" }] },
      { role: "developer", content: "Use tools" },
      { role: "assistant", content: null, tool_calls: calls },
      { role: "tool", tool_call_id: calls[0].id, content: "42" },
    ],
  }));
  assert.equal(contentFor(second), "The answer is 42.");
  const messages = requests[1].messages;
  assert.deepEqual(messages.map((message) => message.role), ["system", "user", "assistant", "user"]);
  assert.match(messages[0].content, /^Be helpful\n\nUse tools/);
  assert.match(messages[0].content, /"name":"eval"/);
  assert.equal(messages[1].content, "Calculate");
  assert.equal(typeof messages[2].content, "string");
  assert.match(messages[2].content, /<tool_call>\n\{"name":"eval","arguments":\{\}\}\n<\/tool_call>/);
  assert.equal(messages.at(-1).content, "<tool_response>\n42\n</tool_response>");
});

test("adjacent turns merge and an assistant-final request gets a final user turn", async () => {
  const { bridge, requests } = await fakeBridge(() => stream(["Hello"]));
  await eventsFor(bridge, { messages: [
    { role: "user", content: "one" },
    { role: "user", content: "two" },
    { role: "assistant", content: ["partial", { text: " response" }] },
  ] });
  assert.deepEqual(requests[0].messages, [
    { role: "user", content: "one\n\ntwo" },
    { role: "assistant", content: "partial response" },
    { role: "user", content: "" },
  ]);
});

test("non-streaming requests return a JSON chat completion using the same tool protocol", async () => {
  const { bridge } = await fakeBridge(() => stream(['<tool_call>{"name":"eval","arguments":{"x":1}}</tool_call>']));
  const events = await eventsFor(bridge, { stream: false });
  assert.deepEqual(events[1].headers, [["content-type", "application/json"]]);
  const data = events.filter((event) => event.type === "data");
  assert.equal(data.length, 1);
  const completion = JSON.parse(data[0].data);
  assert.equal(completion.object, "chat.completion");
  assert.equal(completion.choices[0].finish_reason, "tool_calls");
  assert.equal(completion.choices[0].message.content, null);
  assert.equal(completion.choices[0].message.tool_calls[0].function.arguments, '{"x":1}');
  assert.equal("index" in completion.choices[0].message.tool_calls[0], false);
  assert.deepEqual(completion.usage, USAGE);
});

test("cancel interrupts generation and suppresses every later event", async () => {
  let release;
  let reached;
  const blocked = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { reached = resolve; });
  const { bridge, interrupts } = await fakeBridge(() => (async function* () {
    yield { choices: [{ delta: { content: "first" } }] };
    reached();
    await blocked;
    yield { choices: [{ delta: { content: "after cancellation" } }] };
  })());
  const events = [];
  const running = bridge.request(payload(), (event) => events.push(event));
  await started;
  bridge.cancel("request-1");
  const before = events.length;
  release();
  await running;
  assert.equal(interrupts(), 1);
  assert.equal(events.length, before);
  assert.equal(events.some((event) => event.type === "done"), false);
  assert.ok(!JSON.stringify(events).includes("after cancellation"));
});

test("an already-aborted signal does not start generation or emit events", async () => {
  const { bridge, requests } = await fakeBridge(() => stream(["never"]));
  const controller = new AbortController();
  controller.abort();
  const events = [];
  await bridge.request(payload(), (event) => events.push(event), controller.signal);
  assert.deepEqual(events, []);
  assert.deepEqual(requests, []);
});

test("generation failures produce a terminal wire error", async () => {
  const { bridge } = await fakeBridge(() => { throw new Error("generation failed"); });
  const events = [];
  await bridge.request(payload(), (event) => events.push(event));
  assert.deepEqual(events, [{ id: "request-1", type: "error", message: "generation failed" }]);
});

test("the fetch shim serves SSE for client-qualified and unqualified URLs", async (t) => {
  const { bridge } = await fakeBridge(() => stream(["via fetch"]));
  const previous = globalThis.fetch;
  const previousShim = globalThis.webLLMFetch;
  t.after(() => { globalThis.webLLMFetch = previousShim; });
  const localFetch = bridge.installFetchShim("https://web-llm.invalid");
  assert.equal(globalThis.webLLMFetch, localFetch);
  assert.equal(globalThis.fetch, previous);
  for (const path of ["/clients/browser-1/v1/chat/completions", "/v1/chat/completions"]) {
    const response = await localFetch(`https://web-llm.invalid${path}`, {
      method: "POST", headers: { "content-type": "application/json" }, body: payload().body,
    });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "text/event-stream");
    const text = await response.text();
    assert.match(text, /"content":"via fetch"/);
    assert.ok(text.endsWith("data: [DONE]\n\n"));
  }
  assert.equal(globalThis.fetch, previous);
});

test("the fetch shim also accepts Request inputs and JSON completions", async (t) => {
  const { bridge } = await fakeBridge(() => stream(["JSON reply"]));
  const previousShim = globalThis.webLLMFetch;
  t.after(() => { globalThis.webLLMFetch = previousShim; });
  const localFetch = bridge.installFetchShim();
  const request = new Request("https://web-llm.invalid/clients/browser-1/v1/chat/completions", {
    method: "POST", body: payload({ stream: false }).body,
  });
  const response = await localFetch(request);
  assert.equal(response.headers.get("content-type"), "application/json");
  assert.equal((await response.json()).choices[0].message.content, "JSON reply");
});

test("catalog includes configured and extra model records with VRAM and context", async () => {
  const bridge = createBridge({
    contextWindow: 8192,
    appConfig: { model_list: [{ model_id: "prebuilt", vram_required_MB: 1234.6 }] },
    models: [{ model_id: "self-hosted", vram_required_MB: 2000, model: "/model" }],
  });
  const catalog = await bridge.catalog();
  assert.equal(typeof catalog.webgpu, "boolean");
  assert.deepEqual(catalog.models.map(({ id, vram_mb, context_window }) => ({ id, vram_mb, context_window })), [
    { id: "prebuilt", vram_mb: 1235, context_window: 8192 },
    { id: "self-hosted", vram_mb: 2000, context_window: 8192 },
  ]);
  assert.equal(catalog.models[1].model, "/model");
});

function hookHarness(options = {}, dataset = {}) {
  const hook = createWebLLMHook(options);
  const handlers = new Map();
  const sent = [];
  const instance = {
    ...hook,
    el: { id: "gpu-client", dataset: { client: "browser-1", model: MODEL, ...dataset } },
    handleEvent(event, callback) { handlers.set(event, callback); },
    pushEventTo(element, event, payload) {
      assert.equal(element, this.el);
      sent.push({ event, payload });
    },
  };
  instance.mounted();
  return { instance, sent, handlers };
}

test("the LiveView hook targets its element and gates async page evaluation", async () => {
  assert.equal(typeof WebLLMHook.mounted, "function");
  const { instance, sent, handlers } = hookHarness({}, { allowEval: "true" });
  assert.equal(instance.webLLMClient, "browser-1");
  assert.equal(sent[0].event, "web_llm:status");
  assert.equal(sent[0].payload.state, "idle");
  await handlers.get("web_llm:eval")({ target: "another-client", id: "ignored", source: "throw Error('wrong target')" });
  assert.equal(sent.length, 1);
  await handlers.get("web_llm:eval")({ target: instance.el.id, id: "eval-1", source: "return {answer: await Promise.resolve(42), big: 1n}" });
  assert.deepEqual(sent.at(-1), {
    event: "web_llm:eval_result",
    payload: { id: "eval-1", ok: true, value: { answer: 42, big: "1" }, error: "" },
  });
  await handlers.get("web_llm:eval")({ target: instance.el.id, id: "eval-2", source: "throw new Error('bad cell')" });
  assert.equal(sent.at(-1).payload.ok, false);
  assert.match(sent.at(-1).payload.error, /bad cell/);
  instance.destroyed();
  const count = sent.length;
  await handlers.get("web_llm:eval")({ target: instance.el.id, id: "late", source: "return 1" });
  assert.equal(sent.length, count);
  const denied = hookHarness();
  await denied.handlers.get("web_llm:eval")({ target: denied.instance.el.id, id: "denied", source: "return 1" });
  assert.equal(denied.sent.at(-1).payload.ok, false);
  assert.match(denied.sent.at(-1).payload.error, /evaluation is disabled/);
});

test("the hook reports loading and readiness and relays request events", async () => {
  const { instance, sent, handlers } = hookHarness({ engineFactory: async (_model, progress) => {
    progress({ progress: 0.5, text: "Half loaded" });
    return { chat: { completions: { async create() { return stream(["hook reply"]); } } } };
  } });
  await handlers.get("web_llm:load")({ target: instance.el.id, model: MODEL });
  assert.ok(sent.some(({ event, payload }) => event === "web_llm:status" && payload.state === "loading" && payload.progress === 0.5));
  assert.equal(sent.at(-1).payload.state, "ready");
  await handlers.get("web_llm:request")({ target: instance.el.id, request: payload() });
  const events = sent.filter(({ event }) => event === "web_llm:event").map(({ payload }) => payload);
  assert.equal(events[0].type, "status");
  assert.equal(events.at(-1).type, "done");
  assert.equal(contentFor(chunksFor(events)), "hook reply");
  instance.destroyed();
});

test("destroying the hook aborts in-flight generation without sending late events", async () => {
  let release;
  let reached;
  let interrupted = false;
  const blocked = new Promise((resolve) => { release = resolve; });
  const started = new Promise((resolve) => { reached = resolve; });
  const { instance, sent, handlers } = hookHarness({ engineFactory: async () => ({
    interruptGenerate() { interrupted = true; },
    chat: { completions: { async create() {
      return (async function* () {
        reached();
        await blocked;
        yield { choices: [{ delta: { content: "too late" } }] };
      })();
    } } },
  }) });
  await handlers.get("web_llm:load")({ target: instance.el.id, model: MODEL });
  const running = handlers.get("web_llm:request")({ target: instance.el.id, request: payload() });
  await started;
  instance.destroyed();
  const count = sent.length;
  release();
  await running;
  assert.equal(interrupted, true);
  assert.equal(sent.length, count);
  assert.equal(instance.webLLMRequests.size, 0);
});

test("the installed fetch function delegates unrelated URLs to the captured network fetch", async (t) => {
  const network = globalThis.fetch;
  const previousShim = globalThis.webLLMFetch;
  const calls = [];
  globalThis.fetch = async (...args) => {
    calls.push(args);
    return new Response("network");
  };
  t.after(() => {
    globalThis.fetch = network;
    globalThis.webLLMFetch = previousShim;
  });
  const bridge = createBridge();
  const localFetch = bridge.installFetchShim();
  const options = { headers: { accept: "text/plain" } };
  assert.equal(await (await localFetch("https://example.invalid/file", options)).text(), "network");
  assert.equal(await (await localFetch("/relative-network-path")).text(), "network");
  assert.deepEqual(calls, [["https://example.invalid/file", options], ["/relative-network-path", undefined]]);
});
