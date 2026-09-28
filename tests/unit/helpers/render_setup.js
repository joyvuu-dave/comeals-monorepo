// Loaded by vitest before every unit test file (vitest.config.mjs
// setupFiles). Adds the jest-dom matchers (toBeInTheDocument,
// toBeDisabled, ...) and unmounts rendered components after each test
// so one test's DOM cannot leak into the next.
import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeAll, beforeEach, vi } from "vitest";
import Cookie, { cookies } from "../mocks/js_cookie.js";

// The shared cookie jar (tests/unit/mocks/js_cookie.js) lives for the
// whole file, and its `set` and `remove` change it. So after every test,
// put back the cookies the file started its tests with: the default
// fixture, or the one the file set at its top, which has run by the time
// beforeAll does. mockReset also puts back the jar's own functions if a
// test replaced one with mockImplementation. A file that does not mock
// js-cookie never reads this jar, so the reset does nothing there.
let fileCookies = {};

beforeAll(() => {
  fileCookies = { ...cookies.current };
});

afterEach(() => {
  cookies.current = { ...fileCookies };
  Cookie.get.mockReset();
  Cookie.set.mockReset();
  Cookie.remove.mockReset();
});

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
