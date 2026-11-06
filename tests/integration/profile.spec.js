const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/integration_setup");

// The signed-in resident's own profile (ADR 0014), against the real
// server. Each test puts back what it changed, because the tests share
// one seeded database and run one after another.
test.describe("Profile (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  async function openProfile(page) {
    await page.goto("/calendar/all/2026-01-15/");
    await page.getByRole("button", { name: "profile" }).click();
    const form = page.locator(".ReactModal__Content--after-open");
    await expect(form.locator("fieldset[data-populated]")).toBeVisible({
      timeout: 10000,
    });
    return form;
  }

  async function save(page, form) {
    const saved = page.waitForResponse(
      (response) =>
        response.url().endsWith("/api/v1/profile") &&
        response.request().method() === "PATCH",
    );
    await form.getByRole("button", { name: "Save" }).click();
    const response = await saved;
    expect(response.status()).toBe(200);
    await expect(form).toBeHidden();
  }

  test("saves the vegetarian setting", async ({ page }) => {
    let form = await openProfile(page);
    const box = form.locator("#profile-vegetarian");
    const before = await box.isChecked();

    await box.setChecked(!before);
    await save(page, form);
    await expect(page.locator(".toast--success .toast__message")).toHaveText(
      /Your profile has been saved\./,
    );

    form = await openProfile(page);
    await expect(form.locator("#profile-vegetarian")).toBeChecked({
      checked: !before,
    });
    await form.locator("#profile-vegetarian").setChecked(before);
    await save(page, form);
  });

  test("keeps the old email until the link is opened", async ({ page }) => {
    let form = await openProfile(page);
    const oldEmail = await form.locator("#profile-email").inputValue();

    await form.locator("#profile-email").fill("someone.new@test.com");
    await save(page, form);
    await expect(page.locator(".toast--success .toast__message")).toHaveText(
      "Your profile has been saved. To change your email, open the link " +
        `we sent to someone.new@test.com. Until then, sign in with ${oldEmail}.`,
    );

    form = await openProfile(page);
    await expect(form.locator("#profile-email")).toHaveValue(
      "someone.new@test.com",
    );
    await expect(form.getByText(/Not changed yet/)).toBeVisible();

    // Putting the old address back takes the change off.
    await form.locator("#profile-email").fill(oldEmail);
    await save(page, form);
    form = await openProfile(page);
    await expect(form.getByText(/Not changed yet/)).toHaveCount(0);
  });
});
