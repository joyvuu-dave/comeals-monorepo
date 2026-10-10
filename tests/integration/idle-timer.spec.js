const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
const {
  COMMUNITY_TIMEZONE,
  FAKE_NOW,
  FAKE_TODAY,
  loadAuthInfo,
  authenticateContext,
  stubPusher,
  disableIdleTimer,
  gotoMeal,
  mealLoaded,
} = require("../helpers/integration_setup");
const { zonedInstant } = require("../helpers/zoned_time");

// The idle timer (app/frontend/src/components/app/back_to_today.tsx).
// Five minutes after the last mouse, key, scroll or touch event, or after
// the page loads or changes, it sends the screen to today's calendar.
// So a shared screen someone walked away from shows today again. It
// moves inside the app, with no page load: the messages on screen stay,
// a cost still waiting to save is sent the way leaving a meal sends it,
// and an open calendar form is never closed. A crashed page and old code
// after a deploy are the two cases it loads the page from the server
// instead; the crash is checked in
// tests/unit/components/back_to_today.test.jsx.
//
// Every other browser test turns the timer off with disableIdleTimer.
// These tests check the timer itself, and that the helper really turns
// it off (#118: the old helper did not).

const auth = loadAuthInfo();
const mealId = auth.meals.today.id;
const mealPath = `/meals/${mealId}/edit/`;
const calendarPath = `/calendar/all/${FAKE_TODAY}/`;
const FIVE_MINUTES = 5 * 60 * 1000;

// What the server answers when it refuses a sign-up, in this test only.
const REFUSAL = "Test refusal: this sign-up was not saved.";

// A path, as a RegExp for toHaveURL, anchored at the end.
function endsWith(path) {
  return new RegExp(`${path.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}$`);
}

test.describe("Idle timer (real backend)", () => {
  test.use({
    allowedConsoleErrors: combinePatterns(
      httpFailurePattern,
      new RegExp(`^${REFUSAL}$`),
    ),
  });

  test.beforeEach(async ({ page, context }) => {
    // install, not setFixedTime: fastForward runs the page's timers
    // only on an installed clock.
    await page.clock.install({ time: FAKE_NOW });
    await authenticateContext(context);
    await stubPusher(page);
  });

  async function openMeal(page) {
    await gotoMeal(page, mealId);
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();
  }

  // A page load starts the five minutes. Before, only the first touch
  // did, so a page loaded with nobody there never went home.
  test("a page nobody touches goes home five minutes after it loads", async ({
    page,
  }) => {
    await openMeal(page);

    await page.clock.fastForward("04:55");
    await expect(page).toHaveURL(endsWith(mealPath));

    await page.clock.fastForward("00:06");
    await expect(page).toHaveURL(endsWith(calendarPath));
  });

  test("a key press starts the five minutes again", async ({ page }) => {
    await openMeal(page);
    await page.clock.fastForward("04:00");
    await page.keyboard.press("a");

    // 8 minutes since the page loaded, but only 4 since the key press.
    await page.clock.fastForward("04:00");
    await expect(page).toHaveURL(endsWith(mealPath));

    await page.clock.fastForward("01:01");
    await expect(page).toHaveURL(endsWith(calendarPath));
  });

  test("a modifier key alone is not activity", async ({ page }) => {
    await openMeal(page);
    await page.clock.fastForward("04:00");
    await page.keyboard.press("Shift");

    await page.clock.fastForward("01:01");
    await expect(page).toHaveURL(endsWith(calendarPath));
  });

  // Before, the trip home loaded the page again, which took away every
  // message, read or not (#137).
  test("the trip home keeps the page and the messages on it", async ({
    page,
  }) => {
    await page.route("**/api/v1/meals/*/residents/*", (route) =>
      route.fulfill({
        status: 409,
        contentType: "application/json",
        body: JSON.stringify({ message: REFUSAL }),
      }),
    );
    await openMeal(page);
    await page.evaluate(() => {
      window.__samePage = true;
    });
    await page
      .getByRole("cell", { name: "B - Bob Johnson", exact: true })
      .click();
    const message = page.locator(".toast", { hasText: REFUSAL });
    await expect(message).toBeVisible();

    await page.clock.fastForward("05:01");
    await expect(page).toHaveURL(endsWith(calendarPath));
    await expect(page.locator(".rbc-calendar")).toBeVisible();
    await expect(message).toBeVisible();
    expect(await page.evaluate(() => window.__samePage)).toBe(true);
  });

  // The calendar already shows today's month, so the timer does nothing.
  // Before, it loaded "/" again, which sent the screen back to the same
  // calendar after a page load.
  test("the calendar of today's month stays as it is", async ({ page }) => {
    await page.goto(calendarPath);
    await expect(page.locator(".rbc-calendar")).toBeVisible();
    await page.evaluate(() => {
      window.__samePage = true;
    });
    await page.mouse.move(10, 10);

    await page.clock.fastForward("05:01");
    await page.waitForTimeout(500);
    await expect(page).toHaveURL(endsWith(calendarPath));
    expect(await page.evaluate(() => window.__samePage)).toBe(true);
  });

  // After a deploy, a move inside the app would keep the old code
  // running until someone tapped Refresh. So when the banner has seen a
  // new version, the timer loads today's calendar from the server, five
  // minutes after the banner saw it. Before, nothing loaded the new code
  // by itself.
  test("a screen nobody uses loads a new version five minutes after the banner sees it", async ({
    page,
  }) => {
    await page.route("**/.vite/manifest.json", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          "index.html": {
            isEntry: true,
            file: "vite-assets/index-NEWBUILD.js",
          },
        }),
      }),
    );
    await page.goto(calendarPath);
    await expect(page.locator(".rbc-calendar")).toBeVisible();
    await page.evaluate(() => {
      window.__samePage = true;
    });

    // The banner looks every five minutes.
    await page.clock.fastForward("05:01");
    await expect(page.locator(".app-banner--info")).toBeVisible();
    expect(await page.evaluate(() => window.__samePage)).toBe(true);

    const loaded = page.waitForEvent("load");
    await page.clock.fastForward("05:30");
    await loaded;
    await expect(page).toHaveURL(endsWith(calendarPath));
    await expect(page.locator(".rbc-calendar")).toBeVisible();
    expect(await page.evaluate(() => window.__samePage)).toBeUndefined();
  });

  // ADR 0006: a calendar form is a draft until Create or Update. Before,
  // the trip home closed it and threw the draft away.
  test("an open calendar form stays open with what was typed", async ({
    page,
  }) => {
    await page.goto("/calendar/all/2026-03-01/events/new/");
    const title = page.locator("#event-new-title");
    await title.fill("Draft the timer must keep");
    await page.mouse.move(10, 10);

    await page.clock.fastForward("10:00");
    await page.waitForTimeout(500);
    await expect(page).toHaveURL(
      endsWith("/calendar/all/2026-03-01/events/new/"),
    );
    await expect(title).toHaveValue("Draft the timer must keep");
  });

  // A cook row saves 2 seconds after its last edit. A cost can still be
  // waiting when the timer leaves the meal, and leaving must send it,
  // as going to another meal or to the calendar does. fill and
  // selectOption make no mouse or key events, so the timer is not
  // started again by them.
  test("a cost still waiting to save is sent when the timer leaves the meal", async ({
    page,
  }) => {
    await openMeal(page);
    // From here no timer runs until the test says so. The mouse move
    // starts the five minutes at a known time.
    const now = await page.evaluate(() => Date.now());
    await page.clock.pauseAt(now + 1000);
    await page.mouse.move(10, 10);
    await page.clock.runFor(FIVE_MINUTES - 1000);

    await page
      .locator('[aria-label="Select meal cook"]')
      .first()
      .selectOption(String(auth.resident_id));
    const saved = page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes(`/api/v1/meals/${mealId}/bills`) &&
        r
          .request()
          .postDataJSON()
          .edits.some((edit) => edit.to && edit.to.amount === "42.50"),
    );
    await page.locator('[aria-label="Set meal cost"]').first().fill("42.50");

    // The timer ends one second before the row's own wait would.
    await page.clock.runFor(1000);
    expect((await saved).ok()).toBe(true);
    await expect(page).toHaveURL(endsWith(calendarPath));

    // Put the meal back the way the other tests expect it. Back, not a
    // page load: a page load would cut off the requests the calendar
    // has just sent, and WebKit logs each one as an error.
    await page.clock.resume();
    const loaded = mealLoaded(page, mealId);
    await page.goBack();
    await loaded;
    await expect(page).toHaveURL(endsWith(mealPath));
    const cost = page.locator('[aria-label="Set meal cost"]').first();
    await expect(cost).toHaveValue("42.50");
    const cleared = page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes(`/api/v1/meals/${mealId}/bills`),
    );
    await cost.fill("0");
    await cleared;
  });

  // At the community's midnight, the calendar of the month that held
  // the old day moves to the new day's month, inside the app. Before,
  // only the date in the header and the mark on today moved, so a screen
  // nobody touched showed January's meals all through February.
  test("the calendar of the old month moves to the new month at midnight", async ({
    page,
  }) => {
    const at = (wallClock) => zonedInstant(wallClock, COMMUNITY_TIMEZONE);
    await page.clock.setSystemTime(at("2026-01-31T23:57"));
    await page.goto("/calendar/all/2026-01-20/");
    await expect(page.locator("h2", { hasText: "January 2026" })).toBeVisible();
    await expect(page.locator(".rbc-date-cell").first()).toHaveText("28");
    await page.evaluate(() => {
      window.__samePage = true;
    });
    // From here no timer runs until the test says so.
    await page.clock.pauseAt(at("2026-01-31T23:59"));

    await page.clock.runFor("00:59");
    await expect(page).toHaveURL(endsWith("/calendar/all/2026-01-20/"));

    await page.clock.runFor("00:03");
    await expect(page).toHaveURL(endsWith("/calendar/all/2026-02-01/"));
    await expect(
      page.locator("h2", { hasText: "February 2026" }),
    ).toBeVisible();
    // The calendar draws the new month's grid two animation frames
    // after the address changes, and those run only while the clock
    // runs. February 2026 starts on a Sunday. January's grid starts on
    // Sunday, Dec 28.
    await page.clock.runFor("00:01");
    await expect(page.locator(".rbc-date-cell").first()).toHaveText("01");
    expect(await page.evaluate(() => window.__samePage)).toBe(true);
  });

  test("disableIdleTimer turns the timer off", async ({ page }) => {
    await disableIdleTimer(page);
    await openMeal(page);
    await page.mouse.move(10, 10);

    await page.clock.fastForward("06:00");
    // With the timer on, the page leaves within a few hundred
    // milliseconds of the fast-forward (the tests above). Give it a
    // full second of real time before saying it stayed.
    await page.waitForTimeout(1000);
    await expect(page).toHaveURL(endsWith(mealPath));
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();
  });
});
