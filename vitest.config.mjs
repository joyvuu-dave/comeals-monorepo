import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    include: ["tests/unit/**/*.test.{js,ts,jsx,tsx}"],
    setupFiles: ["tests/unit/helpers/render_setup.js"],
    // Vitest's default is 5 seconds. With six full Vitest runs at once
    // on a 10-core laptop, tests that take a fraction of a second on an
    // idle machine took up to 12 seconds, and many failed at 5 (#247).
    // 30 seconds leaves room for more load than that. A test that never
    // ends still fails, only later. The Testing Library wait limit is
    // in render_setup.js.
    testTimeout: 30_000,
    coverage: {
      provider: "v8",
      reporter: ["text", "html"],
      // Its own directory: SimpleCov writes the Ruby report to coverage/,
      // and Vitest empties its report directory on every run.
      reportsDirectory: "coverage/vitest",
      include: ["app/frontend/src/**/*.{js,jsx,ts,tsx}"],
      // Every line, branch and function, the same rule SimpleCov holds
      // the Ruby side to. A branch the app cannot reach is not a reason
      // to lower these: change the code so the branch is gone. bin/check
      // and CI run test:coverage, so a drop below 100 fails the check.
      // A test that renders a component another file loads with
      // React.lazy must mock that file (tests/unit/components/
      // date_box.test.jsx shows how): the lazily loaded copy reports a
      // wrapper offset of 0, and the v8 merge can apply that offset to
      // the file's real coverage, which loses branches at random (#128).
      thresholds: {
        statements: 100,
        branches: 100,
        functions: 100,
        lines: 100,
      },
    },
  },
});
