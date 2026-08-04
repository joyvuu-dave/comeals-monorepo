// Loaded by vitest before every unit test file (vitest.config.mjs
// setupFiles). Adds the jest-dom matchers (toBeInTheDocument,
// toBeDisabled, ...) and unmounts rendered components after each test
// so one test's DOM cannot leak into the next.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

afterEach(() => {
  cleanup();
});
