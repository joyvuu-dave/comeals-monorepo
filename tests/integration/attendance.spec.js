const { test, expect } = require("@playwright/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  clearStorage,
} = require("../helpers/integration_setup");

test.describe("Attendance (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  test("toggle attendance persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");

    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCell).toBeVisible({ timeout: 10000 });

    // Before: Bob is NOT attending today's meal (per seed data)
    await expect(bobCell).not.toHaveClass(/background-green/);

    // Toggle Bob ON
    await bobCell.click();
    await expect(bobCell).toHaveClass(/background-green/, { timeout: 5000 });

    // Wait for the API call to complete
    await page.waitForTimeout(500);

    // Reload and clear cache to force fresh fetch from backend
    await clearStorage(page);
    await page.reload();
    await page.waitForLoadState("networkidle");

    // Bob should STILL be attending after reload (change persisted)
    const bobCellAfter = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCellAfter).toHaveClass(/background-green/, {
      timeout: 10000,
    });

    // Restore: toggle Bob OFF
    await bobCellAfter.click();
    await expect(bobCellAfter).not.toHaveClass(/background-green/, {
      timeout: 5000,
    });
    await page.waitForTimeout(500);
  });

  test("adding a guest persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");

    // Jane is attending today's meal
    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });
    await expect(janeCell).toHaveClass(/background-green/);

    const janeRow = janeCell.locator("xpath=ancestor::tr");

    // Count initial guest badges
    const initialBadges = await janeRow.locator(".badge img").count();

    // Add a non-vegetarian guest
    await janeRow.locator(".dropdown-add").click();
    const dropdownMenu = janeRow.locator(".dropdown-menu");
    await expect(dropdownMenu).toBeVisible({ timeout: 3000 });
    await dropdownMenu.locator("img[alt='cow-icon']").click();

    // Wait for API
    await page.waitForTimeout(500);

    // Reload and verify guest persisted
    await clearStorage(page);
    await page.reload();
    await page.waitForLoadState("networkidle");

    const janeRowAfter = page
      .getByRole("cell", { name: "A - Jane Smith", exact: true })
      .locator("xpath=ancestor::tr");
    const newBadges = await janeRowAfter.locator(".badge img").count();
    expect(newBadges).toBe(initialBadges + 1);

    // Restore: remove the guest we just added
    const removeButton = janeRowAfter.locator(
      '[aria-label="Remove Guest of A - Jane Smith"]',
    );
    if (await removeButton.isEnabled()) {
      await removeButton.click();
      await page.waitForTimeout(500);
    }
  });

  test("toggling late flag persists across reload", async ({ page }) => {
    const mealId = auth.meals.tomorrow.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");

    // Find Alice's row and her late switch
    const aliceCell = page.getByRole("cell", {
      name: "C - Alice Williams",
      exact: true,
    });
    await expect(aliceCell).toBeVisible({ timeout: 10000 });

    const aliceRow = aliceCell.locator("xpath=ancestor::tr");
    const lateSwitch = aliceRow.locator('[id^="late_switch_"]');
    // The visible click target is the <label>, not the hidden <input>
    const lateLabel = aliceRow.locator('label[for^="late_switch_"]');

    // Alice is NOT late by default
    await expect(lateSwitch).not.toBeChecked();

    // Toggle late ON by clicking the label
    await lateLabel.click();
    await expect(lateSwitch).toBeChecked({ timeout: 3000 });
    await page.waitForTimeout(500);

    // Reload and verify
    await clearStorage(page);
    await page.reload();
    await page.waitForLoadState("networkidle");

    const aliceRowAfter = page
      .getByRole("cell", { name: "C - Alice Williams", exact: true })
      .locator("xpath=ancestor::tr");
    const lateSwitchAfter = aliceRowAfter.locator('[id^="late_switch_"]');
    await expect(lateSwitchAfter).toBeChecked({ timeout: 10000 });

    // Restore: toggle late OFF
    const lateLabelAfter = aliceRowAfter.locator('label[for^="late_switch_"]');
    await lateLabelAfter.click();
    await page.waitForTimeout(500);
  });
});
