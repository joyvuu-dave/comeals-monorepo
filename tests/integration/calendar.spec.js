const dayjs = require("dayjs");
const { test, expect } = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  FAKE_TODAY,
} = require("../helpers/integration_setup");

const auth = loadAuthInfo();

// A meal's calendar tile, by its exact text. MealSerializer#title
// makes it "Dinner", a line break, and the head count (residents plus
// guests) with a word the server picks by comparing the meal's date
// with its own today: "attending" for today's meal, "signed up" for a
// later one, "attended" for an earlier one. So an exact tile also
// checks that the server and the seed agree on which day is today.
function mealTile(page, countAndWord) {
  return page.locator(".rbc-event", {
    hasText: new RegExp(`^Dinner\\s*${countAndWord}$`),
  });
}

function calendarUrl(date) {
  return new RegExp(`/calendar/all/${date.format("YYYY-MM-DD")}/?$`);
}

test.describe("Calendar (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  async function openCalendar(page) {
    await page.goto(`/calendar/all/${FAKE_TODAY}/`);
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });
  }

  test("current month calendar loads with real meal data", async ({ page }) => {
    await openCalendar(page);

    // Today: Jane and Alice. Tomorrow: Jane, Bob, Alice and Jane's
    // guest. Two days ago: Bob, Alice and Charlie.
    await expect(mealTile(page, "2 attending")).toBeVisible({
      timeout: 10000,
    });
    await expect(mealTile(page, "4 signed up")).toBeVisible();
    await expect(mealTile(page, "3 attended")).toBeVisible();
  });

  test("community event appears on calendar", async ({ page }) => {
    await openCalendar(page);

    // The seeded "Community Meeting" event should be visible
    await expect(page.locator("text=Community Meeting")).toBeVisible({
      timeout: 10000,
    });
  });

  test("Next Meal button opens today's meal", async ({ page }) => {
    await openCalendar(page);

    // The server's next meal is the first one dated on or after its
    // today, so a meal dated today counts. The seed has meals two days
    // ago, today and tomorrow, one on each side of that rule.
    await page.locator("text=Next Meal").click();
    await expect(page).toHaveURL(
      new RegExp(`/meals/${auth.meals.today.id}/edit/?$`),
      { timeout: 10000 },
    );
    await expect(
      page.locator('[aria-label="Enter meal description"]'),
    ).toHaveValue("Pizza and salad", { timeout: 10000 });
  });

  test("month navigation works", async ({ page }) => {
    const thisMonth = dayjs(FAKE_TODAY);
    const nextMonth = thisMonth.add(1, "month");
    const heading = page.locator("h2");
    await openCalendar(page);
    await expect(heading).toHaveText(thisMonth.format("MMMM YYYY"));

    await page.locator('[aria-label="Goto Next Month"]').click();
    await expect(page).toHaveURL(calendarUrl(nextMonth));
    await expect(heading).toHaveText(nextMonth.format("MMMM YYYY"));
    // The seed puts the first rotation's one meal 40 days after today,
    // which is next month from the suite's frozen day. Its tile shows
    // that the real API sent next month's data.
    await expect(mealTile(page, "0 signed up")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator("text=Community Meeting")).toHaveCount(0);

    await page.locator('[aria-label="Goto Last Month"]').click();
    await expect(page).toHaveURL(calendarUrl(thisMonth));
    await expect(heading).toHaveText(thisMonth.format("MMMM YYYY"));
    await expect(page.locator("text=Community Meeting")).toBeVisible({
      timeout: 10000,
    });
    await expect(mealTile(page, "2 attending")).toBeVisible();
  });
});
