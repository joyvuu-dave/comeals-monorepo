const { test, expect, httpFailurePattern } = require("../helpers/test");
const {
  stubPusher,
  disableIdleTimer,
} = require("../helpers/integration_setup");
const routes = require("../../app/frontend/src/routes.json");

// Every page of routes.json, opened by a full load from the real server:
// the way a bookmark, a link in an email, or a reload opens it. The
// server must answer 200 with the app, and the app must show the page,
// not Page not found (ADR 0016). The examples come from the list, so a
// page added there is opened here with no change to this file.
test.describe("Every page of the app, from the real server", () => {
  test.beforeEach(async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
  });

  for (const [name, page] of Object.entries(routes.pages)) {
    for (const example of page.examples) {
      test(`opens ${example}, the ${name} page`, async ({ page: tab }) => {
        const response = await tab.goto(example);

        expect(response.status()).toBe(200);
        // Signed out, the calendar and the meal page send the browser on
        // to the sign-in page, which is a page too.
        await expect(tab.locator("#root > *").first()).toBeVisible();
        await expect(
          tab.getByRole("heading", { name: "Page not found" }),
        ).toHaveCount(0);
      });
    }
  }
});

// Addresses that are not pages get the server's plain 404 page, which
// does not load the app. These open non-pages on purpose, so the check
// that every address shown is a page is off, and the browser's log line
// for the 404 is expected.
test.describe("Addresses that are not pages, from the real server", () => {
  test.use({ addressCheck: false, allowedConsoleErrors: httpFailurePattern });

  for (const address of [
    "/.well-known/security.txt",
    "/foo.json",
    "/calnedar",
    "/meals/1/edit/nothing",
  ]) {
    test(`answers ${address} with the 404 page and a way back`, async ({
      page,
    }) => {
      const response = await page.goto(address);

      expect(response.status()).toBe(404);
      await expect(
        page.getByRole("heading", { name: "Page not found" }),
      ).toBeVisible();
      await page
        .getByRole("link", { name: "Go to the Comeals home page" })
        .click();
      await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    });
  }
});
