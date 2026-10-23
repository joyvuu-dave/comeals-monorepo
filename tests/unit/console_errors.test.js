import { describe, it, expect } from "vitest";
import { failsTheTest } from "../helpers/console_errors.js";

// The strict page fixture (tests/helpers/test.js) fails a test on any
// console error from the page, except the few lines that come from the
// browser and not from the app.
describe("failsTheTest", () => {
  // WebKit logs this when the machine is offline, for the
  // <link rel="preconnect"> in app/frontend/index.html. The page did
  // nothing wrong: a preconnect is only a hint to the browser (#236).
  it("ignores a failed preconnect", () => {
    const text =
      "Failed to preconnect to https://stats.pusher.com/. Error: The Internet connection appears to be offline.";

    expect(failsTheTest(text, null)).toBe(false);
  });

  it("fails on any other console error", () => {
    expect(failsTheTest("TypeError: x is undefined", null)).toBe(true);
  });

  it("fails on a line that only mentions a preconnect later on", () => {
    expect(failsTheTest("Error: Failed to preconnect to the store", null)).toBe(
      true,
    );
  });

  it("ignores what the test said it expects", () => {
    expect(
      failsTheTest("Failed to load resource: 500", /Failed to load resource/),
    ).toBe(false);
  });

  it("still fails on a line the test did not say it expects", () => {
    expect(failsTheTest("TypeError: x", /Failed to load resource/)).toBe(true);
  });
});
