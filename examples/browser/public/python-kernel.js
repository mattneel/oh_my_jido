// One Pyodide interpreter per Python Eval kernel, in its own Web Worker.
// Globals persist across cells in one namespace dictionary. `await tool(name,
// parameters)` calls an Oh-My-Jido tool that the session has granted.

import { loadPyodide } from "./pyodide/pyodide.mjs";

const toolReplies = new Map();
let nextRequest = 0;
let runCell;
let namespace;

function post(message) {
  self.postMessage(message);
}

function callTool(name, parametersJson) {
  const request = nextRequest++;
  const reply = Promise.withResolvers();
  toolReplies.set(request, reply);
  post({ type: "tool", request, name, parameters: parametersJson });
  return reply.promise.then((value) => JSON.stringify(value));
}

async function start() {
  const pyodide = await loadPyodide({
    indexURL: new URL("./pyodide/", import.meta.url).href,
    stdout: (text) => post({ type: "output", stream: "stdout", text: `${text}\n` }),
    stderr: (text) => post({ type: "output", stream: "stderr", text: `${text}\n` }),
  });

  pyodide.registerJsModule("_oh_my_jido_bridge", {
    call_tool: callTool,
    display: (text) => post({ type: "display", text }),
  });

  runCell = pyodide.runPython(`
import json
from pyodide.code import eval_code_async
import _oh_my_jido_bridge as _bridge


async def tool(name, parameters=None):
    reply = json.loads(await _bridge.call_tool(name, json.dumps(parameters or {})))
    if not reply.get("ok"):
        raise RuntimeError(reply.get("error"))
    return reply.get("result")


def display(value):
    _bridge.display(value if isinstance(value, str) else repr(value))


async def _run_cell(source, namespace):
    value = await eval_code_async(source, namespace)
    return None if value is None else repr(value)


_run_cell
`);

  namespace = pyodide.globals.get("dict")();
  namespace.set("tool", pyodide.globals.get("tool"));
  namespace.set("display", pyodide.globals.get("display"));
}

const started = start().then(
  () => post({ type: "ready" }),
  (error) => post({ type: "failed", error: String(error?.stack ?? error) }),
);

self.onmessage = async (event) => {
  const message = event.data;

  if (message.type === "tool") {
    const reply = toolReplies.get(message.request);
    toolReplies.delete(message.request);
    reply?.resolve(message.reply);
    return;
  }

  if (message.type === "run") {
    await started;
    try {
      const display = await runCell(message.source, namespace);
      post({ type: "result", status: "ok", display: display ?? "" });
    } catch (error) {
      post({ type: "result", status: "error", error: String(error?.message ?? error) });
    }
  }
};
