(() => {
  "use strict";
  const call = Beam.callSync.bind(Beam);
  const render = value => {
    if (typeof value === "string") return value;
    try { return JSON.stringify(value) ?? String(value); }
    catch (_) { return String(value); }
  };
  const invoke = (operation, ...args) => {
    const cell = globalThis.__omj_cell;
    if (!cell) throw new Error("stale_execution");
    const result = call("omj_eval", cell.generation, cell.id, operation, ...args);
    if (result && result.ok === false) throw new Error(result.error);
    return result && result.ok === true ? result.result : result;
  };
  const tools = Object.freeze({
    call(name, parameters = {}) {
      if (typeof name !== "string" || !parameters || Array.isArray(parameters) || typeof parameters !== "object") {
        throw new TypeError("tools.call requires a tool name and structured parameters");
      }
      return invoke("tool", name, parameters);
    }
  });
  const console = Object.freeze(Object.fromEntries(
    ["log", "info", "warn", "error", "debug"].map(level => [level, (...values) => {
      invoke("output", level === "error" || level === "warn" ? "stderr" : "stdout", values.map(render).join(" ") + "\n");
    }])
  ));
  for (const [name, value] of Object.entries({
    tools, console,
    display: value => invoke("display", render(value)),
    artifact: (name, mediaType, data) => invoke("artifact", name, mediaType, data),
    Beam: undefined
  })) {
    Object.defineProperty(globalThis, name, {value, writable: false, configurable: false});
  }
})();
