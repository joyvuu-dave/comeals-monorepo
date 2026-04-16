const { test, expect } = require("@playwright/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
} = require("../helpers/integration_setup");

test.describe("Calendar (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  test("current month calendar loads with real meal data", async ({
    page,
  }) => {
    const today = new Date().toISOString().split("T")[0];
    await page.goto(`/calendar/all/${today}/`);
    await page.waitForLoadState("networkidle");

    // Calendar renders
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Today's meal should appear (as a cook event or meal entry)
    // Meals without cooks show "Meal: Open", meals with cooks show "Meal: Cook Name"
    // Today's meal has no bills, so it should show as "Meal: Open" or similar
    const calendarEvents = page.locator(".rbc-event");
    await expect(calendarEvents.first()).toBeVisible({ timeout: 10000 });
  });

  test("community event appears on calendar", async ({ page }) => {
    const today = new Date().toISOString().split("T")[0];
    await page.goto(`/calendar/all/${today}/`);
    await page.waitForLoadState("networkidle");

    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // The seeded "Community Meeting" event should be visible
    await expect(page.locator("text=Community Meeting")).toBeVisible({
      timeout: 10000,
    });
  });

  test("Next Meal button navigates to meal edit page", async ({ page }) => {
    const today = new Date().toISOString().split("T")[0];
    await page.goto(`/calendar/all/${today}/`);
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Click "Next Meal" in sidebar
    await page.locator("text=Next Meal").click();

    // Should navigate to a meal edit page with a real meal ID
    await expect(page).toHaveURL(/\/meals\/\d+\/edit\//, { timeout: 10000 });

    // The meal page should load real data (not error)
    await expect(page.locator("h1")).toBeVisible({ timeout: 10000 });
  });

  test("month navigation works", async ({ page }) => {
    const today = new Date().toISOString().split("T")[0];
    await page.goto(`/calendar/all/${today}/`);
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Navigate to next month
    await page.locator('[aria-label="Goto Next Month"]').click();
    await page.waitForLoadState("networkidle");

    // Calendar should still render (real API returns data for next month)
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Navigate back
    await page.locator('[aria-label="Goto Last Month"]').click();
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });
  });
});
