// Loaded by vitest before every unit test file (vitest.config.mjs
// setupFiles). Adds the jest-dom matchers (toBeInTheDocument,
// toBeDisabled, ...) and unmounts rendered components after each test
// so one test's DOM cannot leak into the next.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach, vi } from "vitest";

// React warns through console.error when a controlled input gets a null
// value or flips between controlled and uncontrolled. That happens when
// a nullable API field is put into an input's `value` without a `|| ""`
// fallback (the common house reservation title did this — its column is
// nullable). The warning only shows in the browser console, so nobody
// sees it in CI unless we turn it into a failure. Any test that renders
// a component with this bug now fails here.
const CONTROLLED_INPUT_WARNINGS = [
  /should not be null/,
  /changing a controlled input to be uncontrolled/,
  /changing an uncontrolled input to be controlled/,
];

let controlledInputWarnings = [];
let consoleErrorSpy = null;

beforeEach(() => {
  controlledInputWarnings = [];
  const originalConsoleError = console.error;
  consoleErrorSpy = vi.spyOn(console, "error").mockImplementation((...args) => {
    const message = args
      .map((arg) => (typeof arg === "string" ? arg : String(arg)))
      .join(" ");
    if (CONTROLLED_INPUT_WARNINGS.some((pattern) => pattern.test(message))) {
      controlledInputWarnings.push(message);
    }
    originalConsoleError(...args);
  });
});

afterEach(() => {
  cleanup();
  // A test may have replaced console.error itself (the bugsnag and
  // error-boundary tests do). Only restore when our spy is still the
  // one installed.
  if (consoleErrorSpy && console.error === consoleErrorSpy) {
    consoleErrorSpy.mockRestore();
  }
  consoleErrorSpy = null;
  if (controlledInputWarnings.length > 0) {
    const failures = controlledInputWarnings.join("\n");
    controlledInputWarnings = [];
    throw new Error(
      `React reported a controlled-input problem. A nullable field is ` +
        `probably going into an input's \`value\` without a "" fallback.\n` +
        failures,
    );
  }
});
