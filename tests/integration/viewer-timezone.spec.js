const dayjs = require("dayjs");
const { test, expect } = require("../helpers/test");
const { zonedInstant } = require("../helpers/zoned_time");
const {
  COMMUNITY_TIMEZONE,
  FAKE_TODAY,
  loadAuthInfo,
  authenticateContext,
  stubPusher,
  disableIdleTimer,
  gotoMeal,
} = require("../helpers/integration_setup");

// A resident whose phone is set to London. Every other browser test
// runs the browser in the community's own zone, where the browser's
// day and the community's day are always the same, so none of them
// could see the app use the wrong one.
//
// The browser's clock is 23:30 in Los Angeles on the frozen day, which
// is already 07:30 the next day in London. The community's today is
// still the frozen day, and the server agrees.
test.use({ timezoneId: "Europe/London" });

const auth = loadAuthInfo();
const today = dayjs(FAKE_TODAY);
const lateEvening = zonedInstant(`${FAKE_TODAY}T23:30`, COMMUNITY_TIMEZONE);
// "YYYY-MM-DD" in London, from Intl (en-CA writes dates that way).
const londonDay = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/London",
}).format(lateEvening);

test.describe("A viewer in another time zone (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    // The browser really is on the next day, or this file tests nothing.
    expect(londonDay).toBe(today.add(1, "day").format("YYYY-MM-DD"));
    await authenticateContext(context);
    await stubPusher(page);
    await disableIdleTimer(page);
    await page.clock.setFixedTime(lateEvening);
  });

  test("today's meal is labeled Today", async ({ page }) => {
    await gotoMeal(page, auth.meals.today.id);
    await expect(
      page.locator('[aria-label="Enter meal description"]'),
    ).toHaveValue("Pizza and salad", { timeout: 10000 });
    await expect(page.locator("h3.text-black")).toHaveText("Today");
  });

  test("an evening event sits on its community day", async ({ page }) => {
    // The seeded Community Meeting starts at 19:00 in Los Angeles on the
    // frozen day: 03:00 the next day in London.
    await page.goto(`/calendar/all/${FAKE_TODAY}/`);
    const tile = page.locator(".rbc-event", { hasText: "Community Meeting" });
    await expect(tile).toBeVisible({ timeout: 10000 });

    const dayCell = page.locator(".rbc-date-cell:not(.rbc-off-range)", {
      hasText: new RegExp(`^${today.format("DD")}$`),
    });
    const week = dayCell.locator(
      "xpath=ancestor::div[contains(@class, 'rbc-month-row')]",
    );
    await expect(
      week.locator(".rbc-event", { hasText: "Community Meeting" }),
    ).toHaveCount(1);

    const cellBox = await dayCell.boundingBox();
    const tileBox = await tile.boundingBox();
    const tileMiddle = tileBox.x + tileBox.width / 2;
    expect(tileMiddle).toBeGreaterThan(cellBox.x);
    expect(tileMiddle).toBeLessThan(cellBox.x + cellBox.width);
  });

  test("the today button goes to the community's today", async ({ page }) => {
    const lastMonth = today.subtract(1, "month").format("YYYY-MM-DD");
    await page.goto(`/calendar/all/${lastMonth}/`);
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });

    await page.getByRole("button", { name: "today" }).click();
    await expect(page).toHaveURL(new RegExp(`/calendar/all/${FAKE_TODAY}/?$`));
  });
});
