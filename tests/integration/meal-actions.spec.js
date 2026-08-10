const { test, expect } = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
} = require("../helpers/integration_setup");

// Every meal-page action against the real backend (plan item 4).
// The pattern throughout: perform the action, wait for the write to
// land, reload the page, assert the state came back from the
// database. Tests restore what they change so the suite can run in
// any order and repeatedly against one seeding, and preconditions
// are read from the page rather than assumed, so a half-finished
// earlier run cannot poison this one.

const auth = loadAuthInfo();

test.describe("Meal actions (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  // The meal page populates from GET /cooks after mount. Interacting
  // before that response lands races the load — the arriving data
  // overwrites what the test typed — so every goto and reload arms a
  // waiter for that GET and awaits it before the test touches
  // anything.
  function armLoad(page, mealId) {
    return page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes(`/api/v1/meals/${mealId}/cooks`) &&
        r.ok(),
    );
  }

  async function gotoMeal(page, mealId) {
    const loaded = armLoad(page, mealId);
    await page.goto(`/meals/${mealId}/edit/`);
    await loaded;
  }

  async function reloadMeal(page, mealId) {
    const loaded = armLoad(page, mealId);
    await page.reload();
    await loaded;
  }

  // Waits for a PATCH to this meal's endpoint to succeed.
  function patched(page, mealId, pathPart) {
    return page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes(`/api/v1/meals/${mealId}/${pathPart}`) &&
        r.ok(),
    );
  }

  test("veg toggle persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    const residentId = auth.resident_id; // Jane attends today's meal
    await gotoMeal(page, mealId);
    const vegSwitch = page.locator(`#veg_switch_${residentId}`);
    await expect(vegSwitch).toBeVisible({ timeout: 10000 });
    const wasChecked = await vegSwitch.isChecked();

    let saved = patched(page, mealId, "residents");
    await page.locator(`label[for="veg_switch_${residentId}"]`).click();
    await saved;

    await reloadMeal(page, mealId);
    await expect(vegSwitch).toBeChecked({
      checked: !wasChecked,
      timeout: 10000,
    });

    // Restore.
    saved = patched(page, mealId, "residents");
    await page.locator(`label[for="veg_switch_${residentId}"]`).click();
    await saved;
    await reloadMeal(page, mealId);
    await expect(vegSwitch).toBeChecked({
      checked: wasChecked,
      timeout: 10000,
    });
  });

  test("removing a guest persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    const janeRow = page
      .getByRole("cell", { name: "A - Jane Smith", exact: true })
      .locator("xpath=ancestor::tr");
    await expect(janeRow).toBeVisible({ timeout: 10000 });
    const initialBadges = await janeRow.locator(".badge img").count();

    // Add a guest, then remove it — covers the remove path without
    // touching the seeded guest other tests count.
    const added = page.waitForResponse(
      (r) =>
        r.request().method() === "POST" &&
        r.url().includes("/guests") &&
        r.ok(),
    );
    await janeRow.locator(".dropdown-add").click();
    const dropdownMenu = janeRow.locator(".dropdown-menu");
    await expect(dropdownMenu).toBeVisible({ timeout: 3000 });
    await dropdownMenu.locator("img[alt='cow-icon']").click();
    await added;
    await reloadMeal(page, mealId);
    await expect
      .poll(() => janeRow.locator(".badge img").count(), { timeout: 10000 })
      .toBe(initialBadges + 1);

    const removed = page.waitForResponse(
      (r) =>
        r.request().method() === "DELETE" &&
        r.url().includes("/guests") &&
        r.ok(),
    );
    await janeRow
      .locator('[aria-label="Remove Guest of A - Jane Smith"]')
      .click();
    await removed;
    await reloadMeal(page, mealId);
    await expect
      .poll(() => janeRow.locator(".badge img").count(), { timeout: 10000 })
      .toBe(initialBadges);
  });

  test("selecting a cook persists across reload", async ({ page }) => {
    const mealId = auth.meals.tomorrow.id;
    await gotoMeal(page, mealId);
    const cookSelects = page.locator('[aria-label="Select meal cook"]');
    await expect(cookSelects.first()).toBeVisible({ timeout: 10000 });

    // Slot 2 is empty (slot 1 is Jane, who holds the seeded bill).
    // Option labels carry the unit prefix, so match by substring and
    // select by value.
    const secondSlot = cookSelects.nth(1);
    const bobValue = await secondSlot.evaluate((s) => {
      const option = Array.from(s.options).find((o) =>
        o.textContent.includes("Bob Johnson"),
      );
      return option && option.value;
    });
    expect(bobValue).toBeTruthy();

    let saved = patched(page, mealId, "bills");
    await secondSlot.selectOption(bobValue);
    await saved;

    await reloadMeal(page, mealId);
    await expect(cookSelects.nth(1)).toHaveValue(bobValue, { timeout: 10000 });

    // Restore the empty slot.
    saved = patched(page, mealId, "bills");
    await cookSelects.nth(1).selectOption({ index: 0 });
    await saved;
    await reloadMeal(page, mealId);
    await expect(cookSelects.nth(1)).not.toHaveValue(bobValue, {
      timeout: 10000,
    });
  });

  test("meal description edit persists across reload", async ({ page }) => {
    const mealId = auth.meals.future.id;
    await gotoMeal(page, mealId);
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toBeVisible({ timeout: 10000 });

    let saved = patched(page, mealId, "description");
    await textarea.fill("Soup and fresh bread");
    await saved;

    await reloadMeal(page, mealId);
    await expect(textarea).toHaveValue("Soup and fresh bread", {
      timeout: 10000,
    });

    // Restore the blank description the seed gives this meal.
    saved = patched(page, mealId, "description");
    await textarea.fill("");
    await saved;
    await reloadMeal(page, mealId);
    await expect(textarea).toHaveValue("", { timeout: 10000 });
  });

  test("closing and reopening a meal persists across reload", async ({
    page,
  }) => {
    const mealId = auth.meals.close_test.id;
    await gotoMeal(page, mealId);
    await expect(page.locator("text=OPEN").first()).toBeVisible({
      timeout: 10000,
    });

    // Close. The seeded cook cost means no blank-cost question
    // (bill-entry.spec.js owns that flow). Closing triggers a refetch
    // of /cooks; await it so the reload cannot cancel it mid-flight
    // (WebKit logs a cancelled request as a console error).
    let refetched = armLoad(page, mealId);
    let saved = patched(page, mealId, "closed");
    await page.locator("text=Open / Close Meal").click();
    await saved;
    await refetched;
    await reloadMeal(page, mealId);
    await expect(page.locator("text=CLOSED").first()).toBeVisible({
      timeout: 10000,
    });

    // Reopen.
    refetched = armLoad(page, mealId);
    saved = patched(page, mealId, "closed");
    await page.locator("text=Open / Close Meal").click();
    await saved;
    await refetched;
    await reloadMeal(page, mealId);
    await expect(page.locator("text=OPEN").first()).toBeVisible({
      timeout: 10000,
    });
  });

  test("setting extras on a closed meal persists across reload", async ({
    page,
  }) => {
    const mealId = auth.meals.closed.id;
    await gotoMeal(page, mealId);
    const extrasBoxes = page.locator('[aria-label^="Set Extras to"]');
    await expect(extrasBoxes.first()).toBeVisible({ timeout: 10000 });

    // Read the current value instead of assuming it, pick a different
    // one, and restore at the end. An extras save also refetches
    // /cooks; await it before reloading (same WebKit concern as the
    // close test).
    const before = await extrasBoxes.evaluateAll(
      (boxes) => (boxes.find((b) => b.checked) || {}).value,
    );
    const target = before === "2" ? "3" : "2";
    const targetBox = page.locator(`[aria-label="Set Extras to ${target}"]`);

    let refetched = armLoad(page, mealId);
    let saved = patched(page, mealId, "max");
    await targetBox.click();
    await saved;
    await refetched;
    await reloadMeal(page, mealId);
    await expect(targetBox).toBeChecked({ timeout: 10000 });

    if (before !== undefined) {
      refetched = armLoad(page, mealId);
      saved = patched(page, mealId, "max");
      await page.locator(`[aria-label="Set Extras to ${before}"]`).click();
      await saved;
      await refetched;
      await reloadMeal(page, mealId);
      await expect(
        page.locator(`[aria-label="Set Extras to ${before}"]`),
      ).toBeChecked({ timeout: 10000 });
    }
  });

  test("history modal opens with real data", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    const historyButton = page.locator("text=history").first();
    await expect(historyButton).toBeVisible({ timeout: 10000 });
    await historyButton.click();

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    // The seeded past meals give the history real rows; the strict
    // console-error fixture fails this test if the fetch blew up.
    await expect(modal.locator("table, ul, li").first()).toBeVisible({
      timeout: 10000,
    });
  });

  test("webcal subscribe links carry the community and resident", async ({
    page,
  }) => {
    await page.goto(`/calendar/all/${auth.meals.today.date}/`);
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });

    const links = page.locator('a[href^="webcal://"]');
    await expect(links).toHaveCount(2);
    const hrefs = await links.evaluateAll((as) => as.map((a) => a.href));
    expect(hrefs.some((h) => h.includes(`/communities/`))).toBe(true);
    expect(
      hrefs.some((h) => h.includes(`/residents/${auth.resident_id}/ical.ics`)),
    ).toBe(true);
  });
});
