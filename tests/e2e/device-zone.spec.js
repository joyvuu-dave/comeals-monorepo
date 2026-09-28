const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");
const calendarFixture = require("../fixtures/calendar.json");

// A resident whose phone is on Central or Eastern time while the
// community is in Los Angeles (#123). On the Sunday the clocks go
// forward (Mar 8, 2026), the app read the date "2026-03-08" as 23:00 on
// Mar 7 on such a phone: the meal page said "Sat, Mar 7th" and
// "Yesterday", and a birthday that day sat on the Saturday. Every other
// browser test runs the browser in Los Angeles, where this cannot show.
const SPRING_FORWARD_NOON = new Date("2026-03-08T12:00:00-07:00");

for (const zone of ["America/Chicago", "America/New_York"]) {
  test.describe(`A phone on ${zone} time`, () => {
    test.use({ timezoneId: zone });

    test.beforeEach(async ({ page, context }) => {
      // The browser really is in that zone, or this file tests nothing.
      expect(
        await page.evaluate(
          () => Intl.DateTimeFormat().resolvedOptions().timeZone,
        ),
      ).toBe(zone);
      await setupAuthenticatedPage(page, context, {
        mealData: { ...mealFixture, date: "2026-03-08" },
        calendarData: {
          ...calendarFixture,
          month: 3,
          meals: [],
          bills: [],
          rotations: [],
          common_house_reservations: [],
          guest_room_reservations: [],
          events: [],
          birthdays: [
            {
              ...calendarFixture.birthdays[0],
              start: "2026-03-08",
              end: "2026-03-08",
            },
          ],
        },
      });
      await page.clock.setFixedTime(SPRING_FORWARD_NOON);
    });

    test("the meal on the spring-forward Sunday is on that Sunday", async ({
      page,
    }) => {
      await page.goto("/meals/42/edit/");

      await expect(
        page.getByRole("heading", { level: 2, name: /Mar \d/ }),
      ).toHaveText("Sun, Mar 8th", { timeout: 10000 });
      await expect(page.locator("h3.text-black")).toHaveText("Today");
    });

    test("a birthday on the spring-forward Sunday is on that Sunday", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-03-08/");
      const chip = page.locator(".rbc-event", { hasText: "Alice's B-day!" });
      await expect(chip).toBeVisible({ timeout: 10000 });

      // Mar 8 opens the second week of March 2026 (Sat, Mar 7 closes the
      // first). The chip must be in that week, inside the day's column.
      const dayCell = page.locator(".rbc-date-cell:not(.rbc-off-range)", {
        hasText: /^08$/,
      });
      const week = dayCell.locator(
        "xpath=ancestor::div[contains(@class, 'rbc-month-row')]",
      );
      await expect(
        week.locator(".rbc-event", { hasText: "Alice's B-day!" }),
      ).toHaveCount(1);
      const cellBox = await dayCell.boundingBox();
      const chipBox = await chip.boundingBox();
      const chipMiddle = chipBox.x + chipBox.width / 2;
      expect(chipMiddle).toBeGreaterThan(cellBox.x);
      expect(chipMiddle).toBeLessThan(cellBox.x + cellBox.width);
    });
  });
}
