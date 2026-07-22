/**
 * Drop-in replacement for @playwright/test whose `page` fixture fails
 * any test whose page produced an uncaught error. The error boundary
 * turns a crash into a quiet "Something went wrong" screen, so a test
 * that only looks for its own elements can time out without saying
 * why — this makes every test double as a crash detector and report
 * the real error.
 *
 * Use it in specs instead of @playwright/test:
 *
 *   const { test, expect } = require("../helpers/test");
 */
const base = require("@playwright/test");

const test = base.test.extend({
  page: async ({ page }, use) => {
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(String(error)));
    await use(page);
    base.expect(pageErrors, "uncaught page errors during the test").toEqual([]);
  },
});

module.exports = { test, expect: base.expect };
