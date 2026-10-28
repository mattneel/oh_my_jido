import { mkdir, writeFile } from "node:fs/promises";
import { expect, test } from "@playwright/test";

const app = (page) => page.locator("#app");

async function ready(page) {
  await expect(app(page)).toHaveAttribute("data-state", "ready");
}

test("the agent changes its own page through JavaScript and Python Eval", async ({ page }) => {
  await page.goto("/");
  await ready(page);
  await expect(page.locator("#omj-status")).toContainText("scripted model");
  await page.evaluate(() => {
    window.sameDocument = true;
  });

  await page.fill("#omj-prompt", "Show the Python result in the title and make the accent orange");
  await page.click("#omj-send");

  const question = page.locator("[data-approval]");
  await expect(question).toContainText("Which accent color should the page use?");
  await question.locator("button[data-answer='Orange']").click();

  await ready(page);
  await expect(page.locator("#omj-title")).toHaveText("Popcorn Agent sum=285");
  const accent = await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue("--accent").trim(),
  );
  expect(accent).toBe("#f97316");
  expect(await page.evaluate(() => window.sameDocument)).toBe(true);
  await expect(page.locator("#omj-log .message.tool")).toHaveCount(5);
  await expect(page.locator("#omj-log .message.assistant")).toContainText(
    "The title now shows the Python result",
  );
});

test("a local WebLLM model drives tool calls through the in-page bridge", async ({ page }) => {
  await page.addInitScript(() => {
    window.localRequests = [];
    globalThis.webLLMEngineFactory = async (_model, progress) => {
      progress({ progress: 1, text: "test engine ready" });
      return {
        interruptGenerate() {},
        chat: {
          completions: {
            async create(options) {
              window.localRequests.push(options);
              const answered = options.messages.some((message) =>
                String(message.content).includes("<tool_response>"),
              );
              const call = JSON.stringify({
                name: "eval",
                arguments: {
                  language: "javascript",
                  source: "document.querySelector('#omj-title').textContent = 'Local Agent'; return 'done'",
                },
              });
              const pieces = answered
                ? ["The title now ", "says Local Agent."]
                : ["<tool_", `call>\n${call.slice(0, 20)}`, `${call.slice(20)}\n</tool_call>`];

              return (async function* () {
                for (const content of pieces) {
                  yield { choices: [{ index: 0, delta: { content }, finish_reason: null }] };
                }
                yield {
                  choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
                  usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 },
                };
              })();
            },
          },
        },
      };
    };
  });

  await page.goto("/");
  await ready(page);
  await page.selectOption("#omj-model", "local:Qwen3-4B-q4f16_1-MLC");
  await expect(page.locator("#omj-status")).toContainText("Qwen3-4B-q4f16_1-MLC on this GPU");
  await ready(page);

  await page.fill("#omj-prompt", "Rename the title to Local Agent");
  await page.click("#omj-send");
  await expect(app(page)).toHaveAttribute("data-state", "running");
  await ready(page);

  await expect(page.locator("#omj-title")).toHaveText("Local Agent");
  await expect(page.locator("#omj-log .message.assistant")).toHaveText(/says Local Agent\./);
  await expect(page.locator("#omj-status")).toContainText("last run 200 input / 40 output tokens");

  const requests = await page.evaluate(() =>
    window.localRequests.map((request) => ({
      roles: request.messages.map((message) => message.role),
      system: request.messages[0].content,
      last: request.messages.at(-1).content,
    })),
  );
  expect(requests).toHaveLength(2);
  expect(requests[0].roles).toEqual(["system", "user"]);
  const system = requests[0].system;
  expect(system).toContain("web_llm:Qwen3-4B-q4f16_1-MLC");
  for (const name of ["edit", "eval", "question", "read", "write"]) {
    expect(system).toContain(`"name":"${name}"`);
  }
  for (const name of ["shell", "search", "git", "list", "lsp", "browser"]) {
    expect(system).not.toContain(`"name":"${name}"`);
  }
  expect(requests[1].roles).toEqual(["system", "user", "assistant", "user"]);
  expect(requests[1].last).toContain("<tool_response>");
});

test("the OpenRouter key is stored encrypted, survives a reload and can be forgotten", async ({
  page,
}) => {
  // Not key-shaped on purpose: secret scanners must not mistake test data for a key.
  const key = "test-only-openrouter-placeholder-value";

  await page.goto("/");
  await ready(page);
  await page.selectOption("#omj-model", "openrouter");
  await expect(app(page)).toHaveAttribute("data-state", "needs-key");

  await page.fill("#omj-key", key);
  await page.click("#omj-key-form button[type='submit']");
  await ready(page);
  await expect(page.locator("#omj-key")).toHaveValue("");

  const stored = await page.evaluate(
    () =>
      new Promise((resolve, reject) => {
        const request = indexedDB.open("oh-my-jido");
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const read = request.result
            .transaction("secrets")
            .objectStore("secrets")
            .get("secret:openrouter-api-key");
          read.onsuccess = () =>
            resolve(new TextDecoder().decode(new Uint8Array(read.result.data)));
        };
      }),
  );
  expect(stored).not.toContain(key);
  expect(stored).not.toContain("placeholder");

  await page.reload();
  await ready(page);
  await page.selectOption("#omj-model", "openrouter");
  await ready(page);
  await expect(page.locator("#omj-forget")).toBeVisible();

  await page.click("#omj-forget");
  await expect(app(page)).toHaveAttribute("data-state", "needs-key");
});

test("the library's capability probes pass inside the browser VM", async ({ page }) => {
  test.setTimeout(900_000);
  await page.goto("/?probes");
  const probes = page.locator("#omj-probes[data-done='true']");
  await expect(probes).toBeAttached({ timeout: 840_000 });

  const results = JSON.parse(await probes.textContent());
  const report = new URL("../tmp/e2e/probes.json", import.meta.url);
  await mkdir(new URL(".", report), { recursive: true });
  await writeFile(report, JSON.stringify(results, null, 2));
  expect(Array.isArray(results)).toBe(true);
  const failed = results.filter((result) => result.status !== "passed");
  expect(failed, JSON.stringify(failed, null, 2)).toEqual([]);
  const ids = ["A03", "A05", "A06", "A07", "A08", "B02", "B09", "B10", "C07", "C11", "C13"]
    .concat(["D01", "D02", "D04", "D05", "D06", "D07", "D08", "D14", "E05", "E06", "F03", "L1"])
    .sort();
  expect(results.map((result) => result.id).sort()).toEqual(ids);
});
