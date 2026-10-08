const { randomUUID } = require("crypto");
const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
const {
  loadAuthInfo,
  setupAuthenticatedPage,
  mealLoaded,
  gotoMeal,
  reloadMeal,
} = require("../helpers/integration_setup");

test.describe("Bill entry (real backend)", () => {
  let auth;

  test.beforeEach(async ({ page, context }) => {
    auth = loadAuthInfo();
    await setupAuthenticatedPage(page, context);
  });

  // The answer to the first bills save of this meal with an edit whose
  // `to` (the bill the person wants) passes `wanted`.
  function billsSaveAnswered(page, mealId, wanted) {
    return page.waitForResponse((r) => {
      if (r.request().method() !== "PATCH") return false;
      if (!r.url().includes(`/api/v1/meals/${mealId}/bills`)) return false;
      const body = r.request().postDataJSON();
      return body.edits.some(
        (edit) => edit.to !== undefined && wanted(edit.to),
      );
    });
  }

  // Bill saves are debounced, and picking a cook schedules a save of its
  // own. Waiting on the PATCH response whose request carried the typed
  // amount is the deterministic way to know that value reached the server.
  function billSaved(page, mealId, amount) {
    return billsSaveAnswered(page, mealId, (to) => to.amount === amount);
  }

  test("entering a bill amount persists across reload", async ({ page }) => {
    // Today's meal has no bills in the seed data
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // Select Jane as cook (use her resident_id as the option value)
    const cookSelect = page.locator('[aria-label="Select meal cook"]').first();
    await cookSelect.selectOption(String(auth.resident_id));

    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    const saved = billSaved(page, mealId, "65.00");
    await costInput.fill("65.00");
    await saved;

    // Reload and verify bill persisted
    await reloadMeal(page, mealId);

    const costInputAfter = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInputAfter).toHaveValue("65.00", { timeout: 10000 });

    // Restore: clear the bill by setting amount to 0
    const cleared = billSaved(page, mealId, "0");
    await costInputAfter.fill("0");
    await cleared;
  });

  // Typing "1", pausing past the debounce, then typing "0" used to
  // produce "1.00" with the "0" swallowed: the save's ack reformatted
  // the field under the cursor, and "1.00" plus "0" breaks the
  // whole-cents grammar. The ack must not touch a field it agrees with;
  // padding happens on blur instead.
  test("typing slowly across the save debounce keeps accepting keystrokes", async ({
    page,
  }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    const cookSelect = page.locator('[aria-label="Select meal cook"]').first();
    await cookSelect.selectOption(String(auth.resident_id));

    // Type "1", then pause: the debounce fires and the server answers.
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    const firstSave = billSaved(page, mealId, "1");
    await costInput.press("1");
    await firstSave;

    // The ack has arrived. Give it time to hit the store, then confirm
    // the field still shows exactly what was typed.
    await page.waitForTimeout(300);
    await expect(costInput).toHaveValue("1");

    // The late "0" keystroke must land.
    const secondSave = billSaved(page, mealId, "10");
    await costInput.press("0");
    await expect(costInput).toHaveValue("10");
    await secondSave;

    // Leaving the field pads the display.
    await costInput.blur();
    await expect(costInput).toHaveValue("10.00");

    // Restore: clear the bill for the other tests.
    const cleared = billSaved(page, mealId, "0");
    await costInput.fill("0");
    await cleared;
  });

  // Turning on "no cost" over a typed cost erases the cost, so the
  // switch asks first. Every exit except a deliberate Yes — the No
  // button, Escape, a click elsewhere — must leave the cost alone.
  test("the no-cost switch asks before erasing a typed cost", async ({
    page,
  }) => {
    const mealId = auth.meals.tomorrow.id;
    await gotoMeal(page, mealId);

    // Tomorrow's meal has Jane's $50.00 bill from the seed.
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("50.00", { timeout: 10000 });

    const switchLabel = page.locator('label[for^="no_cost_switch-"]').first();
    const noCostBox = page.locator('[aria-label^="No cost button"]').first();
    const confirm = page.locator(".confirm-bar");

    // The click alone changes nothing: the bar opens and asks.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await expect(confirm).toContainText("$50.00");
    await expect(costInput).toHaveValue("50.00");
    await expect(noCostBox).not.toBeChecked();

    // No keeps everything.
    await confirm.getByRole("button", { name: "No" }).click();
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("50.00");
    await expect(noCostBox).not.toBeChecked();

    // Escape is a No too.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("50.00");

    // A click anywhere else is also a No.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await page.locator("h2", { hasText: "Cooks" }).click();
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("50.00");

    // A deliberate Yes erases the cost and flips the switch. The Yes
    // button ignores clicks while it arms, so wait that out.
    await switchLabel.click();
    await expect(confirm).toBeVisible();
    await page.waitForTimeout(500);
    const erased = billsSaveAnswered(page, mealId, (to) => to.no_cost);
    await confirm.getByRole("button", { name: "Yes" }).click();
    await expect(confirm).toBeHidden();
    await expect(costInput).toHaveValue("");
    await expect(noCostBox).toBeChecked();
    await erased;

    // Turning the switch back off never asks — it destroys nothing.
    await switchLabel.click();
    await expect(confirm).toBeHidden();
    await expect(noCostBox).not.toBeChecked();

    // Restore the seed: put Jane's $50.00 back.
    const restored = billSaved(page, mealId, "50.00");
    await costInput.fill("50.00");
    await restored;
  });

  test("modifying an existing bill persists", async ({ page }) => {
    const mealId = auth.meals.tomorrow.id;
    await gotoMeal(page, mealId);

    // Change Jane's bill from $50.00 to $55.00
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("50.00", { timeout: 10000 });
    const saved = billSaved(page, mealId, "55.00");
    await costInput.fill("55.00");
    await saved;

    // Reload and verify
    await reloadMeal(page, mealId);

    const costInputAfter = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInputAfter).toHaveValue("55.00", { timeout: 10000 });

    // Restore: put it back to $50.00
    const restored = billSaved(page, mealId, "50.00");
    await costInputAfter.fill("50.00");
    await restored;
  });

  // A meal can close with a cook's cost still blank — after a Yes that
  // names the cook — and the cost can be entered on the closed meal.
  // Bills freeze at reconciliation, not at close.
  test("closing with a blank cost asks, and the cost can be entered after closing", async ({
    page,
  }) => {
    const mealId = auth.meals.today.id;
    await gotoMeal(page, mealId);
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    // Make sure a cook is assigned with no cost entered.
    const cookSelect = page.locator('[aria-label="Select meal cook"]').first();
    if ((await cookSelect.inputValue()) !== String(auth.resident_id)) {
      const assigned = page.waitForResponse(
        (r) =>
          r.request().method() === "PATCH" &&
          r.url().includes(`/api/v1/meals/${mealId}/bills`),
      );
      await cookSelect.selectOption(String(auth.resident_id));
      await assigned;
    }
    const costInput = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costInput).toHaveValue("");

    // Closing asks and names the cook; No keeps the meal open.
    const closeButton = page.locator("text=Open / Close Meal");
    const confirm = page.locator(".confirm-bar");
    await closeButton.click();
    await expect(confirm).toBeVisible();
    await expect(confirm).toContainText("entered a cost yet");
    await expect(confirm).toContainText("Jane");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();
    await confirm.getByRole("button", { name: "No" }).click();
    await expect(confirm).toBeHidden();
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible();

    // Yes closes the meal. Closing triggers a refetch that replaces the
    // bill rows — wait it out before typing into them.
    await closeButton.click();
    await expect(confirm).toBeVisible();
    const refetched = page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes(`/api/v1/meals/${mealId}`),
    );
    await confirm.getByRole("button", { name: "Yes" }).click();
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 5000,
    });
    await refetched;

    // The blank cost now reads "pending": the cook had the chance and
    // said later.
    await expect(costInput).toHaveAttribute("placeholder", "pending");

    // The cost field is still editable on the closed meal, and the
    // save sticks across a reload.
    await expect(costInput).toBeEnabled();
    const saved = billSaved(page, mealId, "12.00");
    await costInput.fill("12.00");
    await saved;

    await reloadMeal(page, mealId);
    const costAfter = page.locator('[aria-label="Set meal cost"]').first();
    await expect(costAfter).toBeEnabled({ timeout: 10000 });
    await expect(costAfter).toHaveValue("12.00");

    // Restore the seed: reopen the meal (no question in that
    // direction), wait out its refetch, then pick the blank in the
    // cook's row, which sends a save that removes her bill.
    const reopened = page.waitForResponse(
      (r) =>
        r.request().method() === "GET" &&
        r.url().includes(`/api/v1/meals/${mealId}`),
    );
    await page.locator("text=Open / Close Meal").click();
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 5000,
    });
    await reopened;
    const cleared = page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes(`/api/v1/meals/${mealId}/bills`),
    );
    await page
      .locator('[aria-label="Select meal cook"]')
      .first()
      .selectOption("");
    await cleared;
  });

  // The bills the server has for a meal, by cook id, read as Jane.
  async function storedBills(request, mealId) {
    const response = await request.get(`/api/v1/meals/${mealId}/cooks`, {
      headers: { Authorization: `Bearer ${auth.token}` },
    });
    expect(response.status(), await response.text()).toBe(200);
    const { bills } = await response.json();
    return new Map(
      bills.map((bill) => [
        bill.resident_id,
        { amount: bill.amount, no_cost: bill.no_cost },
      ]),
    );
  }

  // Sets a meal's bills straight through the API, as Jane. `wanted` is a
  // list of [cook id, bill] pairs: the cook gets that bill
  // ({ amount, no_cost }), or loses their bill when it is null. A cook
  // the list does not name keeps their bill. The bills are read first,
  // so each edit's `from` is the bill the server has now
  // (docs/adr/0009-bills-saves-send-edits.md).
  async function setBills(request, mealId, wanted) {
    const stored = await storedBills(request, mealId);
    const edits = [];
    for (const [residentId, to] of wanted) {
      const from = stored.get(residentId);
      if (to === null) {
        if (from !== undefined) {
          edits.push({ op: "remove", resident_id: residentId, from });
        }
      } else if (from === undefined) {
        edits.push({ op: "add", resident_id: residentId, to });
      } else {
        edits.push({ op: "change", resident_id: residentId, from, to });
      }
    }
    const response = await request.patch(`/api/v1/meals/${mealId}/bills`, {
      headers: {
        Authorization: `Bearer ${auth.token}`,
        "Idempotency-Key": `"${randomUUID()}"`,
      },
      data: { edits },
    });
    expect(response.status(), await response.text()).toBe(200);
  }

  // One cook's row in the cooks box: the row whose menu has this
  // resident picked.
  function cookRow(page, residentId) {
    return page.locator(".confirm-bar-anchor").filter({
      has: page.locator(
        `[aria-label="Select meal cook"] option[value="${residentId}"]:checked`,
      ),
    });
  }

  // #91. Diana cooked tomorrow's meal, did not eat, and is retired. The
  // server lists her in the meal form because she has a bill
  // (MealFormSerializer#residents), so the page shows her bill in her own
  // row. A save of another cook's cost names only that cook, and the
  // server never touches the bill of a cook a save does not name (#135),
  // so her $40 stays.
  test("a retired cook who did not eat keeps her bill when another cook's cost is saved", async ({
    page,
    request,
  }) => {
    const mealId = auth.meals.tomorrow.id;
    const jane = auth.resident_id;
    const diana = auth.diana_id;

    // Give Diana a $40 bill. Jane keeps her $50.00 from the seed.
    await setBills(request, mealId, [
      [diana, { amount: "40.00", no_cost: false }],
    ]);

    try {
      await gotoMeal(page, mealId);
      const janeCost = cookRow(page, jane).locator(
        '[aria-label="Set meal cost"]',
      );
      const dianaCost = cookRow(page, diana).locator(
        '[aria-label="Set meal cost"]',
      );

      // Her bill shows in her own row, with her name and her cost.
      await expect(
        cookRow(page, diana).locator(
          '[aria-label="Select meal cook"] option:checked',
        ),
      ).toHaveText("C - Diana Prince", { timeout: 10000 });
      await expect(dianaCost).toHaveValue("40.00");
      await expect(janeCost).toHaveValue("50.00");

      // Only her own row's menu offers her.
      await expect(
        page.locator(
          `[aria-label="Select meal cook"] option[value="${diana}"]`,
        ),
      ).toHaveCount(1);

      // She is not on the sign-up list. Jane's name shows first, so the
      // list is drawn and the check below is not passing on an empty
      // page.
      await expect(
        page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
      ).toBeVisible();
      await expect(
        page.getByRole("cell", { name: "C - Diana Prince", exact: true }),
      ).toHaveCount(0);

      // Change Jane's cost and wait for the save.
      const saved = billSaved(page, mealId, "55.00");
      await janeCost.fill("55.00");
      expect((await saved).status()).toBe(200);

      // After a reload, the page shows only what the server kept.
      await reloadMeal(page, mealId);
      await expect(janeCost).toHaveValue("55.00", { timeout: 10000 });
      await expect(dianaCost).toHaveValue("40.00");
      await expect(
        page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
      ).toBeVisible();
      await expect(
        page.getByRole("cell", { name: "C - Diana Prince", exact: true }),
      ).toHaveCount(0);
    } finally {
      // Put the seed back: Jane's $50.00, and no bill for Diana. The
      // chromium and webkit runs share one database.
      await setBills(request, mealId, [
        [jane, { amount: "50.00", no_cost: false }],
        [diana, null],
      ]);
    }
  });

  // A second tab in the same browser, set up like the test's own page.
  // tests/helpers/test.js checks only the test's own page for errors, so
  // this one keeps its own list: uncaught errors, and console errors that
  // `allowed` does not match.
  async function openSecondPage(context, allowed = null) {
    const second = await context.newPage();
    await setupAuthenticatedPage(second, context);
    const errors = [];
    second.on("pageerror", (error) => errors.push(String(error)));
    second.on("console", (message) => {
      if (message.type() !== "error") return;
      if (allowed && allowed.test(message.text())) return;
      errors.push(message.text());
    });
    return { page: second, errors };
  }

  // The cost box in a cook's row.
  function costOf(page, residentId) {
    return cookRow(page, residentId).locator('[aria-label="Set meal cost"]');
  }

  // Two pages are open on tomorrow's meal (#135). A save on one page shows
  // on the other only after a live update (a job, then Pusher, then a
  // fetch), and Pusher is off in this suite, so the second page keeps
  // showing the meal as it loaded it. A save used to list every cook its
  // page showed, and the server removed the bill of any cook the list left
  // out. A save now names only the cooks it changes.
  test.describe("two pages on one meal", () => {
    test("a cook one page adds keeps their bill when the other page saves its own cost", async ({
      page,
      context,
      request,
    }) => {
      const mealId = auth.meals.tomorrow.id;
      const jane = auth.resident_id;
      const bob = auth.bob_id;
      const other = await openSecondPage(context);

      try {
        await gotoMeal(page, mealId);
        await gotoMeal(other.page, mealId);
        await expect(costOf(other.page, jane)).toHaveValue("50.00", {
          timeout: 10000,
        });

        // This page adds Bob as a second cook, with $30.00.
        await page
          .locator('[aria-label="Select meal cook"]')
          .nth(1)
          .selectOption(String(bob));
        const added = billSaved(page, mealId, "30.00");
        await costOf(page, bob).fill("30.00");
        expect((await added).status()).toBe(200);

        // The other page does not show Bob. It saves Jane's new cost.
        await expect(costOf(other.page, bob)).toHaveCount(0);
        const saved = billSaved(other.page, mealId, "55.00");
        await costOf(other.page, jane).fill("55.00");
        expect((await saved).status()).toBe(200);

        // The server kept both bills, and the other page shows both once
        // it loads the meal again.
        expect(await storedBills(request, mealId)).toEqual(
          new Map([
            [jane, { amount: "55.0", no_cost: false }],
            [bob, { amount: "30.0", no_cost: false }],
          ]),
        );
        await reloadMeal(other.page, mealId);
        await expect(costOf(other.page, jane)).toHaveValue("55.00", {
          timeout: 10000,
        });
        await expect(costOf(other.page, bob)).toHaveValue("30.00");
        expect(other.errors).toEqual([]);
      } finally {
        await other.page.close();
        await setBills(request, mealId, [
          [jane, { amount: "50.00", no_cost: false }],
          [bob, null],
        ]);
      }
    });

    // Both pages loaded Jane's $50.00, and the other page saves $55.00
    // first. This page's save says it changes her cost from $50.00, which
    // the server no longer has, so the server writes nothing and answers
    // 409 with type "stale". This page shows the server's words, does not
    // send the save again, and loads the meal again, so it shows $55.00.
    test.describe(() => {
      test.use({ allowedConsoleErrors: httpFailurePattern });

      test("a save built on a cost the other page changed is refused, and the page says why", async ({
        page,
        context,
        request,
      }) => {
        const mealId = auth.meals.tomorrow.id;
        const jane = auth.resident_id;
        const other = await openSecondPage(context);

        try {
          await gotoMeal(page, mealId);
          await gotoMeal(other.page, mealId);
          await expect(costOf(page, jane)).toHaveValue("50.00", {
            timeout: 10000,
          });
          await expect(costOf(other.page, jane)).toHaveValue("50.00");

          const first = billSaved(other.page, mealId, "55.00");
          await costOf(other.page, jane).fill("55.00");
          expect((await first).status()).toBe(200);

          const saves = [];
          page.on("request", (sent) => {
            if (
              sent.method() === "PATCH" &&
              sent.url().includes(`/api/v1/meals/${mealId}/bills`)
            ) {
              saves.push(sent.postDataJSON());
            }
          });
          const refused = billSaved(page, mealId, "60.00");
          const loadedAgain = mealLoaded(page, mealId);
          await costOf(page, jane).fill("60.00");

          const answer = await refused;
          expect(answer.status()).toBe(409);
          expect((await answer.json()).type).toBe("stale");
          await expect(
            page.locator(".toast--error .toast__message"),
          ).toHaveText(
            "Nothing was saved, because this meal changed after you loaded it: Jane Smith's cost changed. Check the cooks and costs, then enter your change again.",
          );
          await loadedAgain;
          await expect(costOf(page, jane)).toHaveValue("55.00");
          expect(saves).toHaveLength(1);
          expect(await storedBills(request, mealId)).toEqual(
            new Map([[jane, { amount: "55.0", no_cost: false }]]),
          );
          expect(other.errors).toEqual([]);
        } finally {
          await other.page.close();
          await setBills(request, mealId, [
            [jane, { amount: "50.00", no_cost: false }],
          ]);
        }
      });
    });
  });

  // A save whose answer is lost (a dropped connection, or Heroku's router
  // giving up after 30 seconds while the request still runs) may or may
  // not have been written. So the page sends it once more, unchanged, with
  // the same Idempotency-Key. Here the first try was written, and before
  // the second try arrived someone else set the cost back. The second
  // try's `from` is then the stored bill again, so with a new key the
  // server would write it, and the other person's change would be gone
  // with no message to anyone. With the same key the server answers that
  // the save was already made, and writes nothing.
  test.describe(() => {
    test.use({
      allowedConsoleErrors: combinePatterns(
        httpFailurePattern,
        /^Error: no response received from server\.$/,
      ),
    });

    test("a save whose answer was lost is sent again with the same key, and is not written twice", async ({
      page,
      request,
    }) => {
      const mealId = auth.meals.tomorrow.id;
      const jane = auth.resident_id;

      const tries = [];
      await page.route(`**/api/v1/meals/${mealId}/bills*`, async (route) => {
        const sent = route.request();
        tries.push({
          key: sent.headers()["idempotency-key"],
          body: sent.postDataJSON(),
        });
        if (tries.length > 1) return route.fallback();
        // The server writes the first try...
        await route.fetch();
        // ...someone else sets the cost back to $50.00...
        await setBills(request, mealId, [
          [jane, { amount: "50.00", no_cost: false }],
        ]);
        // ...and the answer to the first try never reaches the page.
        return route.abort("connectionfailed");
      });

      try {
        await gotoMeal(page, mealId);
        await expect(costOf(page, jane)).toHaveValue("50.00", {
          timeout: 10000,
        });

        // An aborted request has no response, so this is the second try's.
        const secondTry = billSaved(page, mealId, "55.00");
        const loadedAgain = mealLoaded(page, mealId);
        await costOf(page, jane).fill("55.00");

        const answer = await secondTry;
        expect(answer.status()).toBe(200);
        expect((await answer.json()).type).toBe("replayed");
        expect(tries).toHaveLength(2);
        expect(tries[1]).toEqual(tries[0]);
        expect(await storedBills(request, mealId)).toEqual(
          new Map([[jane, { amount: "50.0", no_cost: false }]]),
        );

        // The answer holds $50.00, not what the page sent, so the page
        // loads the meal again and shows it. Nothing failed, so there is
        // no message.
        await loadedAgain;
        await expect(costOf(page, jane)).toHaveValue("50.00");
        await expect(page.locator(".toast--error")).toHaveCount(0);
      } finally {
        await setBills(request, mealId, [
          [jane, { amount: "50.00", no_cost: false }],
        ]);
      }
    });
  });
});
