// @ts-check
import { defineConfig } from "@playwright/test";

/**
 * Integration test config — runs against a REAL Rails backend.
 *
 * The Rails test server (port 3001) must be running before Playwright starts.
 * Use bin/test-integration to orchestrate seed → server → tests → cleanup.
 *
 * Unlike the mocked E2E suite (playwright.config.js), API calls here hit the
 * real database and return real serialized responses.
 */
export default defineConfig({
  testDir: "./tests/integration",
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [["list"]],

  use: {
    baseURL: "http://localhost:3001",
    screenshot: "only-on-failure",
    trace: "on-first-retry",
  },

  projects: [
    {
      name: "integration",
      use: { browserName: "chromium" },
    },
  ],
});
