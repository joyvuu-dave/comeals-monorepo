const { test, expect } = require("../helpers/test");
const {
  setupAuthenticatedPage,
  stubPusher,
  disableIdleTimer,
  mockApi,
} = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");

// The number in one of the meal page's count circles (Total, Veg,
// Late). The circle holds two divs: the label, then the number.
function circleNumber(page, label) {
  return page.locator(".info-circle", { hasText: label }).locator("div").nth(1);
}

test.describe("Critical Paths", () => {
  test("unauthenticated user is redirected to login from protected route", async ({
    page,
  }) => {
    // Set up page WITHOUT auth cookies
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);

    // Try to access a protected route
    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");

    // Should be redirected to login (shows email/password inputs, not calendar)
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator(".rbc-calendar")).not.toBeVisible();

    // Try meal page too
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Should still show login
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 5000,
    });
  });

  test("rotation modal fetches data and renders resident list", async ({
    page,
    context,
  }) => {
    let rotationGetUrl = null;
    await setupAuthenticatedPage(page, context);

    await page.route("**/api/v1/rotations/*", (route) => {
      rotationGetUrl = route.request().url();
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          id: 10,
          place_value: 3,
          description: "Kitchen cleaning rotation",
          // Out of order on purpose: the server does not sort this
          // list (Resident.eligible_cooks has no ORDER BY), the modal
          // does.
          residents: [
            { id: 3, display_name: "C - Alice Williams", signed_up: false },
            { id: 1, display_name: "A - Jane Smith", signed_up: true },
            { id: 2, display_name: "B - Bob Johnson", signed_up: false },
          ],
        }),
      });
    });

    // Navigate to calendar with rotation modal URL
    await page.goto("/calendar/all/2026-01-15/rotations/show/10/");
    await page.waitForLoadState("networkidle");

    // Modal should open
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });

    // The title shows the place value (3), not the database id (10).
    await expect(modal.locator("text=Rotation 3")).toBeVisible({
      timeout: 5000,
    });
    await expect(modal.locator("text=Rotation 10")).toHaveCount(0);
    await expect(modal.locator("text=Kitchen cleaning rotation")).toBeVisible();

    // Signed-up residents should be struck through (muted)
    const janeEntry = modal.locator("text=Jane Smith");
    await expect(janeEntry).toBeVisible();
    // Jane is signed_up=true → should be in <s> tag with text-muted class
    await expect(modal.locator("s", { hasText: "Jane Smith" })).toBeVisible();

    // Not-signed-up residents should be bold italic
    const bobEntry = modal.locator("li.text-bold", { hasText: "Bob Johnson" });
    await expect(bobEntry).toBeVisible();

    // The modal sorts the residents by display name.
    const listItems = modal.locator("li");
    const names = await listItems.allTextContents();
    expect(names).toEqual([
      "A - Jane Smith",
      "B - Bob Johnson",
      "C - Alice Williams",
    ]);

    // API: GET to /rotations/10
    expect(rotationGetUrl).toMatch(/\/api\/v1\/rotations\/10$/);
  });

  test("reconciled meal disables all controls", async ({ page, context }) => {
    // Closed with max 5 and 3 eaters, so 2 seats are left. On an open
    // or a full meal, other rules already stop a click on a name. Here
    // only the reconciled rule stops a click from signing someone up.
    const reconciledMeal = {
      ...mealFixture,
      reconciled: true,
      closed: true,
      closed_at: "2026-01-15T20:00:00Z",
      max: 5,
    };

    await setupAuthenticatedPage(page, context, { mealData: reconciledMeal });

    const attendanceWrites = [];
    await page.route("**/api/v1/meals/*/residents/**", (route) => {
      attendanceWrites.push(
        `${route.request().method()} ${route.request().url()}`,
      );
      route.fallback();
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Should show RECONCILED status
    await expect(page.locator("h1", { hasText: "RECONCILED" })).toBeVisible({
      timeout: 10000,
    });

    // Open/Close button
    await expect(page.locator("text=Open / Close Meal")).toBeDisabled();

    // The menu
    await expect(
      page.locator('[aria-label="Enter meal description"]'),
    ).toBeDisabled();

    // Every cook row: the cook, the cost, and the no-cost switch
    const cookSelects = page.locator('[aria-label="Select meal cook"]');
    const cookRowCount = await cookSelects.count();
    expect(cookRowCount).toBeGreaterThan(0);
    for (let i = 0; i < cookRowCount; i++) {
      await expect(cookSelects.nth(i)).toBeDisabled();
      await expect(
        page.locator('[aria-label="Set meal cost"]').nth(i),
      ).toBeDisabled();
      await expect(
        page.locator('input[aria-label^="No cost button for"]').nth(i),
      ).toBeDisabled();
    }

    // Every extras choice
    for (let n = 0; n <= 8; n++) {
      await expect(
        page.locator(`[aria-label="Set Extras to ${n}"]`),
      ).toBeDisabled();
    }

    // Every resident row: late, veg, add guest and remove guest
    for (const resident of mealFixture.residents) {
      await expect(page.locator(`#late_switch_${resident.id}`)).toBeDisabled();
      await expect(page.locator(`#veg_switch_${resident.id}`)).toBeDisabled();
      await expect(
        page.locator(
          `button:has([aria-label="Add Guest of ${resident.name}"])`,
        ),
      ).toBeDisabled();
      await expect(
        page.locator(`[aria-label="Remove Guest of ${resident.name}"]`),
      ).toBeDisabled();
    }

    // The name cells are how a person signs up or leaves. A <td> has no
    // disabled state: only the pointer-events rule in attendees_box.jsx
    // stops the click, and jsdom ignores that rule, so only a real
    // browser can check it.
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(bobCell).toHaveCSS("pointer-events", "none");
    await expect(janeCell).toHaveCSS("pointer-events", "none");

    // A real mouse click in the middle of each cell changes nothing and
    // sends nothing. (locator.click() would refuse to click an element
    // that does not take pointer events, so this uses the mouse.)
    for (const cell of [bobCell, janeCell]) {
      const box = await cell.boundingBox();
      await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    }
    // A click event sent to the cell itself (a screen reader's activate
    // action, or a script) does not go through pointer-events. The
    // store refuses that one.
    for (const cell of [bobCell, janeCell]) {
      await cell.dispatchEvent("click");
    }
    await expect(bobCell).not.toHaveClass(/background-green/);
    await expect(janeCell).toHaveClass(/background-green/);
    await expect(circleNumber(page, "Total")).toHaveText("3");
    // Give a request that should not exist time to show up.
    await page.waitForTimeout(500);
    expect(attendanceWrites).toEqual([]);
  });

  // Closing with a blank cook cost asks instead of blocking: forcing a
  // number before the shopping happened bred fake $1 costs. Yes closes;
  // everything else keeps the meal open.
  test("closing with a blank cook cost asks first", async ({
    page,
    context,
  }) => {
    // Create a meal where a cook is assigned but has empty cost
    const mealWithEmptyCost = {
      ...mealFixture,
      bills: [
        {
          id: 201,
          meal_id: 42,
          resident_id: 1,
          amount: "",
          no_cost: false,
        },
      ],
    };

    await setupAuthenticatedPage(page, context, {
      mealData: mealWithEmptyCost,
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Meal should be open
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // The close click asks instead of closing.
    await page.locator("text=Open / Close Meal").click();
    const confirm = page.locator(".confirm-bar");
    await expect(confirm).toBeVisible();
    await expect(confirm).toContainText("entered a cost yet");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();

    // No keeps the meal open.
    await confirm.getByRole("button", { name: "No" }).click();
    await expect(confirm).toBeHidden();
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();

    // Yes closes it.
    await page.locator("text=Open / Close Meal").click();
    await expect(confirm).toBeVisible();
    await confirm.getByRole("button", { name: "Yes" }).click();
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 5000,
    });
  });

  test("online/offline indicator exists with correct state", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);

    // Check calendar page
    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // The online indicator exists in DOM with class "online" and text "ONLINE"
    // CSS intentionally hides it (opacity:0, visibility:hidden) when online --
    // it only flashes visible during offline->online transition. The ".offline"
    // class makes it visible with red background. So: we verify the element
    // exists, has the right class, and has the right text.
    const indicator = page.locator("span.online, span.offline");
    await expect(indicator).toHaveCount(1);
    await expect(indicator).toHaveClass(/online/);
    await expect(indicator).toHaveText("ONLINE");

    // Check meal page has it too
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });

    const mealIndicator = page.locator("span.online, span.offline");
    await expect(mealIndicator).toHaveCount(1);
    await expect(mealIndicator).toHaveText("ONLINE");
  });

  test("toggle off attendance sends DELETE and updates counts", async ({
    page,
    context,
  }) => {
    let apiMethod = null;
    let apiUrl = null;
    await setupAuthenticatedPage(page, context);

    // Intercept Jane's resident endpoint (id=1) to capture the DELETE.
    // The body is what the server answers.
    await page.route("**/api/v1/meals/*/residents/1", (route) => {
      apiMethod = route.request().method();
      apiUrl = route.request().url();
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "MealResident destroyed." }),
      });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    // Before: Jane is attending (green background). Total is Jane,
    // Alice and Jane's guest; Late is Alice.
    await expect(janeCell).toHaveClass(/background-green/);
    await expect(circleNumber(page, "Total")).toHaveText("3");
    await expect(circleNumber(page, "Late")).toHaveText("1");
    const janeRow = janeCell.locator("xpath=ancestor::tr");
    const janeCow = janeRow.locator('.badge img[alt="cow-icon"]');
    await expect(janeCow).toHaveCount(1);

    // Click Jane's name to remove attendance
    await janeCell.click();

    // After: Jane is not attending. Her guest still eats: neither the
    // client nor the server removes a guest when the host leaves. So
    // Total is Alice plus Jane's guest, 2, and Late is still Alice.
    await expect(janeCell).not.toHaveClass(/background-green/, {
      timeout: 3000,
    });
    await expect(circleNumber(page, "Total")).toHaveText("2");
    await expect(circleNumber(page, "Late")).toHaveText("1");
    await expect(janeCow).toHaveCount(1);

    // API: DELETE (not POST) to remove attendance
    await expect.poll(() => apiMethod, { timeout: 3000 }).toBe("DELETE");
    expect(apiUrl).toMatch(/\/api\/v1\/meals\/42\/residents\/1$/);
  });
});
