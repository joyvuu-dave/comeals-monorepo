// Loaded by vitest before every unit test file (vitest.config.mjs
// setupFiles). Adds the jest-dom matchers (toBeInTheDocument,
// toBeDisabled, ...) and unmounts rendered components after each test
// so one test's DOM cannot leak into the next.
import "@testing-library/jest-dom/vitest";
import { cleanup, configure } from "@testing-library/react";
import { afterEach, beforeAll, beforeEach, vi } from "vitest";
import Cookie, { cookies } from "../mocks/js_cookie.js";
import { WAIT_LIMIT_MS } from "./wait_for.js";
import { clearPageSettings } from "./page_settings_for_tests.js";
import {
  clearExpected,
  expectedNotSeen,
  isExpected,
} from "./console_output.js";

// How long findBy* and waitFor wait before they fail. Testing Library's
// default is 1 second. With six full Vitest runs at once, waits that
// end in a few milliseconds on an idle machine took up to 2.7 seconds,
// and some went past 1 second (#247). 10 seconds leaves room for more
// load than that. Vitest's own waits get the same limit through
// wait_for.js, where the number is.
configure({ asyncUtilTimeout: WAIT_LIMIT_MS });

// jsdom does not scroll, so it has no scrollIntoView. A calendar form
// scrolls its own messages into view (form_messages.tsx), and every
// test that makes a form's request fail would throw without this. A
// test that checks the scroll spies on it.
if (typeof Element.prototype.scrollIntoView !== "function") {
  Element.prototype.scrollIntoView = function () {};
}

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

// A test fails when the code it runs writes to console.error or
// console.warn and the test did not say it expects that (#249). RSpec
// and the browser tests already fail this way, and a warning that only
// scrolls by in the output hides a real problem: a React act() warning,
// a store that logged a failed request, a controlled input given null.
//
// A test says it expects a message with expectConsole
// (console_output.js), or by replacing console.error or console.warn
// itself (vi.spyOn(console, "error").mockImplementation(...)), which
// takes the place of the recording below for that test.
//
// React warns through console.error when a controlled input gets a null
// value or flips between controlled and uncontrolled. That happens when
// a nullable API field is put into an input's `value` without a `|| ""`
// fallback (the common house reservation title did this — its column is
// nullable). Those get their own message, which says what to fix.
const CONTROLLED_INPUT_WARNINGS = [
  /should not be null/,
  /changing a controlled input to be uncontrolled/,
  /changing an uncontrolled input to be controlled/,
];

// Messages from a library that this repo cannot fix. Only a library's
// own messages go here, never the app's. React prints each of these
// once per test file, so it lands on whichever test runs first, and no
// one test can say it expects it.
const LIBRARY_MESSAGES = [
  // React 19 warns when an element is made with the old JSX transform.
  // react-big-calendar 1.20 wraps its Calendar with uncontrollable
  // 7.2.1, whose build makes an element that way (with a __self prop:
  // node_modules/uncontrollable/lib/cjs/uncontrollable.js). Every page
  // with the calendar draws that element. react-big-calendar requires
  // uncontrollable ^7.2.1, and 7.2.1 is the last 7.x release.
  {
    method: "warn",
    pattern:
      /^Your app \(or one of its dependencies\) is using an outdated JSX transform\./,
  },
];

let unexpectedOutput = [];
let consoleSpies = [];

function recordConsole(method) {
  const original = console[method];
  const spy = vi.spyOn(console, method).mockImplementation((...args) => {
    const message = args
      .map((arg) => (typeof arg === "string" ? arg : String(arg)))
      .join(" ");
    const fromLibrary = LIBRARY_MESSAGES.some(
      (item) => item.method === method && item.pattern.test(message),
    );
    if (fromLibrary) return;
    if (isExpected(method, message)) return;
    unexpectedOutput.push({ method, message });
    original(...args);
  });
  consoleSpies.push({ method, spy });
}

beforeEach(() => {
  unexpectedOutput = [];
  consoleSpies = [];
  recordConsole("error");
  recordConsole("warn");
});

afterEach(() => {
  cleanup();
  clearPageSettings();
  // A test may have replaced console.error or console.warn itself (the
  // bugsnag and error-boundary tests do). Only restore a spy that is
  // still the one installed.
  for (const { method, spy } of consoleSpies) {
    if (console[method] === spy) spy.mockRestore();
  }
  consoleSpies = [];
  const missing = expectedNotSeen();
  clearExpected();
  const output = unexpectedOutput;
  unexpectedOutput = [];
  const controlled = output.filter(({ message }) =>
    CONTROLLED_INPUT_WARNINGS.some((pattern) => pattern.test(message)),
  );
  if (controlled.length > 0) {
    throw new Error(
      `React reported a controlled-input problem. A nullable field is ` +
        `probably going into an input's \`value\` without a "" fallback.\n` +
        controlled.map(({ message }) => message).join("\n"),
    );
  }
  if (output.length > 0) {
    throw new Error(
      `The test wrote to the console without saying it expects that. ` +
        `Fix the cause, or call expectConsole(method, pattern) in the ` +
        `test (tests/unit/helpers/console_output.js).\n` +
        output
          .map(({ method, message }) => `console.${method}: ${message}`)
          .join("\n"),
    );
  }
  if (missing.length > 0) {
    throw new Error(
      `The test expected console output it never wrote:\n` + missing.join("\n"),
    );
  }
});
