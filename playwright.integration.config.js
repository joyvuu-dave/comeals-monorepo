// @ts-check
import { defineConfig } from "@playwright/test";
// 3001 in the main checkout; an agent worktree gets its own port
// through .env (#65). bin/test-integration reads the same .env line.
import ports from "./tests/helpers/ports.js";

/**
 * Integration test config — runs against a REAL Rails backend.
 *
 * The Rails test server must be running before Playwright starts.
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
    baseURL: `http://localhost:${ports.INTEGRATION_PORT}`,
    screenshot: "only-on-failure",
    trace: "on-first-retry",
    // The community's timezone. Rendering depends on the viewer's
    // zone (the November DST escape), so tests pin it rather than
    // inherit whatever machine runs the suite.
    timezoneId: "America/Los_Angeles",
  },

  projects: [
    {
      name: "integration",
      use: { browserName: "chromium" },
    },
    // Same tests under WebKit (Safari's engine) — see the webkit
    // project in playwright.config.js for why.
    {
      name: "integration-webkit",
      use: { browserName: "webkit" },
    },
  ],
});
