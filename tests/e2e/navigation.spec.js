const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");

test.describe("Navigation", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  test("prev/next meal arrows navigate between meals", async ({ page }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Should show navigation arrows
    // The next arrow should be visible since next_id is 43
    const nextArrow = page
      .locator('[data-testid="next-meal"]')
      .or(page.locator("svg.fa-chevron-right").first());

    if (await nextArrow.isVisible({ timeout: 5000 })) {
      await nextArrow.click();
      // Should navigate to meal 43
      await expect(page).toHaveURL(/\/meals\/43\/edit/, { timeout: 5000 });
    }
  });

  test("meal history modal opens and shows audit entries", async ({ page }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Click the history button/link
    const historyLink = page.locator("text=history").first();
    await expect(historyLink).toBeVisible({ timeout: 10000 });
    await historyLink.click();

    // History modal should open with audit entries
    await expect(page.locator(".ReactModal__Content--after-open")).toBeVisible({
      timeout: 5000,
    });

    // Should show history items from fixture -- use exact cell match
    await expect(
      page.getByRole("cell", { name: "signed up", exact: true }),
    ).toBeVisible({ timeout: 5000 });
  });

  test("calendar back button navigates from meal to calendar", async ({
    page,
  }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Find the back arrow / calendar link
    const backButton = page
      .locator("svg.fa-arrow-left")
      .or(page.locator('[aria-label="Back to calendar"]'))
      .first();

    if (await backButton.isVisible({ timeout: 5000 })) {
      await backButton.click();
      await expect(page).toHaveURL(/\/calendar\//, { timeout: 5000 });
    }
  });

  // Regression test for the 2026-07-22 production crash. Leaving a meal
  // for the calendar nulls store.meal but used to leave the meal's rows
  // (bills, residents, guests) in the store. Clicking back into a meal
  // rendered those stale rows before goToMeal ran, and a row read
  // store.meal.reconciled on the null meal — a TypeError that tripped
  // the error boundary and blanked the whole app.
  test("returning to a meal from the calendar renders it without crashing", async ({
    page,
  }) => {
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(String(error)));

    // Load the meal page fully: attendee rows and cook rows on screen.
    await page.goto("/meals/42/edit/");
    const janeCell = page.getByRole("cell", {
      name: "Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    // To the calendar. Its mount tears down the meal page's store state.
    await page.getByRole("button", { name: "Calendar" }).click();
    await expect(page).toHaveURL(/\/calendar\//, { timeout: 5000 });
    const mealEvent = page.locator("text=Meal: Jane Smith");
    await expect(mealEvent).toBeVisible({ timeout: 5000 });

    // Back into the meal, the same way production does it: the calendar
    // event carries url "/meals/42/edit" and clicking it navigates there.
    await mealEvent.click();
    await expect(page).toHaveURL(/\/meals\/42\/edit/, { timeout: 5000 });

    // The meal page renders again — no error boundary, no page errors.
    await expect(janeCell).toBeVisible({ timeout: 10000 });
    await expect(
      page.locator("text=Something went wrong with Comeals."),
    ).toHaveCount(0);
    expect(pageErrors).toEqual([]);
  });

  // The same bug family as the crash above, one window earlier.
  // Switching meal → meal used to keep the OLD meal's rows on screen
  // until the new meal's data arrived. On a slow backend that window is
  // long and the rows were editable — and a bill edit made in it was
  // sent to the NEW meal's bills endpoint carrying the OLD meal's cook
  // list, which the server treats as the complete list for that meal.
  // The rows must leave with their meal, and the menu must freeze while
  // the next meal loads.
  test("switching meals on a slow backend leaves nothing stale to edit", async ({
    page,
  }) => {
    // Meal 43 answers slowly, with its own distinct people.
    const meal43 = JSON.parse(JSON.stringify(mealFixture));
    meal43.id = 43;
    meal43.prev_id = 42;
    meal43.next_id = 44;
    meal43.residents = [
      {
        id: 4,
        meal_id: 43,
        name: "Zed Zebra",
        attending: false,
        attending_at: null,
        late: false,
        vegetarian: false,
        can_cook: true,
        active: true,
      },
    ];
    meal43.guests = [];
    meal43.bills = [];
    await page.route("**/api/v1/meals/43/cooks*", async (route) => {
      if (route.request().method() !== "GET") return route.fallback();
      await new Promise((resolve) => setTimeout(resolve, 2000));
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(meal43),
      });
    });

    const billsPatchesTo43 = [];
    page.on("request", (request) => {
      if (
        request.method() === "PATCH" &&
        request.url().includes("/meals/43/bills")
      ) {
        billsPatchesTo43.push(request.postData());
      }
    });

    await page.goto("/meals/42/edit/");
    await expect(page.getByLabel("Set meal cost").first()).toHaveValue("25.50");

    await page.locator("svg.fa-chevron-right").first().click();
    await expect(page).toHaveURL(/\/meals\/43\/edit/);

    // Inside the load window: the old meal's rows are gone and the menu
    // is frozen. The window is 2s; each check must settle well before
    // the load lands — a longer timeout could let the loaded state mask
    // a stale-row bug (the loaded meal also has blank cost inputs).
    await expect(
      page.getByRole("cell", { name: "Jane Smith", exact: true }),
    ).toHaveCount(0, { timeout: 900 });
    await expect(page.getByLabel("Set meal cost")).toHaveCount(0, {
      timeout: 900,
    });
    await expect(page.getByLabel("Enter meal description")).toBeDisabled({
      timeout: 900,
    });

    // The slow load lands: meal 43's own rows appear, editing unfreezes.
    await expect(
      page.getByRole("cell", { name: "Zed Zebra", exact: true }),
    ).toBeVisible({ timeout: 10000 });
    await expect(page.getByLabel("Enter meal description")).toBeEnabled();

    // And nothing was ever saved onto meal 43's bills.
    expect(billsPatchesTo43).toEqual([]);
  });

  // Menu text typed just before a meal switch used to follow the
  // switch: the textarea's 500ms debounce fired after store.meal had
  // moved on, so the text saved onto the NEW meal — silently replacing
  // that meal's real menu (verified by probe, 2026-07-22). The text
  // must save to the meal it was typed on.
  test("menu text typed just before a meal switch saves to the meal it was typed on", async ({
    page,
  }) => {
    const meal43 = JSON.parse(JSON.stringify(mealFixture));
    meal43.id = 43;
    meal43.prev_id = 42;
    meal43.next_id = 44;
    meal43.description = "Meal 43's real menu";
    await page.route("**/api/v1/meals/43/cooks*", async (route) => {
      if (route.request().method() !== "GET") return route.fallback();
      await new Promise((resolve) => setTimeout(resolve, 1200));
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(meal43),
      });
    });

    const descriptionPatches = [];
    page.on("request", (request) => {
      if (
        request.method() === "PATCH" &&
        request.url().includes("/description")
      ) {
        descriptionPatches.push({
          url: request.url(),
          body: request.postData(),
        });
      }
    });

    await page.goto("/meals/42/edit/");
    const menuBox = page.getByLabel("Enter meal description");
    await expect(menuBox).toHaveValue("Pasta night with garlic bread");

    // Type, then switch meals before the 500ms debounce fires.
    await menuBox.fill("Tacos");
    await page.locator("svg.fa-chevron-right").first().click();
    await expect(page).toHaveURL(/\/meals\/43\/edit/);

    // The slow load lands and meal 43 shows its own menu — not the text
    // typed on meal 42.
    await expect(page.getByLabel("Enter meal description")).toHaveValue(
      "Meal 43's real menu",
      { timeout: 10000 },
    );

    // The typed text saved to meal 42, and meal 43 was never written.
    const to42 = descriptionPatches.filter((p) => p.url.includes("/meals/42/"));
    const to43 = descriptionPatches.filter((p) => p.url.includes("/meals/43/"));
    expect(to42.length).toBe(1);
    expect(JSON.parse(to42[0].body).description).toBe("Tacos");
    expect(to43).toEqual([]);
  });

  test("a URL without a trailing slash redirects to the slashed URL", async ({
    page,
  }) => {
    // The TrailingSlash component adds the slash on every navigation.
    // The calendar relies on it: opening a modal pushes a URL built by
    // string concatenation, which has no trailing slash.
    await page.goto("/meals/42/edit");
    await expect(page).toHaveURL(/\/meals\/42\/edit\/$/, { timeout: 10000 });

    // The meal page rendered after the redirect
    await expect(page.locator("svg.fa-chevron-right").first()).toBeVisible({
      timeout: 10000,
    });
  });

  test("a history deep link opens the modal on a fresh page load", async ({
    page,
  }) => {
    // Exercises the splat route plus the descendant history route from
    // a cold load — not via in-app navigation like the test above.
    await page.goto("/meals/42/edit/history/42/");
    await page.waitForLoadState("networkidle");

    await expect(page.locator(".ReactModal__Content--after-open")).toBeVisible({
      timeout: 10000,
    });
    await expect(
      page.getByRole("cell", { name: "signed up", exact: true }),
    ).toBeVisible({ timeout: 5000 });
  });
});
