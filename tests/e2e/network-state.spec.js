const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");

// The browser tests decide whether the browser is online. The laptop's
// network does not (#268). The app shows ONLINE or OFFLINE from
// navigator.onLine and the browser's online and offline events, and
// Chromium takes those from the computer's real connection. Before this,
// a Wi-Fi drop during bin/check failed 27 tests that had nothing wrong.
//
// Chromium's own network switch (the CDP command, not Playwright's
// context.setOffline) does to the page what a Wi-Fi drop does: it makes
// navigator.onLine false and fires "offline". WebKit has no such
// command, so these run in Chromium alone.
test.describe("Network state in the browser tests", () => {
  test.beforeEach(({ browserName }) => {
    test.skip(browserName !== "chromium", "CDP is Chromium-only");
  });

  async function openCalendar(page, context) {
    await setupAuthenticatedPage(page, context);
    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });
  }

  async function dropTheLaptopsNetwork(page) {
    const session = await page.context().newCDPSession(page);
    await session.send("Network.enable");
    await session.send("Network.emulateNetworkConditions", {
      offline: true,
      latency: 0,
      downloadThroughput: -1,
      uploadThroughput: -1,
    });
  }

  test("the page stays ONLINE when the laptop's network drops", async ({
    page,
    context,
  }) => {
    await openCalendar(page, context);

    await dropTheLaptopsNetwork(page);

    // The real event has fired by the time the real value reads false.
    await page.waitForTimeout(500);
    expect(await page.evaluate(() => navigator.onLine)).toBe(true);
    await expect(page.locator("span.online, span.offline")).toHaveText(
      "ONLINE",
    );
  });

  test("a test that calls context.setOffline still goes OFFLINE and back", async ({
    page,
    context,
  }) => {
    await openCalendar(page, context);

    await context.setOffline(true);
    await expect(page.locator(".offline")).toHaveText("OFFLINE");
    expect(await page.evaluate(() => navigator.onLine)).toBe(false);

    await context.setOffline(false);
    await expect(page.locator("span.online")).toHaveText("ONLINE");
    expect(await page.evaluate(() => navigator.onLine)).toBe(true);
  });
});
