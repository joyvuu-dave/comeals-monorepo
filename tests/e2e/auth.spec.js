const { test, expect, httpFailurePattern } = require("../helpers/test");
const { stubPusher, disableIdleTimer, mockApi } = require("../helpers/setup");

test.describe("Authentication", () => {
  test.beforeEach(async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
  });

  test("login page renders with email and password fields", async ({
    page,
  }) => {
    await page.goto("/");
    await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    await expect(page.locator('input[aria-label="password"]')).toBeVisible();
    await expect(page.getByRole("button", { name: "Submit" })).toBeVisible();
  });

  test("successful login sends POST with credentials", async ({ page }) => {
    let loginPayload = null;
    let loginMethod = null;
    await page.route("**/api/v1/residents/token", (route) => {
      loginMethod = route.request().method();
      if (loginMethod === "POST") {
        loginPayload = route.request().postDataJSON();
      }
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          token: "test-token-abc123",
          community_id: 1,
          resident_id: 1,
          username: "Jane Smith",
        }),
      });
    });

    await page.goto("/");
    await page.locator('input[aria-label="email"]').fill("jane@example.com");
    await page.locator('input[aria-label="password"]').fill("password123");

    // Login sets cookies and navigates via React Router
    await page.getByRole("button", { name: "Submit" }).click();
    await page.waitForURL("**/calendar/**");

    // API: POST to /residents/token with email and password
    expect(loginMethod).toBe("POST");
    expect(loginPayload.email).toBe("jane@example.com");
    expect(loginPayload.password).toBe("password123");

    // No error toasts
    await expect(page.locator(".toast--error")).not.toBeVisible();
  });

  test.describe("with a failing login endpoint", () => {
    // The mocked 400 makes the browser log a request failure. The
    // server's message goes to a toast, not to the console, because the
    // login calls handleAxiosError without silent.
    test.use({ allowedConsoleErrors: httpFailurePattern });

    test("login with a wrong password shows the server's message and no signed-out banner", async ({
      page,
    }) => {
      // What ResidentsController#token really answers for a wrong
      // password: 400, not 401. A 401 would also raise the "signed out"
      // banner (the axios interceptor in data_store_app.js), which a
      // real failed login never does.
      await page.route("**/api/v1/residents/token", (route) => {
        route.fulfill({
          status: 400,
          contentType: "application/json",
          body: JSON.stringify({ message: "Incorrect password" }),
        });
      });

      await page.goto("/");
      await page.locator('input[aria-label="email"]').fill("jane@example.com");
      await page.locator('input[aria-label="password"]').fill("wrongpass");
      await page.getByRole("button", { name: "Submit" }).click();

      const toast = page.locator(".toast--error");
      await expect(toast).toBeVisible({ timeout: 5000 });
      await expect(toast.locator(".toast__message")).toHaveText(
        "Incorrect password",
      );
      await expect(
        page.getByText("Heads up — you've been signed out."),
      ).toHaveCount(0);
      // Still on the login form, not signed in.
      await expect(page.locator('input[aria-label="email"]')).toBeVisible();
    });
  });

  test("logout clears cookies, revokes the session, and shows the login page", async ({
    page,
    context,
  }) => {
    const { setupAuthenticatedPage } = require("../helpers/setup");
    await setupAuthenticatedPage(page, context);
    // The real login also writes the community's time zone.
    await context.addCookies([
      {
        name: "timezone",
        value: "America/Los_Angeles",
        domain: "localhost",
        path: "/",
      },
    ]);

    // Registered after setupAuthenticatedPage, so it runs first and then
    // hands the request to the shared stub.
    let revokeMethod = null;
    let revokeAuthorization = null;
    await page.route("**/api/v1/sessions/current", (route) => {
      revokeMethod = route.request().method();
      revokeAuthorization = route.request().headers()["authorization"];
      route.fallback();
    });

    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");

    const logoutButton = page.locator("text=logout");
    await expect(logoutButton.first()).toBeVisible({ timeout: 10000 });
    await logoutButton.first().click();

    // The login page sends anyone who still has a token cookie back to
    // the calendar, so the form showing up means the token is gone.
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 10000,
    });

    // The server was asked to revoke the token. The header is set by
    // logout() itself, before the cookie it reads is removed.
    await expect.poll(() => revokeMethod, { timeout: 5000 }).toBe("DELETE");
    expect(revokeAuthorization).toBe("Bearer test-token-abc123");

    const cookieNames = (await context.cookies()).map((c) => c.name);
    for (const name of [
      "token",
      "community_id",
      "resident_id",
      "username",
      "timezone",
    ]) {
      expect(cookieNames, `cookie ${name} is removed`).not.toContain(name);
    }
  });
});
