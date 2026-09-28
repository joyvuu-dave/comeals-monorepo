const { test, expect } = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  FAKE_TODAY,
} = require("../helpers/integration_setup");

// The rotation modal against the real API. The e2e version mocks the
// response; this one proves the server sends place_value and that the
// modal shows it, not the database id (commit 89577f3). The seed makes
// every rotation's id differ from its place, so the two cannot be
// confused (lib/tasks/test/seed_integration.rake).
test.describe("Rotation modal (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  async function openRotation(page, rotation) {
    await page.goto(
      `/calendar/all/${FAKE_TODAY}/rotations/show/${rotation.id}/`,
    );
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    return modal;
  }

  test("shows the rotation's place in date order and its members", async ({
    page,
  }) => {
    const rotation = auth.rotations.second;
    expect(rotation.place_value).toBe(2);
    expect(rotation.id).not.toBe(rotation.place_value);

    const modal = await openRotation(page, rotation);
    await expect(modal.locator("h1")).toHaveText("Rotation 2", {
      timeout: 10000,
    });

    // Everyone who can be asked to cook, in display-name order: active
    // adults who can cook. The seed also has Alice (cannot cook),
    // Charlie (a child) and Diana (not active), and none of them is on
    // the list. Nobody has signed up for this rotation, so nobody is
    // struck through.
    await expect(modal.locator("li")).toHaveText([
      "A - Jane Smith",
      "B - Bob Johnson",
    ]);
    await expect(modal.locator("s")).toHaveCount(0);
  });

  test("strikes through a member who already has a bill in the rotation", async ({
    page,
  }) => {
    const rotation = auth.rotations.first;
    expect(rotation.place_value).toBe(1);
    expect(rotation.id).not.toBe(rotation.place_value);

    const modal = await openRotation(page, rotation);
    await expect(modal.locator("h1")).toHaveText("Rotation 1", {
      timeout: 10000,
    });
    await expect(modal.locator("li")).toHaveText([
      "A - Jane Smith",
      "B - Bob Johnson",
    ]);
    // Jane cooks this rotation's one meal in the seed; Bob does not.
    await expect(modal.locator("s")).toHaveText(["A - Jane Smith"]);
  });
});
