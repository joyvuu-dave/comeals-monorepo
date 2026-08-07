const { defineConfig } = require("@playwright/test");

// perf-modals and pwa-screenshots are on-demand tooling, not correctness
// tests. They're excluded from the default run (`npm run test:e2e`) but must
// still be runnable when explicitly invoked. The env var gate lets the npm
// scripts (`bench:modals`, `pwa:screenshots`) opt back in.
const DEFAULT_IGNORE = ["**/perf-modals.spec.js", "**/pwa-screenshots.spec.js"];

module.exports = defineConfig({
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
      testDir: "./tests/e2e",
      use: { browserName: "chromium" },
    },
    // ActiveAdmin is server-rendered by Rails, so this project talks to a
    // real Rails server (the second webServer below) instead of the vite
    // preview + mocked API the SPA suite uses. admin.lvh.me is mapped to
    // 127.0.0.1 inside the browser, so the suite works without DNS.
    {
      name: "admin",
      testDir: "./tests/admin",
      use: {
        browserName: "chromium",
        baseURL: "http://admin.lvh.me:3038",
        launchOptions: {
          args: ["--host-resolver-rules=MAP *.lvh.me 127.0.0.1"],
        },
      },
    },
  ],
  // Port 3037, not 3036, and never reuse: 3036 is the dev server's port.
  // With reuseExistingServer on 3036, running bin/check while bin/dev was
  // up silently ran the whole E2E suite against the dev server (dev-mode
  // React, on-demand transforms, HMR reloads on file edits) instead of the
  // production build — nondeterministic and not what deploys ship (#21).
  // A dedicated port with reuse off means the suite always tests a fresh
  // production build, and a port collision fails loudly instead.
  // The build is the same `npm run build` every other path runs — one
  // layout everywhere. bin/check builds once for the whole run and sets
  // E2E_SKIP_BUILD so this server just serves that build; a standalone
  // `npm run test:e2e` still builds for itself.
  webServer: [
    {
      command: process.env.E2E_SKIP_BUILD
        ? "npx vite preview --port 3037"
        : "npm run build && npx vite preview --port 3037",
      port: 3037,
      timeout: 60000,
      reuseExistingServer: false,
    },
    // Rails for the admin project. The script prepares and seeds the
    // dedicated comeals_admin_e2e database before it starts listening,
    // so waiting on the port is the same as waiting on readiness.
    // webServer entries are global (not per-project), so environments
    // that cannot run Rails — the Playwright Linux container that
    // bin/update-linux-snapshots uses has no Ruby — set
    // PLAYWRIGHT_SKIP_ADMIN to leave this server out.
    ...(process.env.PLAYWRIGHT_SKIP_ADMIN
      ? []
      : [
          {
            command: "tests/admin/server.sh",
            port: 3038,
            timeout: 120000,
            reuseExistingServer: false,
          },
        ]),
  ],
});
