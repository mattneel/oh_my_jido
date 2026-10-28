// Eval kernels for Oh-My-Jido in the browser.
//
// JavaScript cells run in this page through `new Function`, against a
// persistent per-kernel scope. Python cells run in Pyodide inside a dedicated
// Web Worker per kernel, which can be terminated. Both report output, display
// values and host tool calls to the Elixir kernel worker (`worker`, a PID).

const jsKernels = new Map();
const pythonKernels = new Map();
const TOOL_TIMEOUT_MS = 120_000;

function show(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  if (typeof Node !== "undefined" && value instanceof Node) {
    return value.outerHTML ?? value.textContent ?? String(value);
  }
  try {
    const json = JSON.stringify(value, null, 2);
    if (json !== undefined) return json;
  } catch (_error) {
    // Fall through to String() for cyclic or exotic values.
  }
  return String(value);
}

function describe(error) {
  if (error && typeof error === "object" && "stack" in error && error.stack) {
    return String(error.stack);
  }
  return String(error);
}

// --- JavaScript --------------------------------------------------------------

// Declarations at column 0 become assignments to the kernel scope so later
// cells can use them. Indented (nested) declarations stay local.
const NAME = "[A-Za-z_$][\\w$]*";
const HOISTS = [
  [new RegExp(`^(?:let|const|var)\\s+(?=${NAME}\\s*(?:[=;,]|$))`, "gm"), ""],
  [new RegExp(`^(async\\s+)?function(\\s*\\*)?\\s+(${NAME})`, "gm"), "$3 = $1function$2 $3"],
  [new RegExp(`^class\\s+(${NAME})`, "gm"), "$1 = class $1"],
];

const hoist = (source) =>
  HOISTS.reduce((code, [pattern, replacement]) => code.replace(pattern, replacement), source);

function compile(source) {
  try {
    return new Function("__scope", `with (__scope) { return (async () => (\n${source}\n))(); }`);
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
  }
  return new Function("__scope", `with (__scope) { return (async () => {\n${hoist(source)}\n})(); }`);
}

// Every free name resolves through the kernel scope: reads fall back to the
// page's globals, writes stay in the scope. Global functions without a
// prototype (fetch, setTimeout, ...) are bound to the window.
function scopeProxy(scope, extras) {
  return new Proxy(scope, {
    has: (_target, key) => key !== Symbol.unscopables,
    get(target, key) {
      if (key === Symbol.unscopables) return undefined;
      if (key in extras) return extras[key];
      if (key in target) return target[key];
      const value = globalThis[key];
      return typeof value === "function" && !("prototype" in value)
        ? value.bind(globalThis)
        : value;
    },
    set(target, key, value) {
      target[key] = value;
      return true;
    },
    deleteProperty(target, key) {
      return delete target[key];
    },
  });
}

function hostApi(worker, { send, call }, pending) {
  const emit = (stream, values) => {
    const text = values.map((value) => (typeof value === "string" ? value : show(value))).join(" ");
    pending.push(send(worker, ["output", stream, `${text}\n`]));
  };

  return {
    console: {
      log: (...values) => emit("stdout", values),
      info: (...values) => emit("stdout", values),
      debug: (...values) => emit("stdout", values),
      warn: (...values) => emit("stderr", values),
      error: (...values) => emit("stderr", values),
    },
    display: (value) => pending.push(send(worker, ["display", show(value)])),
    tool: async (name, parameters = {}) => {
      const reply = await call(worker, ["tool", name, parameters], { timeoutMs: TOOL_TIMEOUT_MS });
      if (!reply.ok) throw new Error(reply.error);
      return reply.result;
    },
  };
}

export function openJavaScript({ id }) {
  jsKernels.set(id, Object.create(null));
  return true;
}

export function closeJavaScript({ id }) {
  jsKernels.delete(id);
  return true;
}

export async function runJavaScript({ id, source, worker }, actions) {
  const scope = jsKernels.get(id);
  if (!scope) return { status: "error", error: "This JavaScript kernel is closed." };

  const pending = [];
  let result;

  try {
    const value = await compile(source)(scopeProxy(scope, hostApi(worker, actions, pending)));
    result = { status: "ok", display: show(value) };
  } catch (error) {
    result = { status: "error", error: describe(error) };
  }

  await Promise.allSettled(pending);
  return result;
}

// --- Python (Pyodide) ---------------------------------------------------------

function settle(kernel, message) {
  const run = kernel.run;
  kernel.run = null;
  Promise.allSettled(kernel.pending).then(() => run?.resolve(message));
  kernel.pending = [];
}

function onPythonMessage(kernel, message) {
  switch (message.type) {
    case "ready":
      kernel.ready.resolve(true);
      break;
    case "failed":
      kernel.ready.reject(new Error(message.error));
      break;
    case "output":
      kernel.pending.push(kernel.actions.send(kernel.worker, ["output", message.stream, message.text]));
      break;
    case "display":
      kernel.pending.push(kernel.actions.send(kernel.worker, ["display", message.text]));
      break;
    case "tool":
      kernel.actions
        .call(kernel.worker, ["tool", message.name, JSON.parse(message.parameters)], {
          timeoutMs: TOOL_TIMEOUT_MS,
        })
        .then(
          (reply) => kernel.thread.postMessage({ type: "tool", request: message.request, reply }),
          (error) =>
            kernel.thread.postMessage({
              type: "tool",
              request: message.request,
              reply: { ok: false, error: describe(error) },
            }),
        );
      break;
    case "result":
      settle(kernel, { status: message.status, display: message.display, error: message.error });
      break;
  }
}

export function openPython({ id, worker }, actions) {
  const thread = new Worker(new URL("./python-kernel.js", import.meta.url), { type: "module" });
  const kernel = { thread, worker, actions, run: null, pending: [], ready: Promise.withResolvers() };
  thread.onmessage = (event) => onPythonMessage(kernel, event.data);
  thread.onerror = (event) => {
    const error = event.message || "The Python worker failed to start.";
    kernel.ready.reject(new Error(error));
    settle(kernel, { status: "error", error });
  };
  pythonKernels.set(id, kernel);
  return kernel.ready.promise;
}

export function runPython({ id, source }) {
  const kernel = pythonKernels.get(id);
  if (!kernel) return { status: "error", error: "This Python kernel is closed." };
  if (kernel.run) return { status: "error", error: "This Python kernel is busy." };

  kernel.run = Promise.withResolvers();
  kernel.thread.postMessage({ type: "run", source });
  return kernel.run.promise;
}

export function closePython({ id }) {
  const kernel = pythonKernels.get(id);
  pythonKernels.delete(id);
  if (kernel) {
    kernel.thread.terminate();
    kernel.run?.resolve({ status: "error", error: "The Python kernel was stopped." });
  }
  return true;
}
