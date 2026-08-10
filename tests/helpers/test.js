/**
 * Drop-in replacement for @playwright/test whose `page` fixture fails
 * any test whose page produced an uncaught error OR wrote to
 * console.error. The error boundary turns a crash into a quiet
 * "Something went wrong" screen, and rendering bugs usually log
 * before a person notices them — this makes every test double as a
 * crash-and-error detector and report the real message.
 *
 * Use it in specs instead of @playwright/test:
 *
 *   const { test, expect } = require("../helpers/test");
 *
 * A test that intentionally makes the app hit an error path (a
 * mocked 500, a wrong password) declares what it expects, scoped as
 * narrowly as the intent:
 *
 *   test.use({ allowedConsoleErrors: /Failed to load resource/ });
 *
 * The option is ONE RegExp, not an array — test.use() unwraps an
 * array value as a [value, options] tuple, which silently mangles
 * pattern lists. Combine patterns with alternation (see
 * combinePatterns below). Anything not matching still fails the
 * test.
 */
const base = require("@playwright/test");

const test = base.test.extend({
  allowedConsoleErrors: [null, { option: true }],
  page: async ({ page, allowedConsoleErrors }, use) => {
    const pageErrors = [];
    const consoleErrors = [];
    page.on("pageerror", (error) => pageErrors.push(String(error)));
    page.on("console", (message) => {
      if (message.type() !== "error") return;
      const text = message.text();
      if (allowedConsoleErrors && allowedConsoleErrors.test(text)) return;
      consoleErrors.push(text);
    });
    await use(page);
    base.expect(pageErrors, "uncaught page errors during the test").toEqual([]);
    base
      .expect(consoleErrors, "unexpected console errors during the test")
      .toEqual([]);
  },
});

// The browser's own log line for a request that failed or returned an
// error status — the expected noise of a test that mocks a 401/500 or
// cuts the network. Chromium says "Failed to load resource" /
// "net::ERR_*"; WebKit says "Load failed" / "XMLHttpRequest cannot
// load". Real application errors (React, stores, our own code) match
// none of these and still fail the test.
const httpFailurePattern =
  /Failed to load resource|net::ERR_|Load failed|XMLHttpRequest cannot load/;

// Joins RegExps into one, for allowedConsoleErrors:
//   combinePatterns(httpFailurePattern, /^You are not authenticated\.$/)
function combinePatterns(...patterns) {
  return new RegExp(patterns.map((p) => p.source).join("|"));
}

module.exports = {
  test,
  expect: base.expect,
  httpFailurePattern,
  combinePatterns,
};
