const { test, expect, httpFailurePattern } = require("../helpers/test");
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
      // What ResidentsController#password_reset answers when the mail
      // goes out.
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Check your email." }),
      });
    });

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // Fill in the email on the login form, then click Reset your password
    await page.locator("#login-email").fill("jane@example.com");
    await page.getByRole("button", { name: "Reset your password" }).click();

    // API: POST with the email and nothing else
    await expect.poll(() => resetPayload, { timeout: 5000 }).toBeTruthy();
    expect(resetMethod).toBe("POST");
    expect(resetPayload).toEqual({ email: "jane@example.com" });

    // The server's message, word for word, in a success toast
    const toast = page.locator(".toast--success");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast.locator(".toast__message")).toHaveText(
      "Check your email.",
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
        body: JSON.stringify({ message: "Check your email." }),
      });
    });

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    await page.getByRole("button", { name: "Reset your password" }).click();

    const toast = page.locator(".toast--error");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast.locator(".toast__message")).toHaveText(
      "Email required.",
    );
    expect(resetRequested).toBe(false);

    // The page made this check itself, so the error goes as soon as the
    // email box holds an email, without waiting to be closed (#137).
    await page.locator('input[aria-label="email"]').fill("jane@example.com");
    await expect(toast).toHaveCount(0);
  });

  test("set new password sends POST with the token and the password", async ({
    page,
  }) => {
    let passwordPayload = null;
    let passwordMethod = null;
    let passwordUrl = null;
    // Every address the browser asks for. The token is after the # in
    // the link, which a browser never sends, and the page sends it only
    // in request bodies, so no address may hold it: Rails and Heroku's
    // router log every one.
    const requested = [];
    page.on("request", (request) => requested.push(request.url()));
    await page.route("**/api/v1/residents/password-reset/new", (route) => {
      passwordMethod = route.request().method();
      passwordUrl = route.request().url();
      if (passwordMethod === "POST") {
        passwordPayload = route.request().postDataJSON();
      }
      // What ResidentsController#password_new answers on success.
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Password updated!" }),
      });
    });

    await page.goto("/reset-password#token=test-reset-token");
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

    // API: POST to /residents/password-reset/new with the token and
    // the password in the body
    await expect.poll(() => passwordPayload, { timeout: 5000 }).toBeTruthy();
    expect(passwordMethod).toBe("POST");
    expect(passwordPayload).toEqual({
      reset_token: "test-reset-token",
      password: "newpassword123",
    });
    expect(passwordUrl).toMatch(/\/api\/v1\/residents\/password-reset\/new$/);
    expect(requested.filter((url) => url.includes("test-reset-token"))).toEqual(
      [],
    );

    // The server's message, word for word, in a success toast
    const toast = page.locator(".toast--success");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await expect(toast.locator(".toast__message")).toHaveText(
      "Password updated!",
    );
  });

  // #152. While the request is out, the form disables its field and
  // Submit. Chrome moves focus off a control that turns disabled, to
  // <body>, and react-modal listens for Escape only on the dialog, so
  // Escape did nothing after a refused password. WebKit does not focus
  // a button on a click, so it worked there.
  test.describe("refused", () => {
    test.use({ allowedConsoleErrors: httpFailurePattern });

    test("Escape closes the reset dialog after its Submit is refused", async ({
      page,
    }) => {
      await page.route("**/api/v1/residents/password-reset/new", (route) =>
        route.fulfill({
          status: 400,
          contentType: "application/json",
          body: JSON.stringify({ message: "Password is too short" }),
        }),
      );
      await page.goto("/reset-password#token=test-reset-token");
      const modal = page.locator(".ReactModal__Content--after-open");
      await modal.locator('input[type="password"]').fill("x");
      await modal.getByRole("button", { name: "Submit" }).click();
      await expect(modal.locator(".form-message__text")).toHaveText(
        "Password is too short",
      );

      await page.keyboard.press("Escape");
      await expect(modal).toHaveCount(0);
    });
  });

  // The page keeps the token and takes it out of the address, so it is
  // not left on a shared screen or in the browser's history.
  test("the reset page takes the token out of the address", async ({
    page,
  }) => {
    await page.goto("/reset-password#token=test-reset-token");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator('input[type="password"]')).toBeVisible({
      timeout: 10000,
    });

    await expect(page).toHaveURL(/\/reset-password$/);
  });

  // A link mailed before 2026-10-23 has the token in the path. Those
  // tokens were all cleared, so the page sends nothing and says to ask
  // for a new link.
  test.describe("old link", () => {
    test("a reset link of the old kind says to ask for a new one", async ({
      page,
    }) => {
      const asked = [];
      page.on("request", (request) => {
        if (request.url().includes("/api/v1/residents/")) {
          asked.push(request.url());
        }
      });
      await page.goto("/reset-password/test-reset-token/");

      const toast = page.locator(".toast--error");
      await expect(toast.locator(".toast__message")).toHaveText(
        "This password reset link no longer works. Please request a new one.",
        { timeout: 10000 },
      );
      await expect(page).toHaveURL(/\/$/);
      expect(asked).toEqual([]);
    });
  });
});
