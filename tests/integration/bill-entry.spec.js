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

  // Typing "1", pausing past the debounce, then typing "0" used to
  // produce "1.00" with the "0" swallowed: the save's ack reformatted
  // the field under the cursor, and "1.00" plus "0" breaks the
  // whole-cents grammar. The ack must not touch a field it agrees with;
  // padding happens on blur instead.
  test("typing slowly across the save debounce keeps accepting keystrokes", async ({
    page,
  }) => {
    const mealId = auth.meals.today.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    const cookSelect = page.locator('[aria-label="Select meal cook"]').first();
    await cookSelect.selectOption(String(auth.resident_id));

    // Type "1", then pause: the debounce fires and the server answers.
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    const firstSave = billSaved(page, mealId, "1");
    await costInput.press("1");
    await firstSave;

    // The ack has arrived. Give it time to hit the store, then confirm
    // the field still shows exactly what was typed.
    await page.waitForTimeout(300);
    await expect(costInput).toHaveValue("1");

    // The late "0" keystroke must land.
    const secondSave = billSaved(page, mealId, "10");
    await costInput.press("0");
    await expect(costInput).toHaveValue("10");
    await secondSave;

    // Leaving the field pads the display.
    await costInput.blur();
    await expect(costInput).toHaveValue("10.00");

    // Restore: clear the bill for the other tests.
    const cleared = billSaved(page, mealId, "0");
    await costInput.fill("0");
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

  // Turning on "no cost" over a typed cost erases the cost, so the
  // switch asks first. Every exit except a deliberate Yes — the No
  // button, Escape, a click elsewhere — must leave the cost alone.
  test("the no-cost switch asks before erasing a typed cost", async ({
    page,
  }) => {
    const mealId = auth.meals.tomorrow.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");

    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("50.00", { timeout: 10000 });

    const switchLabel = page.locator('label[for^="no_cost_switch-"]').first();
    const noCostBox = page.locator('[aria-label^="No cost button"]').first();
    const confirm = page.locator(".confirm-bar");

    // The click alone changes nothing: the bar opens and asks.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await expect(confirm).toContainText("$50.00");
    await expect(costInput).toHaveValue("50.00");
    await expect(noCostBox).not.toBeChecked();

    // No keeps everything.
    await confirm.getByRole("button", { name: "No" }).click();
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("50.00");
    await expect(noCostBox).not.toBeChecked();

    // Escape is a No too.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("50.00");

    // A click anywhere else is also a No.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await page.locator("h2", { hasText: "Cooks" }).click();
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("50.00");

    // A deliberate Yes erases the cost and flips the switch. The Yes
    // button ignores clicks while it arms, so wait that out.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await page.waitForTimeout(500);
    const erased = page.waitForResponse((r) => {
      if (r.request().method() !== "PATCH") return false;
      if (!r.url().includes(`/api/v1/meals/${mealId}/bills`)) return false;
      const body = r.request().postDataJSON();
      return body.bills.some((b) => b.no_cost === true);
    });
    await confirm.getByRole("button", { name: "Yes" }).click();
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("");
    await expect(noCostBox).toBeChecked();
    await erased;

    // Turning the switch back off never asks — it destroys nothing.
    await switchLabel.click();
    await expect(confirm).toBeHidden();
    await expect(noCostBox).not.toBeChecked();

    // Restore the seed: put Jane's $50.00 back.
    const restored = billSaved(page, mealId, "50.00");
    await costInput.fill("50.00");
    await restored;
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

  // A meal can close with a cook's cost still blank — after a Yes that
  // names the cook — and the cost can be entered on the closed meal.
  // Bills freeze at reconciliation, not at close.
  test("closing with a blank cost asks, and the cost can be entered after closing", async ({
    page,
  }) => {
    const mealId = auth.meals.today.id;
    await page.goto(`/meals/${mealId}/edit/`);
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // Make sure a cook is assigned with no cost entered.
    const cookSelect = page.locator('[aria-label="Select meal cook"]').first();
    if ((await cookSelect.inputValue()) !== String(auth.resident_id)) {
      const assigned = page.waitForResponse(
        (r) =>
          r.request().method() === "PATCH" &&
          r.url().includes(`/api/v1/meals/${mealId}/bills`),
      );
      await cookSelect.selectOption(String(auth.resident_id));
      await assigned;
    }
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("");

    // Closing asks and names the cook; No keeps the meal open.
    const closeButton = page.locator("text=Open / Close Meal");
    const confirm = page.locator(".confirm-bar");
    await closeButton.click();
    await expect(confirm).toBeVisible();
    await expect(confirm).toContainText("entered a cost yet");
    await expect(confirm).toContainText("Jane");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();
    await confirm.getByRole("button", { name: "No" }).click();
    await expect(confirm).toBeHidden();
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();

    // Yes closes the meal. Closing triggers a refetch that replaces the
    // bill rows — wait it out before typing into them.
    await closeButton.click();
    await expect(confirm).toBeVisible();
    const refetched = page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes(`/api/v1/meals/${mealId}`),
    );
    await confirm.getByRole("button", { name: "Yes" }).click();
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 5000,
    });
    await refetched;

    // The blank cost now reads "pending": the cook had the chance and
    // said later.
    await expect(costInput).toHaveAttribute("placeholder", "pending");

    // The cost field is still editable on the closed meal, and the
    // save sticks across a reload.
    await expect(costInput).toBeEnabled();
    const saved = billSaved(page, mealId, "12.00");
    await costInput.fill("12.00");
    await saved;

    await clearStorage(page);
    await page.reload();
    await page.waitForLoadState("networkidle");
    const costAfter = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costAfter).toBeEnabled({ timeout: 10000 });
    await expect(costAfter).toHaveValue("12.00");

    // Restore the seed: reopen the meal (no question in that
    // direction), wait out its refetch, then unassign the cook — the
    // server deletes a bill whose cook is left out of the payload.
    const reopened = page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes(`/api/v1/meals/${mealId}`),
    );
    await page.locator("text=Open / Close Meal").click();
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 5000,
    });
    await reopened;
    const cleared = page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes(`/api/v1/meals/${mealId}/bills`),
    );
    await page
      .locator('[aria-label="Select meal cook"]')
      .first()
      .selectOption("");
    await cleared;
  });
});
