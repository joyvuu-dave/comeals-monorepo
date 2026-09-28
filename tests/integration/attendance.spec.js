const { test, expect } = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  gotoMeal,
  reloadMeal,
  mealWritten,
} = require("../helpers/integration_setup");

// Attendance writes against the real backend. Each test reads the
// starting state from the page, changes it, proves the change came
// back from the server after a reload, then puts it back and proves
// that too. So a test that fails half way leaves nothing behind that
// the next browser project could trip on. Adding and removing a guest
// is in meal-actions.spec.js.

const auth = loadAuthInfo();

test.describe("Attendance (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  test("toggle attendance persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);

    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCell).toBeVisible({ timeout: 10000 });
    // The seed leaves Bob off today's meal. Read it anyway, so the
    // test works from whatever state it finds.
    const wasAttending = /background-green/.test(
      (await bobCell.getAttribute("class")) || "",
    );

    // A sign-up is a POST, a removal a DELETE.
    let saved = mealWritten(
      page,
      mealId,
      wasAttending ? "DELETE" : "POST",
      "residents/",
    );
    await bobCell.click();
    await saved;
    await reloadMeal(page, mealId);
    if (wasAttending) {
      await expect(bobCell).not.toHaveClass(/background-green/);
    } else {
      await expect(bobCell).toHaveClass(/background-green/);
    }

    // Restore, and prove the restore reached the server too.
    saved = mealWritten(
      page,
      mealId,
      wasAttending ? "POST" : "DELETE",
      "residents/",
    );
    await bobCell.click();
    await saved;
    await reloadMeal(page, mealId);
    if (wasAttending) {
      await expect(bobCell).toHaveClass(/background-green/);
    } else {
      await expect(bobCell).not.toHaveClass(/background-green/);
    }
  });

  test("toggling late flag persists across reload", async ({ page }) => {
    const mealId = auth.meals.tomorrow.id;
    await gotoMeal(page, mealId);

    const aliceCell = page.getByRole("cell", {
      name: "C - Alice Williams",
      exact: true,
    });
    // Alice attends tomorrow's meal in the seed. For someone who does
    // not, the late switch signs them up (a POST), which is not what
    // this test is about.
    await expect(aliceCell).toHaveClass(/background-green/, {
      timeout: 10000,
    });
    const aliceRow = aliceCell.locator("xpath=ancestor::tr");
    const lateSwitch = aliceRow.locator('[id^="late_switch_"]');
    // The visible click target is the <label>, not the hidden <input>.
    const lateLabel = aliceRow.locator('label[for^="late_switch_"]');
    // She is not late in the seed. Read it anyway, so the test works
    // from whatever state it finds.
    const wasLate = await lateSwitch.isChecked();

    let saved = mealWritten(page, mealId, "PATCH", "residents/");
    await lateLabel.click();
    await saved;
    await reloadMeal(page, mealId);
    await expect(lateSwitch).toBeChecked({ checked: !wasLate });

    saved = mealWritten(page, mealId, "PATCH", "residents/");
    await lateLabel.click();
    await saved;
    await reloadMeal(page, mealId);
    await expect(lateSwitch).toBeChecked({ checked: wasLate });
  });
});
