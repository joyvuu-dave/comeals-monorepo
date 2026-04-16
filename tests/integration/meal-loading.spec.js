const { test, expect } = require("@playwright/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
} = require("../helpers/integration_setup");

test.describe("Meal loading (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  test("tomorrow's meal loads with correct data", async ({ page }) => {
    await page.goto(`/meals/${auth.meals.tomorrow.id}/edit/`);
    await page.waitForLoadState("networkidle");

    // Status: OPEN (not closed)
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // Description matches seed data
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Pasta night with garlic bread");

    // All seeded residents visible (names include unit prefix from real serializer)
    // Use exact: true to avoid matching late/veg/guest cells that also contain the name
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("cell", { name: "B - Bob Johnson", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("cell", { name: "C - Alice Williams", exact: true }),
    ).toBeVisible();

    // Jane, Bob, and Alice are attending (green background)
    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    const aliceCell = page.getByRole("cell", {
      name: "C - Alice Williams",
      exact: true,
    });
    await expect(janeCell).toHaveClass(/background-green/);
    await expect(bobCell).toHaveClass(/background-green/);
    await expect(aliceCell).toHaveClass(/background-green/);

    // Bill: Jane cooked, $50.00
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("50.00");

    // Jane has 1 vegetarian guest (carrot icon)
    const janeRow = janeCell.locator("xpath=ancestor::tr");
    await expect(
      janeRow.locator('.badge img[alt="carrot-icon"]'),
    ).toBeVisible();
  });

  test("closed meal loads with correct state", async ({ page }) => {
    await page.goto(`/meals/${auth.meals.closed.id}/edit/`);
    await page.waitForLoadState("networkidle");

    // Status: CLOSED
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 10000,
    });

    // Description
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Tacos and rice");
    await expect(textarea).toBeDisabled();

    // Bob attending, Jane NOT attending
    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(janeCell).not.toHaveClass(/background-green/);
    await expect(bobCell).toHaveClass(/background-green/);

    // Bill: Bob cooked, $35.50
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("35.50");
  });

  test("today's meal loads with correct attendees", async ({ page }) => {
    await page.goto(`/meals/${auth.meals.today.id}/edit/`);
    await page.waitForLoadState("networkidle");

    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Pizza and salad");

    // Jane and Alice attending
    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    const aliceCell = page.getByRole("cell", {
      name: "C - Alice Williams",
      exact: true,
    });
    await expect(janeCell).toHaveClass(/background-green/);
    await expect(aliceCell).toHaveClass(/background-green/);

    // Bob NOT attending
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCell).not.toHaveClass(/background-green/);
  });

  test("prev/next navigation works between real meals", async ({ page }) => {
    await page.goto(`/meals/${auth.meals.today.id}/edit/`);
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1")).toBeVisible({ timeout: 10000 });

    // Click the right chevron arrow to go to the next meal
    await page.locator('[data-icon="chevron-right"]').click();
    await page.waitForLoadState("networkidle");

    // Should now show tomorrow's meal description
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Pasta night with garlic bread", {
      timeout: 10000,
    });

    // URL should have changed to tomorrow's meal ID
    await expect(page).toHaveURL(
      new RegExp(`/meals/${auth.meals.tomorrow.id}/edit/`),
    );
  });

  test("reconciled meal shows reconciled state", async ({ page }) => {
    await page.goto(`/meals/${auth.meals.reconciled.id}/edit/`);
    await page.waitForLoadState("networkidle");

    // Reconciled meals show "RECONCILED" (separate h1 path in date_box.jsx)
    await expect(
      page.locator("h1", { hasText: "RECONCILED" }),
    ).toBeVisible({ timeout: 10000 });

    // Description still populated
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Stir fry vegetables");
  });
});
