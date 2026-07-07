const { defineConfig } = require("@playwright/test");

// perf-modals and pwa-screenshots are on-demand tooling, not correctness
// tests. They're excluded from the default run (`npm run test:e2e`) but must
// still be runnable when explicitly invoked. The env var gate lets the npm
// scripts (`bench:modals`, `pwa:screenshots`) opt back in.
const DEFAULT_IGNORE = ["**/perf-modals.spec.js", "**/pwa-screenshots.spec.js"];

module.exports = defineConfig({
  testDir: "./tests/e2e",
  testIgnore: process.env.PLAYWRIGHT_INCLUDE_ALL ? [] : DEFAULT_IGNORE,
  timeout: 30000,
  expect: {
    timeout: 5000,
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.01,
    },
  },
  fullyParallel: true,
  // One retry so a flake passes on retry and is reported as "flaky" (with
  // the failed attempt's trace kept by retain-on-failure below) instead of
  // failing the run; a real regression fails both attempts. With retries: 0
  // a flake was indistinguishable from a regression (#21).
  retries: 1,
  workers: 1,
  reporter: "list",
  use: {
    baseURL: "http://localhost:3037",
    // retain-on-failure keeps the trace of every FAILED attempt — including
    // the first attempt of a flaky test — and discards traces of passing
    // runs. on-first-retry would only trace the retry, which usually
    // passes, leaving no evidence of what actually failed (#21).
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
  // Port 3037, not 3036, and never reuse: 3036 is the dev server's port.
  // With reuseExistingServer on 3036, running bin/check while bin/dev was
  // up silently ran the whole E2E suite against the dev server (dev-mode
  // React, on-demand transforms, HMR reloads on file edits) instead of the
  // production build — nondeterministic and not what deploys ship (#21).
  // A dedicated port with reuse off means the suite always tests a fresh
  // production build, and a port collision fails loudly instead.
  webServer: {
    command: "npx vite build && npx vite preview --port 3037",
    port: 3037,
    timeout: 60000,
    reuseExistingServer: false,
  },
});
