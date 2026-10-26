const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");

// Every test here feeds the app a 401 or a dead network. Expected
// noise: the browser's request-failed line, plus the line
// handle_axios_error logs when a request with `silent: true` gets no
// answer. A 401 is not on this list: the signed-out banner shows it,
// and nothing logs it (#246).
test.use({
  allowedConsoleErrors: combinePatterns(
    httpFailurePattern,
    /^Error: no response received from server\.$/,
  ),
});

test.describe("Session Expiry", () => {
  test("shows session-expired banner when API returns 401", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);

    // Override calendar endpoint to return 401 (expired token)
    await page.route("**/api/v1/communities/*/calendar/*", (route) => {
      route.fulfill({
        status: 401,
        contentType: "application/json",
        body: JSON.stringify({
          message:
            "You are not authenticated. Please try signing in and then try again.",
        }),
      });
    });
    const monthAnswers = [];
    page.on("requestfinished", (request) => {
      if (/\/calendar\//.test(request.url())) monthAnswers.push(request);
    });

    await page.goto("/calendar/all/2026-01-15/");

    // Session-expired banner should appear
    const banner = page.locator("text=Heads up — you've been signed out");
    await expect(banner).toBeVisible({ timeout: 10000 });

    // "Log in" button should be present
    const loginButton = page.locator("button", { hasText: "Sign in" });
    await expect(loginButton).toBeVisible();

    // The boot-time request for the month raises the banner. Once the
    // calendar mounts, it asks for the month again (month_fetch.js
    // revalidate), and that answer is a 401 too. Whether that answer
    // came before the test ended was a race, and when it did, its log
    // failed the test (#246). Wait for it, and for one more turn of the
    // page's event loop, so the page has handled it every time.
    await expect.poll(() => monthAnswers.length).toBeGreaterThanOrEqual(2);
    await page.evaluate(() => new Promise((done) => setTimeout(done, 0)));
  });

  test("does NOT show session-expired banner on successful auth", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);

    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");

    // Calendar should render normally
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // No session-expired banner
    await expect(
      page.locator("text=Heads up — you've been signed out"),
    ).not.toBeVisible();
  });

  test("does NOT show session-expired banner when the network fails", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);

    // Override calendar + resident-id to abort (simulates network failure, not 401)
    await page.route("**/api/v1/communities/*/calendar/*", (route) => {
      route.abort("connectionfailed");
    });

    await page.route("**/api/v1/residents/id*", (route) => {
      route.abort("connectionfailed");
    });

    // The month fetch handles its failure by logging this line
    // (handleAxiosError with `silent: true`). Waiting for it proves the aborted
    // request happened and went through the error path. The 401 check
    // runs earlier on that path, in the axios response interceptor, so
    // if this error were going to raise the banner, it would show now.
    const handled = page.waitForEvent(
      "console",
      (message) =>
        message.text() === "Error: no response received from server.",
    );
    await page.goto("/calendar/all/2026-01-15/");
    await handled;

    // No session-expired banner (this is a network error, not auth)
    await expect(
      page.getByText("Heads up — you've been signed out"),
    ).toHaveCount(0);
  });

  test("clicking 'Log in' clears session and redirects to login page", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);

    // Override calendar endpoint to return 401
    await page.route("**/api/v1/communities/*/calendar/*", (route) => {
      route.fulfill({
        status: 401,
        contentType: "application/json",
        body: JSON.stringify({
          message: "You are not authenticated.",
        }),
      });
    });

    await page.goto("/calendar/all/2026-01-15/");

    // Wait for banner
    const loginButton = page.locator("button", { hasText: "Sign in" });
    await expect(loginButton).toBeVisible({ timeout: 10000 });

    // Click "Log in" — should navigate to login page
    await Promise.all([page.waitForEvent("load"), loginButton.click()]);

    // Should be on the login page with email/password fields
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 10000,
    });
  });

  // "Sign in" removes the session cookies and then loads "/". Until the
  // new page arrives, the old one keeps running, and work it started
  // before the click goes on. Here the calendar's code arrives late, and
  // the click comes as soon as the calendar's grid appears, while the
  // calendar is still reading its month from the device. When that read
  // ends, after the click, the calendar asks the server for the month,
  // and the request named the community "undefined" (#153). WebKit
  // reports a request that the page load cuts off, so the test above
  // failed about 2 runs in 25. This test makes that order happen every
  // time. A page that starts on the calendar renders only once the
  // calendar's code has arrived (index.jsx), so the banner and the grid
  // come in the same render: the calendar's code waits until the month's
  // 401 has been answered, so the banner is in that render, and the click
  // comes as soon as the grid appears. The answer to the request for "/"
  // is 204 No Content, so the browser stays on the old page (HTML spec:
  // a navigation answered 204 is dropped) and the test can see every
  // request the old page sends.
  test("'Sign in' while the calendar mounts sends no request with an undefined community id", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);
    let monthRefused;
    const monthAnswered = new Promise((resolve) => {
      monthRefused = resolve;
    });
    await page.route("**/api/v1/communities/*/calendar/*", async (route) => {
      await route.fulfill({
        status: 401,
        contentType: "application/json",
        body: JSON.stringify({ message: "You are not authenticated." }),
      });
      monthRefused();
    });
    await page.route(/\/vite-assets\/show-[^/]*\.js$/, async (route) => {
      await monthAnswered;
      await route.continue();
    });
    let newPageAsked = false;
    await page.route(
      (url) => url.pathname === "/",
      (route) => {
        newPageAsked = true;
        route.fulfill({ status: 204 });
      },
    );
    await page.addInitScript(() => {
      new window.MutationObserver(function (_records, observer) {
        if (!window.document.querySelector(".rbc-calendar")) return;
        const signIn = Array.from(
          window.document.querySelectorAll("button"),
        ).find((button) => button.textContent === "Sign in");
        if (!signIn) return;
        observer.disconnect();
        signIn.click();
      }).observe(window.document, { childList: true, subtree: true });
    });
    const requests = [];
    page.on("request", (request) => requests.push(request.url()));

    // Not "load": index.html preloads the calendar's code, and the page
    // is not loaded until that arrives.
    await page.goto("/calendar/all/2026-01-15/", { waitUntil: "commit" });
    // The click comes only once the calendar's grid is drawn, so the new
    // page is asked for only then. 15 seconds: on a busy machine WebKit
    // once took 7 seconds from here to drawing the calendar.
    await expect.poll(() => newPageAsked, { timeout: 15000 }).toBe(true);
    // Give the old page a second to send whatever it was going to send.
    // No locator from here on: Playwright waits for the navigation the
    // click started, and in Chromium that wait never ends after a 204.
    // WebKit cancels a request sent after the click, and reports it as
    // the error #153 shows, which tests/helpers/test.js fails on.
    await page.waitForTimeout(1000);
    // The community id came from a cookie read with js-cookie
    // (undefined when gone) until session.ts, which reads it as null.
    expect(
      requests.filter((url) => /\/communities\/(undefined|null)\//.test(url)),
    ).toEqual([]);
  });

  test("401 on meal data fetch also triggers banner", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);

    // Override meal endpoint to return 401
    await page.route("**/api/v1/meals/*/cooks*", (route) => {
      route.fulfill({
        status: 401,
        contentType: "application/json",
        body: JSON.stringify({
          message: "You are not authenticated.",
        }),
      });
    });

    // Mock next-meal endpoint to return a meal id so the app tries to load it
    await page.route("**/api/v1/meals/next*", (route) => {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ meal_id: 42 }),
      });
    });

    await page.goto("/meals/42/edit/");

    // Session-expired banner should appear
    await expect(
      page.locator("text=Heads up — you've been signed out"),
    ).toBeVisible({ timeout: 10000 });
  });
});
