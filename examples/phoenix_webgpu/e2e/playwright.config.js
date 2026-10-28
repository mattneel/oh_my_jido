import { defineConfig, devices } from "@playwright/test";

const baseURL = process.env.OMJ_BASE_URL;
if (!baseURL) throw new Error("Set OMJ_BASE_URL to the endpoint URL (mix test does).");

export default defineConfig({
  testDir: ".",
  testMatch: "*.spec.js",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 300_000,
  expect: { timeout: 120_000 },
  reporter: [["list"]],
  outputDir: "test-results",
  use: {
    ...devices["Desktop Chrome"],
    baseURL,
    trace: "retain-on-failure",
  },
});
