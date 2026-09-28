const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");
const calendarFixture = require("../fixtures/calendar.json");

test.describe("Exhaustive Coverage", () => {
  test.describe("Calendar Page", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("webcal subscription links render with correct hrefs", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // "Subscribe to All Meals" link (always visible)
      const allMealsLink = page.locator("a", {
        hasText: "Subscribe to All Meals",
      });
      await expect(allMealsLink).toBeVisible();
      const allHref = await allMealsLink.getAttribute("href");
      expect(allHref).toContain("webcal://");
      expect(allHref).toContain("/communities/1/ical.ics");

      // "Subscribe to My Meals" link (visible after resident_id loaded)
      const myMealsLink = page.locator("a", {
        hasText: "Subscribe to My Meals",
      });
      await expect(myMealsLink).toBeVisible({ timeout: 5000 });
      const myHref = await myMealsLink.getAttribute("href");
      expect(myHref).toContain("webcal://");
      expect(myHref).toContain("/residents/1/ical.ics");
    });

    test("today button goes to today's date in the community's zone", async ({
      page,
      context,
    }) => {
      // The community is in Honolulu, the browser in Los Angeles (the
      // Playwright config). At this instant it is still Jan 15 in
      // Honolulu (23:30), but already Jan 16 in Los Angeles (01:30) and
      // in UTC (09:30). Only the community's zone gives Jan 15.
      // The zone reaches the page the two ways the real server sends
      // it: the login writes it to a cookie, and every month payload
      // carries it (adoptCommunityTimezone takes the payload's zone).
      await context.addCookies([
        {
          name: "timezone",
          value: "Pacific/Honolulu",
          domain: "localhost",
          path: "/",
        },
      ]);
      await page.route("**/api/v1/communities/*/calendar/*", (route) => {
        route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            ...calendarFixture,
            timezone: "Pacific/Honolulu",
          }),
        });
      });
      await page.clock.setFixedTime(new Date("2026-01-16T09:30:00Z"));

      // Start on a date far from today
      await page.goto("/calendar/all/2025-06-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });
      await expect(page.locator("h2", { hasText: "June 2025" })).toBeVisible();

      const todayButton = page.locator("button", { hasText: "today" });
      await expect(todayButton).toBeVisible();
      await todayButton.click();

      await expect(page).toHaveURL(/\/calendar\/all\/2026-01-15\/?$/, {
        timeout: 5000,
      });
      await expect(
        page.locator("h2", { hasText: "January 2026" }),
      ).toBeVisible();
    });
  });

  test.describe("Meal Page", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("close button CSS class changes from green to red", async ({
      page,
    }) => {
      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const closeButton = page.locator("text=Open / Close Meal");
      await expect(closeButton).toBeVisible({ timeout: 10000 });

      // Open meal: button should have success (green) class
      await expect(closeButton).toHaveClass(/button-success/);

      // Close the meal
      await closeButton.click();
      await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
        timeout: 5000,
      });

      // Closed meal: button should have danger (red) class
      await expect(closeButton).toHaveClass(/button-danger/, { timeout: 3000 });
    });

    test("cook select dropdown shows only can_cook residents", async ({
      page,
    }) => {
      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const cookSelect = page
        .locator('[aria-label="Select meal cook"]')
        .first();
      await expect(cookSelect).toBeVisible({ timeout: 10000 });

      // Fixture: Jane (can_cook: true), Bob (can_cook: true), Alice (can_cook: false)
      // Cook select should show Jane and Bob but NOT Alice
      const options = cookSelect.locator("option");
      const texts = await options.allTextContents();

      expect(texts).toContain("A - Jane Smith");
      expect(texts).toContain("B - Bob Johnson");
      expect(texts).not.toContain("C - Alice Williams");

      // Should also have the placeholder option
      expect(texts.some((t) => t.includes("¯\\_(ツ)_/¯"))).toBe(true);
    });

    test("date box shows the meal's date and how long ago it was", async ({
      page,
    }) => {
      // The fixture meal is on Thu 2026-01-15. Freeze "now" at
      // 2026-03-20, midday in the community's zone, so the relative
      // label has one right answer. A flipped sign would say
      // "in 2 months".
      await page.clock.setFixedTime(new Date("2026-03-20T12:00:00-07:00"));
      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      // Matched by class, not by [style*="grid-area: a1"]: the style
      // attribute holds the browser's serialization of the inline
      // styles, and WebKit expands the grid-area shorthand where
      // Chromium keeps it, so a style-substring locator only matched
      // in Chromium.
      const dateContainer = page.locator(
        "div.button-border-radius.background-yellow",
      );
      await expect(dateContainer.locator("h2")).toHaveText("Thu, Jan 15th", {
        timeout: 10000,
      });
      await expect(dateContainer.locator("h3")).toHaveText("2 months ago");
    });

    test("bill amount input refuses values that break the whole-cents grammar", async ({
      page,
    }) => {
      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const costInput = page.locator('[aria-label="Set meal cost"]').first();
      await expect(costInput).toBeVisible({ timeout: 10000 });
      await expect(costInput).toHaveValue("25.50");

      // A negative amount does not land: the field keeps its value
      await costInput.fill("-5");
      await expect(costInput).toHaveValue("25.50");

      // A sub-cent amount does not land either
      await costInput.fill("12.345");
      await expect(costInput).toHaveValue("25.50");

      // An amount over 9999.99 does not land
      await costInput.fill("10000");
      await expect(costInput).toHaveValue("25.50");

      // A valid amount lands
      await costInput.fill("10.00");
      await expect(costInput).toHaveValue("10.00");
    });

    test("guest dropdown closes when clicking outside", async ({ page }) => {
      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const janeCell = page.getByRole("cell", {
        name: "A - Jane Smith",
        exact: true,
      });
      await expect(janeCell).toBeVisible({ timeout: 10000 });
      const janeRow = janeCell.locator("xpath=ancestor::tr");

      // Open the dropdown
      const addButton = janeRow.locator(".dropdown-add");
      await addButton.click();

      // Dropdown should be open (active class)
      const dropdown = janeRow.locator(".dropdown");
      await expect(dropdown).toHaveClass(/active/, { timeout: 3000 });

      // Click somewhere else on the page (the date box area)
      await page.locator("h2").first().click();

      // Dropdown should close (no active class)
      await expect(dropdown).not.toHaveClass(/active/, { timeout: 3000 });
    });
  });

  test.describe("Form Details", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("event form time selects have correct options from generateTimes()", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Open event creation modal
      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Find the start time select
      const timeSelects = modal.locator("select");
      const firstSelect = timeSelects.first();
      await expect(firstSelect).toBeVisible();

      // Get all option texts (first may be empty default)
      const options = firstSelect.locator("option");
      const allValues = await options.allTextContents();
      const values = allValues.filter((v) => v.trim() !== "");

      // Should start at 8:00 AM
      expect(values[0]).toBe("8:00 AM");

      // Should include noon
      expect(values).toContain("12:00 PM");

      // Should end around 10:00 PM
      expect(values[values.length - 1]).toBe("10:00 PM");

      // Should have 15-minute increments
      expect(values).toContain("8:15 AM");
      expect(values).toContain("8:30 AM");
      expect(values).toContain("8:45 AM");
    });

    test("DayPickerInput shows the picked day as MM/DD/YYYY and closes", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Open event creation modal
      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // The DayPickerInput renders a readonly input, empty until a day
      // is picked.
      const dayInput = modal.locator("#event-new-day");
      await expect(dayInput).toBeVisible({ timeout: 3000 });
      await expect(dayInput).toHaveValue("");

      // Click to open the calendar overlay. It opens on the calendar's
      // month, January 2026.
      await dayInput.click();
      const overlay = modal.locator(".rdp-root");
      await expect(overlay).toBeVisible({ timeout: 3000 });

      // Pick a named day: the input shows exactly that day, and the
      // overlay closes.
      await overlay.getByRole("button", { name: /January 20/ }).click();
      await expect(dayInput).toHaveValue("01/20/2026");
      await expect(overlay).toBeHidden();
    });
  });
});
