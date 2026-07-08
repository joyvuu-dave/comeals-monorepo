const { test, expect } = require("@playwright/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  clearStorage,
} = require("../helpers/integration_setup");

test.describe("Bill entry (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  // Bill saves are debounced, and picking a cook schedules a save of its
  // own. Waiting on the PATCH response whose request carried the typed
  // amount is the deterministic way to know that value reached the server.
  function billSaved(page, mealId, amount) {
    return page.waitForResponse((r) => {
      if (r.request().method() !== "PATCH") return false;
      if (!r.url().includes(`/api/v1/meals/${mealId}/bills`)) return false;
      const body = r.request().postDataJSON();
      return body.bills.some((b) => b.amount === amount);
    });
  }

  test("entering a bill amount persists across reload", async ({ page }) => {
    // Today's meal has no bills in the seed data
    const mealId = auth.meals.today.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // Select Jane as cook (use her resident_id as the option value)
    const cookSelect = page.locator('[aria-label="Select meal cook"]').first();
    await cookSelect.selectOption(String(auth.resident_id));

    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    const saved = billSaved(page, mealId, "65.00");
    await costInput.fill("65.00");
    await saved;

    // Reload and verify bill persisted
    await clearStorage(page);
    await page.reload();
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1")).toBeVisible({ timeout: 10000 });

    const costInputAfter = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInputAfter).toHaveValue("65.00", { timeout: 10000 });

    // Restore: clear the bill by setting amount to 0
    const cleared = billSaved(page, mealId, "0");
    await costInputAfter.fill("0");
    await cleared;
  });

  test("existing bill on tomorrow's meal shows correct amount", async ({
    page,
  }) => {
    // Tomorrow's meal has Jane's $50.00 bill from the seed
    const mealId = auth.meals.tomorrow.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");

    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("50.00", { timeout: 10000 });
  });

  test("modifying an existing bill persists", async ({ page }) => {
    const mealId = auth.meals.tomorrow.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");

    // Change Jane's bill from $50.00 to $55.00
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("50.00", { timeout: 10000 });
    const saved = billSaved(page, mealId, "55.00");
    await costInput.fill("55.00");
    await saved;

    // Reload and verify
    await clearStorage(page);
    await page.reload();
    await page.waitForLoadState("networkidle");

    const costInputAfter = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInputAfter).toHaveValue("55.00", { timeout: 10000 });

    // Restore: put it back to $50.00
    const restored = billSaved(page, mealId, "50.00");
    await costInputAfter.fill("50.00");
    await restored;
  });
});
