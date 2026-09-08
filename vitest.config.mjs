import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    include: ["tests/unit/**/*.test.{js,ts,jsx,tsx}"],
    setupFiles: ["tests/unit/helpers/render_setup.js"],
    coverage: {
      provider: "v8",
      reporter: ["text", "html"],
      // Its own directory: SimpleCov writes the Ruby report to coverage/,
      // and Vitest empties its report directory on every run.
      reportsDirectory: "coverage/vitest",
      include: ["app/frontend/src/**/*.{js,jsx,ts,tsx}"],
      // Left out of the count, the way spec/ is on the Ruby side:
      // index.jsx boots the app (the router, the providers, the
      // boot-time prefetch) and only runs in a browser, and nav_trace
      // is development-only timing that production builds shim away.
      // The browser suites (tests/e2e, tests/integration) run both.
      exclude: [
        "app/frontend/src/index.jsx",
        "app/frontend/src/helpers/nav_trace.js",
      ],
      // A ratchet, not a target: pinned just under the numbers measured
      // on 2026-09-08 (92.5 / 85.6 / 92.6 / 93.9), so coverage can only
      // rise. When it rises, raise these to match. Unit tests measure
      // what a unit test should: the stores and helpers. Screens are
      // exercised by the browser suites, which this number does not
      // see. bin/check and CI run test:coverage, so a drop below these
      // fails the check.
      thresholds: {
        statements: 92,
        branches: 85,
        functions: 92,
        lines: 93,
      },
    },
  },
});
