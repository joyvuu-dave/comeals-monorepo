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
      // Every line, branch and function, the same rule SimpleCov holds
      // the Ruby side to. A branch the app cannot reach is not a reason
      // to lower these: change the code so the branch is gone. bin/check
      // and CI run test:coverage, so a drop below 100 fails the check.
      thresholds: {
        statements: 100,
        branches: 100,
        functions: 100,
        lines: 100,
      },
    },
  },
});
