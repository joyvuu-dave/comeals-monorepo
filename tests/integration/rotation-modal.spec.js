const { test, expect } = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  FAKE_TODAY,
} = require("../helpers/integration_setup");

// The rotation modal against the real API. The e2e version mocks the
// response; this one proves the server sends place_value and that the
// modal shows it, not the database id (commit 89577f3).
test.describe("Rotation modal (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  test("shows the rotation's place in date order and its members", async ({
    page,
  }) => {
    const rotation = auth.rotations.second;
    expect(rotation.place_value).toBe(2);

    await page.goto(
      `/calendar/all/${FAKE_TODAY}/rotations/show/${rotation.id}/`,
    );
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("text=Rotation 2")).toBeVisible({
      timeout: 10000,
    });
    if (rotation.id !== 2) {
      await expect(modal.locator(`text=Rotation ${rotation.id}`)).toHaveCount(
        0,
      );
    }

    // Every active cook is listed, and none has signed up for this
    // rotation, so nobody is struck through.
    await expect(modal.locator("text=Jane Smith")).toBeVisible();
    await expect(modal.locator("text=Bob Johnson")).toBeVisible();
    await expect(modal.locator("s")).toHaveCount(0);
  });

  test("strikes through a member who already has a bill in the rotation", async ({
    page,
  }) => {
    const rotation = auth.rotations.first;
    await page.goto(
      `/calendar/all/${FAKE_TODAY}/rotations/show/${rotation.id}/`,
    );
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("text=Rotation 1")).toBeVisible({
      timeout: 10000,
    });
    await expect(modal.locator("s", { hasText: "Jane Smith" })).toBeVisible();
    await expect(modal.locator("s", { hasText: "Bob Johnson" })).toHaveCount(0);
  });
});
