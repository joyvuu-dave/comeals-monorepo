const { test, expect, httpFailurePattern } = require("../helpers/test");
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

// The app's code is one module script in index.html, plus the files it
// imports. If it cannot load (a 404 after a deploy, when a browser got
// the old index.html, or a network drop), the page would show
// "Loading..." forever, and nothing would be reported, because Bugsnag
// lives in that code. The browser check watches for that. On the first
// failure it reloads the page once. On a second failure it shows a
// message with a Reload button and sends one report.
test.describe("when the app's code does not load", () => {
  const COULD_NOT_LOAD = "Comeals could not load.";

  test.use({ allowedConsoleErrors: httpFailurePattern });

  test.beforeEach(async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    // The page asks the server for its version before it reloads.
    await page.route("**/api/v1/version", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: '{"version":"test"}',
      }),
    );
  });

  // The path of the app's module script in the built index.html, and of
  // one file it imports.
  async function builtFiles(page) {
    const html = await (await page.request.get("/")).text();
    return {
      main: html.match(/<script type="module" crossorigin src="([^"]+)"/)[1],
      imported: html.match(
        /<link rel="modulepreload" crossorigin href="([^"]+)"/,
      )[1],
    };
  }

  // Answers `path` with a 404 for the first `failures` requests, then
  // serves the real file. Returns the list of requests for it.
  async function failFile(page, path, failures) {
    const requests = [];
    await page.route(
      (url) => url.pathname === path,
      (route) => {
        requests.push(route.request().url());
        if (requests.length <= failures) {
          route.fulfill({ status: 404, body: "Not Found" });
        } else {
          route.fallback();
        }
      },
    );
    return requests;
  }

  function flag(page) {
    return page.evaluate(() => window.sessionStorage.getItem("app_retry"));
  }

  test("reloads once, starts the app, and clears what it remembered", async ({
    page,
  }) => {
    const { main } = await builtFiles(page);
    const requests = await failFile(page, main, 1);
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    expect(requests).toHaveLength(2);
    // One report per page load, and the reload is a second page load.
    await expect
      .poll(() => reports)
      .toEqual(["?result=passed&touch=0", "?result=passed&touch=0"]);
    // So the next deploy can reload the page again.
    expect(await flag(page)).toBeNull();
  });

  test("shows a message and reports once when the reload does not help", async ({
    page,
  }) => {
    const { main } = await builtFiles(page);
    const requests = await failFile(page, main, 1000);
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(
      page.getByRole("heading", { name: COULD_NOT_LOAD }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Reload" })).toBeVisible();
    await expect(page.getByText("Loading...")).toHaveCount(0);
    expect(requests).toHaveLength(2);
    await expect
      .poll(() => reports)
      .toEqual([
        "?result=passed&touch=0",
        "?result=passed&touch=0",
        `?result=load_failed&error=${encodeURIComponent(`Could not load ${main}`)}&touch=0`,
      ]);
    // No more reloads and no more reports.
    await page.waitForTimeout(500);
    expect(requests).toHaveLength(2);
    expect(reports).toHaveLength(3);
  });

  test("the Reload button loads the page again", async ({ page }) => {
    const { main } = await builtFiles(page);
    const requests = await failFile(page, main, 2);
    await catchReport(page);

    await page.goto("/");
    await page.getByRole("button", { name: "Reload" }).click();

    await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    expect(requests).toHaveLength(3);
    expect(await flag(page)).toBeNull();
  });

  // A file the app's code imports fails the same way: the browser fires
  // the error on the module script.
  test("counts a file the app's code imports as the app's code", async ({
    page,
  }) => {
    const { imported } = await builtFiles(page);
    await failFile(page, imported, 1000);
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(
      page.getByRole("heading", { name: COULD_NOT_LOAD }),
    ).toBeVisible();
    await expect.poll(() => reports.length).toBe(3);
  });

  // A browser set to block site data throws on any use of
  // sessionStorage. The page cannot remember a reload, so it never
  // reloads: a file that stays missing would reload it over and over.
  test("never reloads when sessionStorage cannot be used", async ({ page }) => {
    await page.addInitScript(() => {
      Object.defineProperty(window, "sessionStorage", {
        configurable: true,
        get() {
          throw new DOMException("The operation is insecure.", "SecurityError");
        },
      });
    });
    const { main } = await builtFiles(page);
    const requests = await failFile(page, main, 1000);
    const reports = await catchReport(page);

    await page.goto("/");

    await expect(
      page.getByRole("heading", { name: COULD_NOT_LOAD }),
    ).toBeVisible();
    await page.waitForTimeout(500);
    expect(requests).toHaveLength(1);
    await expect
      .poll(() => reports)
      .toEqual([
        "?result=passed&touch=0",
        `?result=load_failed&error=${encodeURIComponent(`Could not load ${main}`)}&touch=0`,
      ]);
  });
});
