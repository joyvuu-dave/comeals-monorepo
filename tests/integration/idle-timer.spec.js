const { test, expect } = require("../helpers/test");
const {
  FAKE_NOW,
  FAKE_TODAY,
  loadAuthInfo,
  authenticateContext,
  stubPusher,
  disableIdleTimer,
} = require("../helpers/integration_setup");

// The idle timer in app/frontend/index.html. Five minutes after the
// last mouse, key, scroll or touch event, it sends the page to "/", and
// "/" sends a signed-in resident to today's calendar. So a screen
// someone walked away from goes back to the calendar. The first event
// starts the timer, which is why each test moves the mouse first.
//
// Every other browser test turns the timer off with disableIdleTimer.
// These tests check the timer itself, and that the helper really turns
// it off (#118: the old helper did not).

const auth = loadAuthInfo();
const mealPath = `/meals/${auth.meals.today.id}/edit/`;
const calendarPath = `/calendar/all/${FAKE_TODAY}/`;

// A path, as a RegExp for toHaveURL, anchored at the end.
function endsWith(path) {
  return new RegExp(`${path.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}$`);
}

test.describe("Idle timer (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    // install, not setFixedTime: fastForward runs the page's timers
    // only on an installed clock.
    await page.clock.install({ time: FAKE_NOW });
    await authenticateContext(context);
    await stubPusher(page);
  });

  async function openMeal(page) {
    const loaded = page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes(`/api/v1/meals/${auth.meals.today.id}/cooks`) &&
        r.ok(),
    );
    await page.goto(mealPath);
    await loaded;
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();
  }

  test("sends a page home after five minutes with no activity", async ({
    page,
  }) => {
    await openMeal(page);
    await page.mouse.move(10, 10);

    await page.clock.fastForward("04:59");
    await expect(page).toHaveURL(endsWith(mealPath));

    await page.clock.fastForward("00:02");
    await expect(page).toHaveURL(endsWith(calendarPath));
  });

  test("a key press starts the five minutes again", async ({ page }) => {
    await openMeal(page);
    await page.mouse.move(10, 10);
    await page.clock.fastForward("04:00");
    await page.keyboard.press("a");

    // 8 minutes since the first move, but only 4 since the key press.
    await page.clock.fastForward("04:00");
    await expect(page).toHaveURL(endsWith(mealPath));

    await page.clock.fastForward("01:01");
    await expect(page).toHaveURL(endsWith(calendarPath));
  });

  test("a modifier key alone is not activity", async ({ page }) => {
    await openMeal(page);
    await page.mouse.move(10, 10);
    await page.clock.fastForward("04:00");
    await page.keyboard.press("Shift");

    await page.clock.fastForward("01:01");
    await expect(page).toHaveURL(endsWith(calendarPath));
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
