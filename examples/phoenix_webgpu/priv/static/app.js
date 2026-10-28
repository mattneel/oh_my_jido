import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { createWebLLMHook } from "web_llm";

const moduleUrl = document.querySelector('meta[name="web-llm-module-url"]').content;
const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { WebLLM: createWebLLMHook({ moduleUrl }) },
});

liveSocket.connect();
