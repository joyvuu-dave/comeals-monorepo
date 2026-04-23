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
