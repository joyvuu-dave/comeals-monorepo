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
  // Its own folder inside test-results/. bin/check runs the mocked
  // suite first, and Playwright empties its output folder when a run
  // starts, so with one shared folder this suite deleted the mocked
  // suite's traces. CI uploads all of test-results/.
  outputDir: "test-results/integration",

  use: {
    baseURL: `http://localhost:${ports.INTEGRATION_PORT}`,
    // The real server answers the browser check's report
    // (tests/helpers/test.js answers it in the mocked suite).
    browserReports: "server",
    screenshot: "only-on-failure",
    // There are no retries, so "on-first-retry" never kept a trace:
    // a failure left only a screenshot (#132).
    trace: "retain-on-failure",
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
