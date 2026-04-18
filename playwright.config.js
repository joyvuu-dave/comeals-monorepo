const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests/e2e",
  // perf-modals is a one-off benchmark invoked via `npm run bench:modals`,
  // not a correctness test. Keep it on disk as tooling but out of the
  // default CI run so it doesn't balloon e2e wall time.
  testIgnore: ["**/perf-modals.spec.js"],
  timeout: 30000,
  expect: {
    timeout: 5000,
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.01,
    },
  },
  fullyParallel: true,
  retries: 0,
  workers: 1,
  reporter: "list",
  use: {
    baseURL: "http://localhost:3036",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
  webServer: {
    command: "npx vite build && npx vite preview --port 3036",
    port: 3036,
    timeout: 60000,
    reuseExistingServer: true,
  },
});
