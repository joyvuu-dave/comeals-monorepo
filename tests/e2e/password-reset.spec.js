const { test, expect } = require("@playwright/test");
const { stubPusher, disableIdleTimer, mockApi } = require("../helpers/setup");

test.describe("Password Reset", () => {
  test.beforeEach(async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
  });

  test("request password reset sends POST with email from login form", async ({
    page,
  }) => {
    let resetPayload = null;
    let resetMethod = null;
    await page.route("**/api/v1/residents/password-reset", (route) => {
      resetMethod = route.request().method();
      if (resetMethod === "POST") {
        resetPayload = route.request().postDataJSON();
      }
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Password reset email sent." }),
      });
    });

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // Fill in the email on the login form, then click Reset your password
    await page.locator("#login-email").fill("jane@example.com");
    await page.getByRole("button", { name: "Reset your password" }).click();

    // API: POST with email
    await expect.poll(() => resetPayload, { timeout: 5000 }).toBeTruthy();
    expect(resetMethod).toBe("POST");
    expect(resetPayload.email).toBe("jane@example.com");

    // Success toast
    const toast = page.locator(".toast--success");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast.locator(".toast__message")).toContainText(
      "Password reset email sent",
    );
  });

  test("reset button with empty email shows error toast and does not POST", async ({
    page,
  }) => {
    let resetRequested = false;
    await page.route("**/api/v1/residents/password-reset", (route) => {
      if (route.request().method() === "POST") {
        resetRequested = true;
      }
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Password reset email sent." }),
      });
    });

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    await page.getByRole("button", { name: "Reset your password" }).click();

    const toast = page.locator(".toast--error");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast.locator(".toast__message")).toContainText(
      "Email required",
    );
    expect(resetRequested).toBe(false);
  });

  test("set new password sends POST with password", async ({ page }) => {
    let passwordPayload = null;
    let passwordMethod = null;
    let passwordUrl = null;
    await page.route("**/api/v1/residents/password-reset/*", (route) => {
      passwordMethod = route.request().method();
      passwordUrl = route.request().url();
      if (passwordMethod === "POST") {
        passwordPayload = route.request().postDataJSON();
      }
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Password updated successfully." }),
      });
    });

    await page.goto("/reset-password/test-reset-token/");
    await page.waitForLoadState("networkidle");

    // The modal should open with the password form
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });

    // Fill in new password
    const passwordInput = modal.locator('input[type="password"]');
    await expect(passwordInput).toBeVisible({ timeout: 5000 });
    await passwordInput.fill("newpassword123");

    // Submit
    await modal.getByRole("button", { name: "Submit" }).click();

    // API: POST to /residents/password-reset/{token} with password
    await expect.poll(() => passwordPayload, { timeout: 5000 }).toBeTruthy();
    expect(passwordMethod).toBe("POST");
    expect(passwordPayload.password).toBe("newpassword123");
    expect(passwordUrl).toContain("test-reset-token");

    // Success toast
    const toast = page.locator(".toast--success");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast.locator(".toast__message")).toContainText(
      "Password updated",
    );
  });
});
