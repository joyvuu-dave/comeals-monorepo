const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");

// The number in one of the meal page's count circles (Total, Veg,
// Late). The circle holds two divs: the label, then the number.
// toHaveText on it is exact, where toContainText("3") on the circle
// would also match 13.
function circleNumber(page, label) {
  return page.locator(".info-circle", { hasText: label }).locator("div").nth(1);
}

// A write answered the way the server answers it (MealsController).
function fulfillJson(route, body) {
  return route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify(body),
  });
}

test.describe("Meal Editing", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  test("meal page loads with correct initial state from fixture data", async ({
    page,
  }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // --- Status ---
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // --- Description ---
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Pasta night with garlic bread");

    // --- Residents in attendee table ---
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
    await expect(janeCell).toBeVisible();
    await expect(bobCell).toBeVisible();
    await expect(aliceCell).toBeVisible();

    // Jane is attending (green background)
    await expect(janeCell).toHaveClass(/background-green/);
    // Bob is NOT attending (no green)
    await expect(bobCell).not.toHaveClass(/background-green/);
    // Alice is attending (green background)
    await expect(aliceCell).toHaveClass(/background-green/);

    // --- Info circles (computed values) ---
    // Fixture: Jane attending + Alice attending + 1 guest = 3 total
    await expect(circleNumber(page, "Total")).toHaveText("3");
    // Fixture: no vegetarian attendees (Bob is veg but not attending)
    await expect(circleNumber(page, "Veg")).toHaveText("0");
    // Fixture: Alice is late = 1 late
    await expect(circleNumber(page, "Late")).toHaveText("1");

    // --- Late/Veg switch initial states ---
    // Alice (id=3) is late -- her switch should be checked
    await expect(page.locator("#late_switch_3")).toBeChecked();
    // Jane (id=1) is not late -- her switch should be unchecked
    await expect(page.locator("#late_switch_1")).not.toBeChecked();
    // Bob (id=2) is vegetarian -- his switch should be checked
    await expect(page.locator("#veg_switch_2")).toBeChecked();
    // Jane (id=1) is not vegetarian
    await expect(page.locator("#veg_switch_1")).not.toBeChecked();

    // --- Guest icons ---
    // Jane has 1 non-vegetarian guest: should show a cow icon
    const janeRow = janeCell.locator("xpath=ancestor::tr");
    await expect(janeRow.locator('.badge img[alt="cow-icon"]')).toBeVisible();
    // Bob has no guests: no icons in his row
    const bobRow = bobCell.locator("xpath=ancestor::tr");
    await expect(bobRow.locator(".badge img")).toHaveCount(0);

    // --- Cooks/Bills ---
    // First bill has resident_id=1 (Jane) and amount=25.50
    const firstCookSelect = page
      .locator('[aria-label="Select meal cook"]')
      .first();
    await expect(firstCookSelect).toHaveValue("1");
    const firstCostInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(firstCostInput).toHaveValue("25.50");
  });

  test("toggle resident attendance updates background and counts", async ({
    page,
  }) => {
    let apiMethod = null;
    let apiPayload = null;
    await page.route("**/api/v1/meals/*/residents/2*", (route) => {
      apiMethod = route.request().method();
      if (apiMethod === "POST") {
        apiPayload = route.request().postDataJSON();
      }
      // The server answers a sign-up with the new MealResident row.
      fulfillJson(route, {
        id: 900,
        meal_id: 42,
        resident_id: 2,
        late: false,
        vegetarian: true,
        created_at: "2026-01-15T10:00:00.000-08:00",
      });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCell).toBeVisible({ timeout: 10000 });

    // Before: Bob not attending, Total=3, Veg=0
    await expect(bobCell).not.toHaveClass(/background-green/);
    await expect(circleNumber(page, "Total")).toHaveText("3");
    await expect(circleNumber(page, "Veg")).toHaveText("0");

    // Click to toggle attending (Bob is not attending -> adds him)
    await bobCell.click();

    // After: Bob attending (green), Total=4, Veg=1 (Bob is vegetarian)
    await expect(bobCell).toHaveClass(/background-green/, { timeout: 3000 });
    await expect(circleNumber(page, "Total")).toHaveText("4");
    await expect(circleNumber(page, "Veg")).toHaveText("1");

    // API: POST to add attendance (not DELETE), with late/vegetarian in payload
    await expect.poll(() => apiMethod, { timeout: 3000 }).toBe("POST");
    expect(Object.keys(apiPayload).sort()).toEqual([
      "late",
      "socket_id",
      "vegetarian",
    ]);
    expect(apiPayload.vegetarian).toBe(true);
    expect(apiPayload.late).toBe(false);
  });

  test("toggle late switch updates checked state and late count", async ({
    page,
  }) => {
    let patchData = null;
    await page.route("**/api/v1/meals/*/residents/1*", (route) => {
      if (route.request().method() === "PATCH") {
        patchData = route.request().postDataJSON();
      }
      fulfillJson(route, { message: "MealResident updated." });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });

    // Before: Jane not late, late count = 1 (only Alice)
    const lateSwitch = page.locator("#late_switch_1");
    await expect(lateSwitch).not.toBeChecked();
    await expect(circleNumber(page, "Late")).toHaveText("1");

    // Toggle late via the label (clicking hidden input with force doesn't fire React onChange)
    await page.locator('label[for="late_switch_1"]').click();

    // After: Jane is now late, switch is checked, late count = 2
    await expect(lateSwitch).toBeChecked({ timeout: 3000 });
    await expect(circleNumber(page, "Late")).toHaveText("2");

    // The store flips the switch before it sends the request, so the
    // request can reach the route after the checks above pass: wait
    // for it. The body carries late and the socket id, nothing else.
    await expect.poll(() => patchData, { timeout: 3000 }).toBeTruthy();
    expect(Object.keys(patchData).sort()).toEqual(["late", "socket_id"]);
    expect(patchData.late).toBe(true);
  });

  test("toggle veg switch updates checked state and veg count", async ({
    page,
  }) => {
    let patchData = null;
    await page.route("**/api/v1/meals/*/residents/1*", (route) => {
      if (route.request().method() === "PATCH") {
        patchData = route.request().postDataJSON();
      }
      fulfillJson(route, { message: "MealResident updated." });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });

    // Before: Jane not veg, veg count = 0
    const vegSwitch = page.locator("#veg_switch_1");
    await expect(vegSwitch).not.toBeChecked();
    await expect(circleNumber(page, "Veg")).toHaveText("0");

    // Toggle veg via the label
    await page.locator('label[for="veg_switch_1"]').click();

    // After: Jane is now veg, switch is checked, veg count = 1
    await expect(vegSwitch).toBeChecked({ timeout: 3000 });
    await expect(circleNumber(page, "Veg")).toHaveText("1");

    // Wait for the request (the switch flips before it is sent). The
    // body carries vegetarian and the socket id, nothing else.
    await expect.poll(() => patchData, { timeout: 3000 }).toBeTruthy();
    expect(Object.keys(patchData).sort()).toEqual(["socket_id", "vegetarian"]);
    expect(patchData.vegetarian).toBe(true);
  });

  test("edit meal description fires debounced API call", async ({ page }) => {
    let descriptionPayload = null;
    await page.route("**/api/v1/meals/*/description*", (route) => {
      descriptionPayload = route.request().postDataJSON();
      fulfillJson(route, { message: "Description updated." });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toHaveValue("Pasta night with garlic bread");

    // Clear and type new description
    await textarea.fill("Updated: Spaghetti and meatballs");
    await expect(textarea).toHaveValue("Updated: Spaghetti and meatballs");

    // Wait for the debounce to trigger the API call
    await expect.poll(() => descriptionPayload, { timeout: 3000 }).toBeTruthy();
    expect(descriptionPayload.description).toBe(
      "Updated: Spaghetti and meatballs",
    );
  });

  test("open/close meal toggles status and disables description", async ({
    page,
  }) => {
    let closedPayload = null;
    await page.route("**/api/v1/meals/*/closed*", (route) => {
      closedPayload = route.request().postDataJSON();
      // Fall through to the setup.js handler so the mock's meal state
      // records the close — the settle-refetch re-reads it from /cooks.
      route.fallback();
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Before: OPEN, description editable
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).not.toBeDisabled();

    // Close the meal
    await page.locator("text=Open / Close Meal").click();

    // After: CLOSED, description disabled, extras visible
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 5000,
    });
    await expect(textarea).toBeDisabled({ timeout: 3000 });
    await expect(page.locator("text=Extras")).toBeVisible();

    // API called with closed: true. The store shows CLOSED before it
    // sends the request, so wait for it.
    await expect.poll(() => closedPayload, { timeout: 3000 }).toBeTruthy();
    expect(Object.keys(closedPayload).sort()).toEqual(["closed", "socket_id"]);
    expect(closedPayload.closed).toBe(true);
  });

  test("add a guest sends the POST and shows the new guest at once", async ({
    page,
  }) => {
    let guestPostData = null;
    let guestPostUrl = null;
    await page.route("**/api/v1/meals/*/residents/*/guests*", (route) => {
      if (route.request().method() === "POST") {
        guestPostData = route.request().postDataJSON();
        guestPostUrl = route.request().url();
      }
      // The server answers with the new Guest row (GuestSerializer).
      fulfillJson(route, {
        id: 999,
        meal_id: 42,
        resident_id: 1,
        vegetarian: false,
        created_at: "2026-01-15T10:00:00.000-08:00",
      });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    // Before: Jane has 1 omnivore guest; Total is 3
    const janeRow = janeCell.locator("xpath=ancestor::tr");
    const janeCowBadge = janeRow.locator(".badge", {
      has: page.locator('img[alt="cow-icon"]'),
    });
    await expect(janeCowBadge).toHaveText("1");
    await expect(circleNumber(page, "Total")).toHaveText("3");

    // Click add guest button to open dropdown
    const addGuestButton = janeRow.locator(".dropdown-add");
    await expect(addGuestButton).toBeVisible();
    await addGuestButton.click();

    // Dropdown should show cow and carrot options
    const dropdownMenu = janeRow.locator(".dropdown-menu");
    await expect(dropdownMenu).toBeVisible({ timeout: 3000 });
    await expect(dropdownMenu.locator("img[alt='cow-icon']")).toBeVisible();
    await expect(dropdownMenu.locator("img[alt='carrot-icon']")).toBeVisible();

    // Click cow icon to add non-veg guest
    await dropdownMenu.locator("img[alt='cow-icon']").click();

    // API: a POST for Jane's guests with vegetarian: false
    await expect.poll(() => guestPostData, { timeout: 3000 }).toBeTruthy();
    expect(guestPostUrl).toMatch(/\/api\/v1\/meals\/42\/residents\/1\/guests$/);
    expect(Object.keys(guestPostData).sort()).toEqual([
      "socket_id",
      "vegetarian",
    ]);
    expect(guestPostData.vegetarian).toBe(false);

    // The screen shows the new guest without a reload: Jane's badge
    // says 2, Total is 4, and Veg is still 0.
    await expect(janeCowBadge).toHaveText("2");
    await expect(circleNumber(page, "Total")).toHaveText("4");
    await expect(circleNumber(page, "Veg")).toHaveText("0");
  });

  test("remove guest button exists and is enabled for resident with guests", async ({
    page,
  }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    // Jane has 1 guest (cow badge icon)
    const janeRow = janeCell.locator("xpath=ancestor::tr");
    await expect(janeRow.locator('.badge img[alt="cow-icon"]')).toHaveCount(1);

    // Remove button should exist with correct aria-label
    const removeButton = janeRow.locator(
      '[aria-label="Remove Guest of A - Jane Smith"]',
    );
    await expect(removeButton).toBeVisible();

    // The button should be enabled (meal is open, Jane has guests)
    await expect(removeButton).not.toBeDisabled();

    // Bob has no guests -- his remove button should be disabled
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    const bobRow = bobCell.locator("xpath=ancestor::tr");
    const bobRemove = bobRow.locator(
      '[aria-label="Remove Guest of B - Bob Johnson"]',
    );
    await expect(bobRemove).toBeDisabled();
  });

  test("set cost, then a cook: each bills PATCH carries only what was changed", async ({
    page,
  }) => {
    // A small stand-in for the server: it keeps the stored bills, writes
    // amount and no_cost only for rows that carry them (BillsPayload),
    // and answers like MealsController#update_bills with the rows as
    // stored. A blank amount is stored as zero.
    const stored = new Map(
      mealFixture.bills.map((b) => [
        b.resident_id,
        { amount: b.amount, no_cost: b.no_cost },
      ]),
    );
    const billsPayloads = [];
    await page.route("**/api/v1/meals/*/bills*", (route) => {
      if (route.request().method() !== "PATCH") return route.fallback();
      const body = route.request().postDataJSON();
      billsPayloads.push(body);
      const next = new Map();
      for (const row of body.bills) {
        const old = stored.get(row.resident_id) || {
          amount: "0.0",
          no_cost: false,
        };
        next.set(
          row.resident_id,
          "amount" in row
            ? {
                amount: row.amount === "" ? "0.0" : row.amount,
                no_cost: row.no_cost,
              }
            : old,
        );
      }
      stored.clear();
      next.forEach((v, k) => stored.set(k, v));
      fulfillJson(route, {
        message: "Form submitted.",
        bills: [...stored].map(([resident_id, v]) => ({ resident_id, ...v })),
      });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // First cook select is pre-populated with Jane (value="1") and cost=25.50
    const cookSelects = page.locator('[aria-label="Select meal cook"]');
    await expect(cookSelects.first()).toHaveValue("1", { timeout: 10000 });
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("25.50");

    // Change Jane's cost to 35.00. The PATCH lists the one cook, with
    // the amount typed and no_cost off.
    const firstAnswer = page.waitForResponse(
      (r) => r.url().includes("/api/v1/meals/42/bills") && r.status() === 200,
    );
    await costInput.fill("35.00");
    await firstAnswer;
    expect(billsPayloads).toHaveLength(1);
    expect(billsPayloads[0].id).toBe(42);
    expect(billsPayloads[0].bills).toEqual([
      { resident_id: 1, amount: "35.00", no_cost: false },
    ]);
    // After the server's answer the field shows what was stored.
    await expect(costInput).toHaveValue("35.00");

    // Pick Bob as the second cook. The server's answer to the first
    // save marked Jane's row as saved, so this PATCH lists her without
    // an amount: a resend of 35.00 could overwrite a newer cost that
    // someone else saved in between.
    await cookSelects.nth(1).selectOption("2");
    await expect.poll(() => billsPayloads.length, { timeout: 3000 }).toBe(2);
    expect(billsPayloads[1].bills).toEqual([
      { resident_id: 1 },
      { resident_id: 2, amount: "", no_cost: false },
    ]);
    await expect(cookSelects.nth(1)).toHaveValue("2");
  });

  // #91: Carol cooked this open meal, did not eat, and was retired
  // afterwards. The server lists her in the meal form because she has a
  // bill (MealFormSerializer). Her bill shows in her row of the cooks
  // box, no other row offers her, she is not on the sign-up list, and a
  // save of Jane's cost names both cooks. The server deletes the bill of
  // a cook left out of that list (BillsPayload#write_to), so naming her
  // is what keeps her $40.
  test("a retired cook who did not eat keeps her bill when another cook's cost is saved", async ({
    page,
  }) => {
    const carol = {
      id: 4,
      meal_id: 42,
      name: "D - Carol Davis",
      short_name: "Carol Davis",
      attending: false,
      attending_at: null,
      late: false,
      vegetarian: false,
      can_cook: true,
      active: false,
    };
    const meal = {
      ...mealFixture,
      bills: [
        ...mealFixture.bills,
        { resident_id: 4, amount: "40.0", no_cost: false },
      ],
      residents: [...mealFixture.residents, carol],
    };
    await page.route("**/api/v1/meals/*/cooks*", (route) => {
      if (route.request().method() !== "GET") return route.fallback();
      fulfillJson(route, meal);
    });
    const billsPayloads = [];
    await page.route("**/api/v1/meals/*/bills*", (route) => {
      if (route.request().method() !== "PATCH") return route.fallback();
      billsPayloads.push(route.request().postDataJSON());
      fulfillJson(route, {
        message: "Form submitted.",
        bills: [
          { resident_id: 1, amount: "35.0", no_cost: false },
          { resident_id: 4, amount: "40.0", no_cost: false },
        ],
      });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Her bill shows in the second row, with her name and her cost.
    const cookSelects = page.getByRole("combobox", {
      name: "Select meal cook",
    });
    const costInputs = page.getByRole("spinbutton", { name: "Set meal cost" });
    await expect(cookSelects.nth(1)).toHaveValue("4", { timeout: 10000 });
    await expect(cookSelects.nth(1).locator("option:checked")).toHaveText(
      "D - Carol Davis",
    );
    await expect(costInputs.nth(1)).toHaveValue("40.00");

    // No other row offers her.
    await expect(cookSelects).toHaveCount(3);
    await expect(cookSelects.nth(0).locator('option[value="4"]')).toHaveCount(
      0,
    );
    await expect(cookSelects.nth(2).locator('option[value="4"]')).toHaveCount(
      0,
    );

    // She is not on the sign-up list; the people who are still show.
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("cell", { name: "D - Carol Davis", exact: true }),
    ).toHaveCount(0);

    // Change Jane's cost. The save names Carol too, without values, so
    // the server keeps her stored $40.
    const answer = page.waitForResponse(
      (r) => r.url().includes("/api/v1/meals/42/bills") && r.status() === 200,
    );
    await costInputs.first().fill("35.00");
    await answer;
    expect(billsPayloads).toHaveLength(1);
    expect(billsPayloads[0].bills).toEqual([
      { resident_id: 1, amount: "35.00", no_cost: false },
      { resident_id: 4 },
    ]);
    await expect(costInputs.nth(1)).toHaveValue("40.00");
  });

  test("guest icons (image assets) load correctly via Vite", async ({
    page,
  }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    // Jane's row should have a cow icon in the badge (non-veg guest)
    const janeRow = janeCell.locator("xpath=ancestor::tr");
    const cowIcon = janeRow.locator('.badge img[alt="cow-icon"]');
    await expect(cowIcon).toBeVisible();

    // Verify the image actually loaded (not a broken image)
    const naturalWidth = await cowIcon.evaluate((el) => el.naturalWidth);
    expect(naturalWidth).toBeGreaterThan(0);

    // Guest dropdown also has cow and carrot images (for adding guests)
    const dropdownCow = janeRow.locator(".dropdown-menu img[alt='cow-icon']");
    const dropdownCarrot = janeRow.locator(
      ".dropdown-menu img[alt='carrot-icon']",
    );
    // Open dropdown to make images visible
    await janeRow.locator(".dropdown-add").click();
    await expect(dropdownCow).toBeVisible({ timeout: 3000 });
    await expect(dropdownCarrot).toBeVisible();
  });

  test("closed meal shows extras radio buttons", async ({ page }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Extras section exists but is hidden (visibility:hidden) when meal is open
    const extrasContainer = page.locator('[aria-label="Set Extras to 0"]');
    // The parent div has visibility:hidden when open
    await expect(extrasContainer).toBeHidden();

    // Close the meal
    await page.locator("text=Open / Close Meal").click();
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 5000,
    });

    // Now extras radio buttons should be visible
    await expect(page.locator('[aria-label="Set Extras to 0"]')).toBeVisible({
      timeout: 3000,
    });
    await expect(page.locator('[aria-label="Set Extras to 3"]')).toBeVisible();

    // Click extras = 3
    await page.locator('[aria-label="Set Extras to 3"]').click({ force: true });

    // The checkbox for 3 should be checked
    await expect(page.locator('[aria-label="Set Extras to 3"]')).toBeChecked({
      timeout: 3000,
    });
  });

  test("meal history modal shows audit entries with correct data", async ({
    page,
  }) => {
    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Click history link
    const historyLink = page.locator("text=history").first();
    await expect(historyLink).toBeVisible({ timeout: 10000 });
    await historyLink.click();

    // Modal should open
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 5000 });

    // The fixture is the real audit trail of meal 42's story: signups,
    // the cook's bill, and the guest. User names are shortened, as the
    // AuditSerializer shortens them.
    await expect(
      modal.getByRole("cell", { name: "Jane" }).first(),
    ).toBeVisible();
    await expect(
      modal.getByRole("cell", { name: "Jane added", exact: true }),
    ).toBeVisible();
    await expect(
      modal.getByRole("cell", { name: "Alice added", exact: true }),
    ).toBeVisible();
    await expect(
      modal.getByRole("cell", { name: "Jane added as cook", exact: true }),
    ).toBeVisible();
    await expect(
      modal.getByRole("cell", { name: "Omnivore guest of Jane added" }),
    ).toBeVisible();

    // Table should have header columns
    await expect(
      modal.getByRole("columnheader", { name: "User" }),
    ).toBeVisible();
    await expect(
      modal.getByRole("columnheader", { name: "Action" }),
    ).toBeVisible();
    await expect(
      modal.getByRole("columnheader", { name: "Time" }),
    ).toBeVisible();
  });

  test("prev/next meal arrows load each meal's own data and neighbors", async ({
    page,
  }) => {
    // Every meal gets its own neighbors and its own menu, the way the
    // server sends them. With one shared payload, meal 43 would say
    // prev_id 41 like meal 42, and a stale prev_id could not be told
    // from the right one.
    const fetchedIds = [];
    await page.route("**/api/v1/meals/*/cooks*", (route) => {
      const mealId = Number(
        route
          .request()
          .url()
          .match(/\/meals\/(\d+)\//)[1],
      );
      fetchedIds.push(mealId);
      fulfillJson(route, {
        ...mealFixture,
        id: mealId,
        prev_id: mealId - 1,
        next_id: mealId + 1,
        description: `Menu ${mealId}`,
      });
    });

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    const menu = page.locator('[aria-label="Enter meal description"]');
    await expect(menu).toHaveValue("Menu 42", { timeout: 10000 });

    // Next goes to meal 43, which loads its own data.
    await page.getByRole("button", { name: "Next meal" }).click();
    await expect(page).toHaveURL(/\/meals\/43\/edit\/?$/, { timeout: 5000 });
    await expect(menu).toHaveValue("Menu 43");
    await expect(menu).toBeEnabled();

    // Prev on meal 43 uses meal 43's own prev_id: back to 42, not 41.
    await page.getByRole("button", { name: "Previous meal" }).click();
    await expect(page).toHaveURL(/\/meals\/42\/edit\/?$/, { timeout: 5000 });
    await expect(menu).toHaveValue("Menu 42");

    // Each page fetched its meal from the server, in order.
    expect(fetchedIds).toEqual([42, 43, 42]);
  });
});
