// The page selects the engine module so self-hosted WebLLM builds work too.
const moduleUrl = new URL(self.location.href).searchParams.get("module")
  ?? "https://esm.run/@mlc-ai/web-llm@0.2.86";
const pending = [];
self.onmessage = (message) => pending.push(message);
const { WebWorkerMLCEngineHandler } = await import(moduleUrl);
const handler = new WebWorkerMLCEngineHandler();
self.onmessage = (message) => handler.onmessage(message);
for (const message of pending) handler.onmessage(message);
pending.length = 0;
