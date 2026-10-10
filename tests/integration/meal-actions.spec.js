const dayjs = require("dayjs");
const advancedFormat = require("dayjs/plugin/advancedFormat");
const { randomUUID } = require("crypto");
const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
const {
  FAKE_TODAY,
  loadAuthInfo,
  setupAuthenticatedPage,
  mealLoaded,
  gotoMeal,
  reloadMeal,
  mealWritten,
} = require("../helpers/integration_setup");

dayjs.extend(advancedFormat);

// Every meal-page action against the real backend (plan item 4).
// The pattern throughout: perform the action, wait for the server to
// answer the write, reload the page, assert the state came back from
// the database. Tests restore what they change so the suite can run
// in any order and repeatedly against one seeding, and preconditions
// are read from the page rather than assumed, so a run that stopped
// half way cannot break the next one.

const auth = loadAuthInfo();

test.describe("Meal actions (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  // Waits for a PATCH to this meal's endpoint to succeed.
  function patched(page, mealId, pathPart) {
    return mealWritten(page, mealId, "PATCH", pathPart);
  }

  test("veg toggle persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    const residentId = auth.resident_id; // Jane attends today's meal
    await gotoMeal(page, mealId);
    const vegSwitch = page.locator(`#veg_switch_${residentId}`);
    await expect(vegSwitch).toBeVisible({ timeout: 10000 });
    const wasChecked = await vegSwitch.isChecked();

    let saved = patched(page, mealId, "residents");
    await page.locator(`label[for="veg_switch_${residentId}"]`).click();
    await saved;

    await reloadMeal(page, mealId);
    await expect(vegSwitch).toBeChecked({
      checked: !wasChecked,
      timeout: 10000,
    });

    // Restore.
    saved = patched(page, mealId, "residents");
    await page.locator(`label[for="veg_switch_${residentId}"]`).click();
    await saved;
    await reloadMeal(page, mealId);
    await expect(vegSwitch).toBeChecked({
      checked: wasChecked,
      timeout: 10000,
    });
  });

  test("removing a guest persists across reload", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    const janeRow = page
      .getByRole("cell", { name: "A - Jane Smith", exact: true })
      .locator("xpath=ancestor::tr");
    await expect(janeRow).toBeVisible({ timeout: 10000 });
    const initialBadges = await janeRow.locator(".badge img").count();

    // Add a guest, then remove it — covers the remove path without
    // touching the seeded guest other tests count.
    const added = page.waitForResponse(
      (r) =>
        r.request().method() === "POST" &&
        r.url().includes("/guests") &&
        r.ok(),
    );
    await janeRow.locator(".dropdown-add").click();
    const dropdownMenu = janeRow.locator(".dropdown-menu");
    await expect(dropdownMenu).toBeVisible({ timeout: 3000 });
    await dropdownMenu.locator("img[alt='cow-icon']").click();
    await added;
    await reloadMeal(page, mealId);
    await expect
      .poll(() => janeRow.locator(".badge img").count(), { timeout: 10000 })
      .toBe(initialBadges + 1);

    const removed = page.waitForResponse(
      (r) =>
        r.request().method() === "DELETE" &&
        r.url().includes("/guests") &&
        r.ok(),
    );
    await janeRow
      .locator('[aria-label="Remove Guest of A - Jane Smith"]')
      .click();
    await removed;
    await reloadMeal(page, mealId);
    await expect
      .poll(() => janeRow.locator(".badge img").count(), { timeout: 10000 })
      .toBe(initialBadges);
  });

  // #134. Diana is retired. A host can add a guest without signing up,
  // and here she has one on the future meal, added through the API. The
  // server lists her in the meal form because of the guest
  // (MealFormSerializer#residents). The page shows her row while she has
  // a guest there, so the guest can be seen and removed. The row is not
  // there to sign her up, and nobody can. After the next load, with no
  // guest and no sign-up, she is off the list again.
  test("a retired host's guest shows in her row and can be removed", async ({
    page,
    request,
  }) => {
    const mealId = auth.meals.future.id;
    const diana = auth.diana_id;
    const headers = { Authorization: `Bearer ${auth.token}` };
    const dianaCell = page.getByRole("cell", {
      name: "C - Diana Prince",
      exact: true,
    });
    const dianaRow = dianaCell.locator("xpath=ancestor::tr");

    const added = await request.post(
      `/api/v1/meals/${mealId}/residents/${diana}/guests`,
      {
        headers: { ...headers, "Idempotency-Key": `"${randomUUID()}"` },
        data: { vegetarian: false },
      },
    );
    expect(added.status(), await added.text()).toBe(200);
    const guestId = (await added.json()).id;

    try {
      await gotoMeal(page, mealId);
      await expect(dianaCell).toBeVisible({ timeout: 10000 });
      await expect(dianaCell).not.toHaveClass(/background-green/);
      await expect(dianaRow.locator(".badge img[alt='cow-icon']")).toHaveCount(
        1,
      );
      await expect(
        dianaRow.getByLabel("Toggle Late for C - Diana Prince"),
      ).toBeDisabled();
      await expect(
        dianaRow.getByLabel("Toggle Veg for C - Diana Prince"),
      ).toBeDisabled();
      await expect(dianaCell).toHaveCSS("pointer-events", "none");

      const removed = mealWritten(
        page,
        mealId,
        "DELETE",
        `residents/${diana}/guests/${guestId}`,
      );
      await dianaRow
        .locator('[aria-label="Remove Guest of C - Diana Prince"]')
        .click();
      await removed;

      // The row stays until the next load, so a wrong tap could be
      // undone by adding the guest again.
      await expect(dianaRow.locator(".badge img")).toHaveCount(0);
      await expect(dianaCell).toBeVisible();

      // Jane's name shows first, so the list is drawn and the check
      // below is not passing on an empty page.
      await reloadMeal(page, mealId);
      await expect(
        page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
      ).toBeVisible({ timeout: 10000 });
      await expect(dianaCell).toHaveCount(0);
    } finally {
      // Remove any guest of hers the page did not remove. The chromium
      // and webkit runs share one database.
      const form = await request.get(`/api/v1/meals/${mealId}/cooks`, {
        headers,
      });
      const left = (await form.json()).guests.filter(
        (guest) => guest.resident_id === diana,
      );
      for (const guest of left) {
        await request.delete(
          `/api/v1/meals/${mealId}/residents/${diana}/guests/${guest.id}`,
          { headers },
        );
      }
    }
  });

  // A guest add whose answer is lost (a dropped connection, or Heroku's
  // router giving up after 30 seconds while the request still runs) may
  // or may not have been written. The page cannot tell, so it shows no
  // guest, and the person taps again. Here the first try was written.
  // With a new request the second tap adds a second guest, and the host
  // pays for two. The second tap sends the first one's Idempotency-Key
  // instead, so the server answers that the guest was already added,
  // and adds nothing. The meal's own reload after no answer is held
  // back, so the page still shows no guest when the person taps again.
  test.describe(() => {
    // The meal's own reload is aborted here, and the page logs that
    // failed load.
    test.use({
      allowedConsoleErrors: combinePatterns(
        httpFailurePattern,
        /^Error: no response received from server\.$/,
      ),
    });

    test("a guest add whose answer was lost, tapped again, adds one guest", async ({
      page,
      request,
    }) => {
      const mealId = auth.meals.future.id;
      const jane = auth.resident_id;
      const headers = { Authorization: `Bearer ${auth.token}` };
      const janeRow = page
        .getByRole("cell", { name: "A - Jane Smith", exact: true })
        .locator("xpath=ancestor::tr");
      const guestsUrl = `/api/v1/meals/${mealId}/residents/${jane}/guests`;
      async function janesGuests() {
        const form = await request.get(`/api/v1/meals/${mealId}/cooks`, {
          headers,
        });
        return (await form.json()).guests.filter(
          (guest) => guest.resident_id === jane,
        );
      }
      async function addGuest() {
        await janeRow.locator(".dropdown-add").click();
        await janeRow
          .locator(".dropdown-menu")
          .locator("img[alt='cow-icon']")
          .click();
      }

      const before = (await janesGuests()).map((guest) => guest.id);
      const keys = [];
      await page.route(`**${guestsUrl}`, async (route) => {
        keys.push(route.request().headers()["idempotency-key"]);
        if (keys.length > 1) return route.fallback();
        // The server writes the first try, and its answer never
        // reaches the page.
        await route.fetch();
        return route.abort("connectionfailed");
      });

      try {
        await gotoMeal(page, mealId);
        await expect(janeRow).toBeVisible({ timeout: 10000 });
        await expect(janeRow.locator(".badge img")).toHaveCount(before.length);
        await page.route(`**/api/v1/meals/${mealId}/cooks`, (route) =>
          route.abort("connectionfailed"),
        );

        const lost = page.waitForEvent("requestfailed", (r) =>
          r.url().endsWith(guestsUrl),
        );
        await addGuest();
        await lost;
        await expect(janeRow.locator(".badge img")).toHaveCount(before.length);

        const secondTry = page.waitForResponse(
          (r) => r.request().method() === "POST" && r.url().endsWith(guestsUrl),
        );
        await addGuest();
        const answer = await secondTry;

        expect(await janesGuests()).toHaveLength(before.length + 1);
        expect(answer.status()).toBe(200);
        expect((await answer.json()).type).toBe("replayed");
        expect(keys).toHaveLength(2);
        expect(keys[0]).toMatch(/^"[0-9a-f-]{36}"$/);
        expect(keys[1]).toBe(keys[0]);
        await expect(janeRow.locator(".badge img")).toHaveCount(
          before.length + 1,
        );
      } finally {
        await page.unrouteAll({ behavior: "ignoreErrors" });
        for (const guest of await janesGuests()) {
          if (before.includes(guest.id)) continue;
          await request.delete(`${guestsUrl}/${guest.id}`, { headers });
        }
      }
    });
  });

  test("selecting a cook persists across reload", async ({ page }) => {
    const mealId = auth.meals.tomorrow.id;
    await gotoMeal(page, mealId);
    const cookSelects = page.locator('[aria-label="Select meal cook"]');
    await expect(cookSelects.first()).toBeVisible({ timeout: 10000 });

    // Slot 2 is empty (slot 1 is Jane, who holds the seeded bill).
    // Option labels carry the unit prefix, so match by substring and
    // select by value.
    const secondSlot = cookSelects.nth(1);
    const bobValue = await secondSlot.evaluate((s) => {
      const option = Array.from(s.options).find((o) =>
        o.textContent.includes("Bob Johnson"),
      );
      return option && option.value;
    });
    expect(bobValue).toBeTruthy();

    let saved = patched(page, mealId, "bills");
    await secondSlot.selectOption(bobValue);
    await saved;

    await reloadMeal(page, mealId);
    await expect(cookSelects.nth(1)).toHaveValue(bobValue, { timeout: 10000 });

    // Restore the empty slot.
    saved = patched(page, mealId, "bills");
    await cookSelects.nth(1).selectOption({ index: 0 });
    await saved;
    await reloadMeal(page, mealId);
    await expect(cookSelects.nth(1)).not.toHaveValue(bobValue, {
      timeout: 10000,
    });
  });

  test("meal description edit persists across reload", async ({ page }) => {
    const mealId = auth.meals.future.id;
    await gotoMeal(page, mealId);
    const textarea = page.locator('[aria-label="Enter meal description"]');
    await expect(textarea).toBeVisible({ timeout: 10000 });

    let saved = patched(page, mealId, "description");
    await textarea.fill("Soup and fresh bread");
    await saved;

    await reloadMeal(page, mealId);
    await expect(textarea).toHaveValue("Soup and fresh bread", {
      timeout: 10000,
    });

    // Restore the blank description the seed gives this meal.
    saved = patched(page, mealId, "description");
    await textarea.fill("");
    await saved;
    await reloadMeal(page, mealId);
    await expect(textarea).toHaveValue("", { timeout: 10000 });
  });

  test("closing and reopening a meal persists across reload", async ({
    page,
  }) => {
    const mealId = auth.meals.close_test.id;
    // The status heading says OPEN while the page has no meal yet, so
    // each check first waits for this meal's own description.
    const description = page.locator('[aria-label="Enter meal description"]');
    const status = page.locator("h1");
    await gotoMeal(page, mealId);
    await expect(description).toHaveValue("Close-test casserole", {
      timeout: 10000,
    });
    await expect(status).toHaveText("OPEN");

    // Close. The seeded cook cost means no blank-cost question
    // (bill-entry.spec.js owns that flow). Closing triggers a refetch
    // of /cooks; await it so the reload cannot cancel it mid-flight
    // (WebKit logs a cancelled request as a console error).
    let refetched = mealLoaded(page, mealId);
    let saved = patched(page, mealId, "closed");
    await page.locator("text=Open / Close Meal").click();
    await saved;
    await refetched;
    await reloadMeal(page, mealId);
    await expect(description).toHaveValue("Close-test casserole", {
      timeout: 10000,
    });
    await expect(status).toHaveText("CLOSED");

    // Reopen.
    refetched = mealLoaded(page, mealId);
    saved = patched(page, mealId, "closed");
    await page.locator("text=Open / Close Meal").click();
    await saved;
    await refetched;
    await reloadMeal(page, mealId);
    await expect(description).toHaveValue("Close-test casserole", {
      timeout: 10000,
    });
    await expect(status).toHaveText("OPEN");
  });

  test("setting extras on a closed meal persists across reload", async ({
    page,
  }) => {
    const mealId = auth.meals.closed.id;
    await gotoMeal(page, mealId);
    const extrasBoxes = page.locator('[aria-label^="Set Extras to"]');
    await expect(extrasBoxes.first()).toBeVisible({ timeout: 10000 });

    // Read the current value instead of assuming it, pick a different
    // one, and restore at the end. An extras save also refetches
    // /cooks; await it before reloading (same WebKit concern as the
    // close test).
    const before = await extrasBoxes.evaluateAll(
      (boxes) => (boxes.find((b) => b.checked) || {}).value,
    );
    const target = before === "2" ? "3" : "2";
    const targetBox = page.locator(`[aria-label="Set Extras to ${target}"]`);

    let refetched = mealLoaded(page, mealId);
    let saved = patched(page, mealId, "max");
    await targetBox.click();
    await saved;
    await refetched;
    await reloadMeal(page, mealId);
    await expect(targetBox).toBeChecked({ timeout: 10000 });

    if (before !== undefined) {
      refetched = mealLoaded(page, mealId);
      saved = patched(page, mealId, "max");
      await page.locator(`[aria-label="Set Extras to ${before}"]`).click();
      await saved;
      await refetched;
      await reloadMeal(page, mealId);
      await expect(
        page.locator(`[aria-label="Set Extras to ${before}"]`),
      ).toBeChecked({ timeout: 10000 });
    }
  });

  test("history modal opens with real data", async ({ page }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    const historyButton = page.locator("text=history").first();
    await expect(historyButton).toBeVisible({ timeout: 10000 });
    await historyButton.click();

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    // The modal lists this meal's own changes, by first name. The seed
    // created today's meal and signed Jane and Alice up to it, so those
    // three rows are always there, whatever the other tests changed on
    // this meal since.
    await expect(modal.locator("h1")).toHaveText(
      dayjs(FAKE_TODAY).format("ddd, MMM Do"),
      { timeout: 10000 },
    );
    for (const action of ["Meal record created", "Jane added", "Alice added"]) {
      await expect(
        modal.getByRole("cell", { name: action, exact: true }),
      ).toBeVisible();
    }
  });

  test("webcal subscribe links carry the community and resident", async ({
    page,
  }) => {
    await page.goto(`/calendar/all/${auth.meals.today.date}/`);
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });

    const links = page.locator('a[href^="webcal://"]');
    await expect(links).toHaveCount(2);
    const hrefs = await links.evaluateAll((as) => as.map((a) => a.href));
    expect(hrefs.some((h) => h.includes(`/communities/`))).toBe(true);
    expect(
      hrefs.some((h) => h.includes(`/residents/${auth.resident_id}/ical.ics`)),
    ).toBe(true);
  });
});
