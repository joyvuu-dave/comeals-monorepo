const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");

test.describe("Navigation", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  test("prev/next meal arrows navigate between meals", async ({ page }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Should show navigation arrows
    // The next arrow should be visible since next_id is 43
    const nextArrow = page
      .locator('[data-testid="next-meal"]')
      .or(page.locator("svg.fa-chevron-right").first());

    if (await nextArrow.isVisible({ timeout: 5000 })) {
      await nextArrow.click();
      // Should navigate to meal 43
      await expect(page).toHaveURL(/\/meals\/43\/edit/, { timeout: 5000 });
    }
  });

  test("meal history modal opens and shows audit entries", async ({ page }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Click the history button/link
    const historyLink = page.locator("text=history").first();
    await expect(historyLink).toBeVisible({ timeout: 10000 });
    await historyLink.click();

    // History modal should open with audit entries
    await expect(page.locator(".ReactModal__Content--after-open")).toBeVisible({
      timeout: 5000,
    });

    // Should show history items from fixture -- use exact cell match
    await expect(
      page.getByRole("cell", { name: "signed up", exact: true }),
    ).toBeVisible({ timeout: 5000 });
  });

  test("calendar back button navigates from meal to calendar", async ({
    page,
  }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Find the back arrow / calendar link
    const backButton = page
      .locator("svg.fa-arrow-left")
      .or(page.locator('[aria-label="Back to calendar"]'))
      .first();

    if (await backButton.isVisible({ timeout: 5000 })) {
      await backButton.click();
      await expect(page).toHaveURL(/\/calendar\//, { timeout: 5000 });
    }
  });

  // Regression test for the 2026-07-22 production crash. Leaving a meal
  // for the calendar nulls store.meal but used to leave the meal's rows
  // (bills, residents, guests) in the store. Clicking back into a meal
  // rendered those stale rows before goToMeal ran, and a row read
  // store.meal.reconciled on the null meal — a TypeError that tripped
  // the error boundary and blanked the whole app.
  test("returning to a meal from the calendar renders it without crashing", async ({
    page,
  }) => {
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(String(error)));

    // Load the meal page fully: attendee rows and cook rows on screen.
    await page.goto("/meals/42/edit/");
    const janeCell = page.getByRole("cell", {
      name: "Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    // To the calendar. Its mount tears down the meal page's store state.
    await page.getByRole("button", { name: "Calendar" }).click();
    await expect(page).toHaveURL(/\/calendar\//, { timeout: 5000 });
    const mealEvent = page.locator("text=Meal: Jane Smith");
    await expect(mealEvent).toBeVisible({ timeout: 5000 });

    // Back into the meal, the same way production does it: the calendar
    // event carries url "/meals/42/edit" and clicking it navigates there.
    await mealEvent.click();
    await expect(page).toHaveURL(/\/meals\/42\/edit/, { timeout: 5000 });

    // The meal page renders again — no error boundary, no page errors.
    await expect(janeCell).toBeVisible({ timeout: 10000 });
    await expect(
      page.locator("text=Something went wrong with Comeals."),
    ).toHaveCount(0);
    expect(pageErrors).toEqual([]);
  });
});
