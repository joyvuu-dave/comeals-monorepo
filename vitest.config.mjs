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
    },
  },
});
