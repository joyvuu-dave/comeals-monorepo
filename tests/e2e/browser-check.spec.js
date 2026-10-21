const { test, expect } = require("../helpers/test");
const { stubPusher, disableIdleTimer, mockApi } = require("../helpers/setup");

// The browser check (app/frontend/browser_check.js) runs in the built
// page before the app. These tests take one feature away from a real
// browser before the page loads, and check that the person sees the
// message, that the app does not start, and that the check sends its
// report. The last test checks that a normal browser starts the app.

const TOO_OLD = "This browser is too old for Comeals.";
const NO_COOKIES = "Comeals cannot keep you signed in.";

// The report the check sends, and what the test answers. The URL
// carries the whole report; the request has no body.
async function catchReport(page) {
  const reports = [];
  await page.route("**/api/v1/browser-reports*", (route) => {
    reports.push(new URL(route.request().url()).search);
    route.fulfill({ status: 204 });
  });
  return reports;
}

test.describe("the browser check", () => {
  test.beforeEach(async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
  });

  test("turns away a browser without regular expression lookbehind (Safari before 16.4)", async ({
    page,
  }) => {
    await page.addInitScript(() => {
      const RealRegExp = window.RegExp;
      function OldRegExp(source, flags) {
        if (String(source).indexOf("(?<") !== -1) {
          throw new SyntaxError("Invalid regular expression: invalid group");
        }
        return new RealRegExp(source, flags);
      }
      OldRegExp.prototype = RealRegExp.prototype;
      window.RegExp = OldRegExp;
    });
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(page.getByRole("heading", { name: TOO_OLD })).toBeVisible();
    await expect(
      page.getByText(
        "On an iPad or iPhone: open Settings, then General, then Software Update",
      ),
    ).toBeVisible();
    await expect
      .poll(() => reports)
      .toEqual(["?result=failed&tests=lookbehind&touch=0"]);
    // The app's code has run by the time the page's load event fires.
    await page.waitForLoadState("load");
    await expect(page.locator('input[aria-label="email"]')).toHaveCount(0);
    expect(await page.evaluate(() => window.comealsBrowserCheck.result)).toBe(
      "failed",
    );
  });

  test("turns away a browser that cannot mix colors in CSS", async ({
    page,
  }) => {
    await page.addInitScript(() => {
      const supports = window.CSS.supports.bind(window.CSS);
      window.CSS.supports = (...args) =>
        /color-mix/.test(args.join(" ")) ? false : supports(...args);
    });
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(page.getByRole("heading", { name: TOO_OLD })).toBeVisible();
    await expect
      .poll(() => reports)
      .toEqual(["?result=failed&tests=color_mix&touch=0"]);
    await page.waitForLoadState("load");
    await expect(page.locator('input[aria-label="email"]')).toHaveCount(0);
  });

  // The login lives in cookies. With cookies blocked, a sign-in seems to
  // work and then shows the login form again.
  test("turns away a browser that blocks cookies, and says how to allow them", async ({
    page,
  }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window.Document.prototype, "cookie", {
        configurable: true,
        get: () => "",
        set: () => {},
      });
    });
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(page.getByRole("heading", { name: NO_COOKIES })).toBeVisible();
    await expect(page.getByText("turn off Block All Cookies")).toBeVisible();
    await expect
      .poll(() => reports)
      .toEqual(["?result=failed&tests=cookies&touch=0"]);
    await page.waitForLoadState("load");
    await expect(page.locator('input[aria-label="email"]')).toHaveCount(0);
  });

  test("lets a normal browser start the app, and reports that it passed", async ({
    page,
  }) => {
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    await expect(page.getByRole("heading", { name: TOO_OLD })).toHaveCount(0);
    await expect.poll(() => reports).toEqual(["?result=passed&touch=0"]);
  });
});
