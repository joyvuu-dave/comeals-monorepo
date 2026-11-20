const { test, expect } = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  gotoMeal,
} = require("../helpers/integration_setup");

// A person types a cost one key at a time, the way a phone keyboard
// sends it. Every half-typed state ("12.", ".") must stay on screen
// until the next key, or a cost with cents cannot be typed at all.
test.describe("Typing a cost one key at a time", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  for (const [typed, shown] of [
    ["12.50", "12.50"],
    ["12.5", "12.50"],
    [".75", "0.75"],
    ["7.", "7.00"],
  ]) {
    test(`typing ${typed} shows ${shown} after leaving the field`, async ({
      page,
    }) => {
      await gotoMeal(page, auth.meals.today.id);
      await page
        .locator('[aria-label="Select meal cook"]')
        .first()
        .selectOption(String(auth.resident_id));
      const cost = page.locator('[aria-label="Set meal cost"]').first();
      await cost.fill("");
      await cost.click();
      await cost.pressSequentially(typed, { delay: 50 });
      await expect(cost).toHaveValue(typed);
      await cost.blur();
      await expect(cost).toHaveValue(shown);

      // Put the meal back the way the seed made it.
      const cleared = page.waitForResponse(
        (r) =>
          r.request().method() === "PATCH" &&
          r.url().includes("/bills") &&
          r
            .request()
            .postDataJSON()
            .edits.some((e) => /^0*(\.0*)?$/.test(e.to?.amount ?? "x")),
      );
      await cost.fill("0");
      await cost.blur();
      await cleared;
    });
  }
});
