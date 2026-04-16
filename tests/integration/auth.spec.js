const { test, expect } = require("@playwright/test");
const {
  loadAuthInfo,
  stubPusher,
  disableIdleTimer,
} = require("../helpers/integration_setup");

test.describe("Authentication (real backend)", () => {
  test.beforeEach(async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
  });

  test("login page renders", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    await expect(page.locator('input[aria-label="password"]')).toBeVisible();
    await expect(page.getByRole("button", { name: "Submit" })).toBeVisible();
  });

  test("login with valid credentials redirects to calendar", async ({
    page,
  }) => {
    const auth = loadAuthInfo();

    await page.goto("/");
    await page.locator('input[aria-label="email"]').fill(auth.bob_email);
    await page.locator('input[aria-label="password"]').fill(auth.bob_password);
    await page.getByRole("button", { name: "Submit" }).click();

    // Real backend returns token, app sets cookies and redirects to calendar
    await expect(page).toHaveURL(/\/calendar\//, { timeout: 10000 });
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });
  });

  test("login with wrong password shows error", async ({ page }) => {
    const auth = loadAuthInfo();

    await page.goto("/");
    await page.locator('input[aria-label="email"]').fill(auth.bob_email);
    await page.locator('input[aria-label="password"]').fill("wrongpassword");
    await page.getByRole("button", { name: "Submit" }).click();

    const toast = page.locator(".toast--error");
    await expect(toast).toBeVisible({ timeout: 5000 });
  });

  test("login with nonexistent email shows error", async ({ page }) => {
    await page.goto("/");
    await page.locator('input[aria-label="email"]').fill("nobody@test.com");
    await page.locator('input[aria-label="password"]').fill("password");
    await page.getByRole("button", { name: "Submit" }).click();

    const toast = page.locator(".toast--error");
    await expect(toast).toBeVisible({ timeout: 5000 });
  });

  test("authenticated user can access protected meal page", async ({
    page,
    context,
  }) => {
    const { setupAuthenticatedPage } = require("../helpers/integration_setup");
    const auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);

    await page.goto(`/meals/${auth.meals.tomorrow.id}/edit/`);
    await page.waitForLoadState("networkidle");

    // Should see the meal page, not be redirected to login
    await expect(page.locator("h1")).toBeVisible({ timeout: 10000 });
    await expect(page.locator('input[aria-label="email"]')).not.toBeVisible();
  });
});
