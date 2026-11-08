/**
 * Drop-in replacement for @playwright/test whose `page` fixture fails
 * any test whose page produced an uncaught error OR wrote to
 * console.error. The error boundary turns a crash into a "Something
 * went wrong" screen that fails no test by itself, and rendering bugs
 * usually log before a person notices them — this makes every test
 * double as a crash-and-error detector and report the real message.
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
 * array value as a [value, options] tuple, so only the first pattern
 * is used and nothing reports an error. Combine patterns with
 * alternation (see combinePatterns below). Anything not matching still
 * fails the test. A failed preconnect is ignored in every test
 * (tests/helpers/console_errors.js).
 *
 * allowedPageErrors does the same for uncaught errors, for a test that
 * makes the page throw on purpose:
 *
 *   test.use({ allowedPageErrors: /crash for the test/ });
 */
const base = require("@playwright/test");
const { saveCoverage } = require("./visual_coverage");
const { failsTheTest } = require("./console_errors");

// The test decides whether the browser is online, not the laptop's
// network (#268). The app shows ONLINE or OFFLINE from navigator.onLine
// and the browser's online and offline events, and Chromium takes those
// from the computer's real connection. Every page here talks only to
// localhost, which works with or without Wi-Fi, so a dropped network
// changed nothing but that word, and failed 27 tests.
//
// So every page starts with navigator.onLine true, and the online and
// offline events are stopped before the app hears them. A test that
// calls context.setOffline gets the real value and the real events back
// from that moment, in every page of the context, so the tests that go
// offline on purpose (tests/e2e/visual.spec.js) still see OFFLINE.
function keepTheBrowserOnline() {
  const realOnLine = Object.getOwnPropertyDescriptor(
    Navigator.prototype,
    "onLine",
  ).get;
  Object.defineProperty(Navigator.prototype, "onLine", {
    configurable: true,
    enumerable: true,
    get() {
      return window.__testSetsTheNetwork ? realOnLine.call(this) : true;
    },
  });
  // A capture listener on window runs before the app's own listeners.
  for (const type of ["online", "offline"]) {
    window.addEventListener(
      type,
      (event) => {
        if (!window.__testSetsTheNetwork) event.stopImmediatePropagation();
      },
      true,
    );
  }
}

function letTheTestSetTheNetwork() {
  window.__testSetsTheNetwork = true;
}

const test = base.test.extend({
  context: async ({ context }, use) => {
    await context.addInitScript(keepTheBrowserOnline);
    const setOffline = context.setOffline.bind(context);
    context.setOffline = async (offline) => {
      // Pages that are open now, and pages loaded later.
      await context.addInitScript(letTheTestSetTheNetwork);
      await Promise.all(
        context.pages().map((page) => page.evaluate(letTheTestSetTheNetwork)),
      );
      await setOffline(offline);
    };
    await use(context);
  },
  allowedConsoleErrors: [null, { option: true }],
  allowedPageErrors: [null, { option: true }],
  // Every page load sends the browser check's report to
  // POST /api/v1/browser-reports (app/frontend/browser_check.js). The
  // mocked suite has no server to answer it, and the browser logs the
  // 404 as an error, so the report is answered here. A test that reads
  // the report routes it itself, and its route wins. The integration
  // suite sets "server" (playwright.integration.config.js): there the
  // real server answers it.
  browserReports: ["answer", { option: true }],
  page: async (
    { page, allowedConsoleErrors, allowedPageErrors, browserReports },
    use,
    testInfo,
  ) => {
    if (browserReports === "answer") {
      await page.route("**/api/v1/browser-reports*", (route) =>
        route.fulfill({ status: 204 }),
      );
    }
    const pageErrors = [];
    const consoleErrors = [];
    // The screen-state measure (bin/visual-coverage): the instrumented
    // build keeps istanbul counters in window.__coverage__. A full page
    // load (a login, a logout) would drop them, so the page hands them
    // out before it unloads, and again when the test ends.
    if (process.env.VISUAL_COVERAGE) {
      await page.exposeFunction("__saveCoverage", (json) =>
        saveCoverage(json, testInfo),
      );
      await page.addInitScript(() => {
        window.addEventListener("pagehide", () => {
          if (window.__coverage__) {
            window.__saveCoverage(JSON.stringify(window.__coverage__));
          }
        });
      });
    }
    page.on("pageerror", (error) => {
      const text = String(error);
      if (!allowedPageErrors || !allowedPageErrors.test(text)) {
        pageErrors.push(text);
      }
    });
    page.on("console", (message) => {
      if (message.type() !== "error") return;
      const text = message.text();
      if (failsTheTest(text, allowedConsoleErrors)) consoleErrors.push(text);
    });
    await use(page);
    if (process.env.VISUAL_COVERAGE && !page.isClosed()) {
      const coverage = await page
        .evaluate(() => window.__coverage__ || null)
        .catch(() => null);
      if (coverage) saveCoverage(JSON.stringify(coverage), testInfo);
    }
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
