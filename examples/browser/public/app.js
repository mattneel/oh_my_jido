import { Popcorn } from "./out/index.mjs";
import * as evalKernels from "./eval.js";
import { createBridge } from "./vendor/web_llm/web_llm.js";
import * as secrets from "./secrets.js";

const localModelIds = [
  "Qwen3-4B-q4f16_1-MLC",
  "Qwen3-1.7B-q4f16_1-MLC",
  "Qwen3-8B-q4f16_1-MLC",
  "Hermes-3-Llama-3.1-8B-q4f16_1-MLC",
  "Qwen2.5-7B-Instruct-q4f16_1-MLC",
  "Llama-3.1-8B-Instruct-q4f16_1-MLC",
];

// Optional self-hosted models (for example a custom MLC build): models/models.json
// lists WebLLM model records whose "model" and "model_lib" are relative to it.
const manifest = new URL("./models/models.json", location.href);
const selfHosted = await fetch(manifest)
  .then((response) => (response.ok ? response.json() : []))
  .catch(() => []);
const extraModels = selfHosted.map((record) => ({
  ...record,
  model: new URL(record.model, manifest).href,
  model_lib: new URL(record.model_lib, manifest).href,
}));
localModelIds.push(...extraModels.map((record) => record.model_id));

const bridge = createBridge({
  moduleUrl: new URL("./vendor/web-llm/index.js", location.href),
  workerUrl: new URL("./vendor/web_llm/web_llm_worker.js", location.href),
  models: extraModels,
});
bridge.installFetchShim();

window.ohMyJidoSecrets = secrets;
window.ohMyJidoEval = evalKernels;
window.ohMyJidoLocalModels = {
  async catalog() {
    const { webgpu, models } = await bridge.catalog();
    const known = new Map(models.map((record) => [record.id, record]));
    return {
      webgpu,
      models: localModelIds.filter((id) => known.has(id)).map((id) => ({
        id,
        vram_mb: known.get(id).vram_mb,
      })),
    };
  },
  load({ model, listener }, { send }) {
    return bridge.load(model, (report) =>
      send(listener, ["progress", report.progress, report.text]),
    );
  },
};
window.popcorn = await Popcorn.init();
