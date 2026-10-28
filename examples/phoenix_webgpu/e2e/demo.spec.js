import { expect, test } from "@playwright/test";

async function installEngine(page) {
  await page.addInitScript(() => {
    window.browserRequests = [];
    globalThis.webLLMEngineFactory = async (model, progress) => {
      progress({ progress: 1, text: "Deterministic engine ready" });
      return {
        interruptGenerate() {},
        chat: {
          completions: {
            async create(options) {
              window.browserRequests.push({ model, options });
              const response = options.messages.find((message) =>
                String(message.content).includes("<tool_response>"),
              );
              const toolCall = JSON.stringify({
                name: "browser_eval",
                arguments: {
                  source:
                    'const heading = document.querySelector("#demo-heading"); ' +
                    'const before = heading.textContent; heading.textContent = "Browser GPU was here"; ' +
                    'return {before, after: heading.textContent};',
                },
              });
              const content = response
                ? "Browser GPU was here. Changed the heading in this document."
                : `<tool_call>${toolCall}</tool_call>`;
              return (async function* () {
                yield { choices: [{ index: 0, delta: { content }, finish_reason: null }] };
                yield {
                  choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
                  usage: { prompt_tokens: 100, completion_tokens: 30, total_tokens: 130 },
                };
              })();
            },
          },
        },
      };
    };
  });
}

test("server delegation evaluates in the requesting tab, not another connected tab", async ({
  page,
  context,
}) => {
  await installEngine(page);
  await page.goto("/");
  await expect(page.locator("#chat-send")).toBeEnabled();
  await expect(page.locator("#web-llm")).toBeAttached();
  await page.evaluate(() => { window.sameDocument = true; });

  const other = await context.newPage();
  await installEngine(other);
  await other.goto("/");
  await expect(other.locator("#chat-send")).toBeEnabled();
  const client = await page.locator("#web-llm").getAttribute("data-client");
  const otherClient = await other.locator("#web-llm").getAttribute("data-client");
  expect(client).not.toBe(otherClient);

  await page.fill("#chat-prompt", "Please change the demo heading through the browser subagent.");
  await page.click("#chat-send");
  await expect(page.locator("#demo-heading")).toHaveText("Browser GPU was here");
  await expect(page.locator("#transcript .message.browser")).toContainText("Browser GPU was here");
  await expect(page.locator("#transcript .message.browser")).toContainText('"status": "completed"');
  await expect(page.locator("#transcript .message.assistant")).toContainText("Browser GPU was here");
  await expect(page.locator("#agent-status")).toHaveText("Ready");
  expect(await page.evaluate(() => window.sameDocument)).toBe(true);

  const requests = await page.evaluate(() => window.browserRequests);
  expect(requests).toHaveLength(2);
  expect(requests[0].model).toBe("Qwen3-8B-q4f16_1-MLC");
  expect(requests[0].options.messages[0].content).toContain('"name":"browser_eval"');
  expect(requests[0].options.messages[0].content).not.toContain('"name":"browser_task"');
  expect(JSON.stringify(requests[1].options.messages)).toContain("<tool_response>");
  expect(JSON.stringify(requests[1].options.messages)).toContain("A page the browser agent can change");
  expect(JSON.stringify(requests[1].options.messages)).toContain("Browser GPU was here");
  await expect(other.locator("#demo-heading")).toHaveText("A page the browser agent can change");
  expect(await other.evaluate(() => window.browserRequests)).toHaveLength(0);
  await other.close();
});
