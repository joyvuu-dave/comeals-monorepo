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
      include: ["app/frontend/src/**/*.{js,jsx,ts,tsx}"],
      // A ratchet, not a target: pinned just under the measured
      // numbers on 2026-08-09 (85.6 / 77.8 / 86.3 / 88.2) so coverage
      // can only rise. When it rises, raise these to match.
      thresholds: {
        statements: 85,
        branches: 77,
        functions: 86,
        lines: 88,
      },
    },
  },
});
