// Admin actions, clicked through the real ActiveAdmin forms against the
// Rails server tests/admin/server.sh starts. One test per row of the
// action table (docs/agents/action-table.md) whose Browser cell used to
// be empty: the request specs prove each action's rules, and these prove
// that a person can reach the action from the page and see the result,
// or the refusal, as a sentence.
//
// The tests write through the forms, so each group below reloads the
// seed before its first test (a retry runs in a fresh worker and reloads
// again), and the file reloads it once more at the end, so admin.spec.js
// and visual.spec.js, which run after it, see the seed as
// tests/admin/seed.rb wrote it. A reload boots Rails, about five seconds,
// which is why it is once per group and not once per test. Inside a
// group every test works on its own rows, so no test depends on what an
// earlier one changed.
const { execFileSync } = require("node:child_process");
const { test, expect } = require("../helpers/test");
const { login } = require("./login");

// tests/admin/env.sh sets the same token for the server.
const READ_ONLY_TOKEN = "admin-e2e-readonly-token";

function reseed() {
  execFileSync("tests/admin/reseed.sh", { stdio: "inherit" });
}

function reseedBeforeGroup() {
  test.beforeAll(() => {
    test.setTimeout(120000);
    reseed();
  });
}

test.afterAll(() => {
  test.setTimeout(120000);
  reseed();
});

// The "Delete" action item on a show page: a link with a delete method
// that asks "Are you sure?" through a browser confirm. Accept it.
async function clickDelete(page) {
  page.once("dialog", (dialog) => dialog.accept());
  await page.locator('.action_items a[data-method="delete"]').click();
}

const notice = (page) => page.locator(".flash_notice");
const alert = (page) => page.locator(".flash_alert");
// A show-page panel by its exact heading ("Meals", not "Meals" inside
// "Number of meals").
const panel = (page, title) =>
  page
    .locator(".panel")
    .filter({ has: page.getByRole("heading", { name: title, exact: true }) });

test.describe("Meals", () => {
  reseedBeforeGroup();

  test("creates a meal", async ({ page }) => {
    await login(page);
    await page.goto("/meals/new");
    await page.fill("#meal_date", "2027-03-01");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Meal was successfully created.");
    await expect(page.locator(".row-date td")).toHaveText("March 01, 2027");
  });

  test("moves a meal to another date", async ({ page }) => {
    await login(page);
    await page.goto("/meals/1/edit");
    await expect(page.locator("#meal_date")).toHaveValue("2027-02-04");
    await page.fill("#meal_date", "2027-02-05");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Meal was successfully updated.");
    await expect(page.locator(".row-date td")).toHaveText("February 05, 2027");
    // The index shows the moved meal with its new weekday.
    await page.goto("/meals");
    await expect(
      page.locator("td.col-date", { hasText: "Fri, Feb 5 2027" }),
    ).toHaveCount(1);
    await expect(
      page.locator("td.col-date", { hasText: "Thu, Feb 4 2027" }),
    ).toHaveCount(0);
  });

  test("refuses to edit a reconciled meal", async ({ page }) => {
    await login(page);
    // Meal 3 was swept by reconciliation 1 in the seed.
    await page.goto("/meals/3/edit");

    await expect(page).toHaveURL(/\/meals\/3$/);
    await expect(alert(page)).toHaveText(
      "This meal is reconciled and cannot be modified.",
    );
  });

  test("deletes an open meal nobody touched", async ({ page }) => {
    await login(page);
    // Meal 2 (2027-02-02) has no bill, no attendee and no guest.
    await page.goto("/meals/2");
    await clickDelete(page);

    await expect(notice(page)).toHaveText("Meal was successfully destroyed.");
    await expect(
      page.locator("td.col-date", { hasText: "Tue, Feb 2 2027" }),
    ).toHaveCount(0);
  });

  test("refuses to delete a closed meal, with the reason", async ({ page }) => {
    await login(page);
    // Meal 4 is closed and not yet settled.
    await page.goto("/meals/4");
    await clickDelete(page);

    await expect(page).toHaveURL(/\/meals\/4$/);
    await expect(alert(page)).toHaveText(
      "Meal has been closed. Reopen it before deleting.",
    );
  });
});

test.describe("Settlement", () => {
  reseedBeforeGroup();

  test("settles a period from the reconciliation form", async ({ page }) => {
    await login(page);
    await page.goto("/reconciliations/new");
    // Meal 4 (2026-01-17, closed, one $20 bill) is the only unsettled meal
    // on or before this cutoff. The clock is frozen at 2026-01-20, so the
    // cutoff is in the past.
    await page.fill("#reconciliation_end_date", "2026-01-18");
    await page.click('input[type="submit"]');

    await expect(page).toHaveURL(/\/reconciliations\/2$/);
    await expect(notice(page)).toHaveText(
      "Reconciliation was successfully created.",
    );
    await expect(page.locator(".row-number_of_meals td")).toHaveText("1");
    // Bob cooked and Alice ate; the words come from BalanceDisplayHelper,
    // never a sign.
    const balances = panel(page, "Settlement Balances");
    await expect(balances).toContainText("Bob Baker");
    await expect(balances).toContainText("is owed");
    await expect(balances).toContainText("Alice Cook");
    await expect(balances).toContainText("owes");
    await expect(panel(page, "Meals")).toContainText("2026-01-17");
  });

  test("refuses a cutoff with nothing to settle", async ({ page }) => {
    await login(page);
    await page.goto("/reconciliations/new");
    // Meal 3 (2026-01-10) is already settled; the next meal with a bill
    // is on the 17th.
    await page.fill("#reconciliation_end_date", "2026-01-16");
    await page.click('input[type="submit"]');

    // The form is shown again with the reason; nothing was created.
    await expect(page).toHaveURL(/\/reconciliations$/);
    await expect(page.locator(".errors, .inline-errors")).toContainText(
      "No unreconciled meals with bills on or before this date.",
    );
  });

  test("shows the reconciliation page with balances and meals", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/reconciliations/1");

    await expect(page.locator(".row-number_of_meals td")).toHaveText("1");
    const residents = panel(page, "Settlement Balances");
    await expect(residents.locator("tbody tr")).toHaveCount(3);
    await expect(residents).toContainText("Alice Cook");
    await expect(residents).toContainText("is owed");
    const units = panel(page, "Unit Balances");
    await expect(units.locator("tbody tr")).toHaveCount(2);
    const meals = panel(page, "Meals");
    await expect(meals).toContainText("2026-01-10");
    await expect(meals).toContainText("Alice Cook");
  });

  test("shows a resident's settlement statement", async ({ page }) => {
    await login(page);
    // Alice cooked meal 3 and ate it; both lines are on her statement.
    await page.goto("/residents/1");

    const statement = panel(page, "Settlement statement");
    // One heading per settlement, under the panel's own title; this is
    // the seed's settlement, whichever others a test in this group added.
    const heading = statement.locator(".panel_contents h3", {
      has: page.locator('a[href$="/reconciliations/1"]'),
    });
    await expect(heading).toHaveCount(1);
    await expect(heading).toContainText("Jan 10, 2026");
    await expect(heading).toContainText("settled:");
    await expect(heading).toContainText("is owed");
    await expect(statement).toContainText("credited");
    await expect(statement).toContainText("charged");
  });
});

test.describe("Residents", () => {
  reseedBeforeGroup();

  test("creates a resident", async ({ page }) => {
    await login(page);
    await page.goto("/residents/new");
    await page.fill("#resident_name", "Dana New");
    await page.fill("#resident_email", "dana@example.com");
    await page.selectOption("#resident_unit_id", { label: "A" });
    await page.check("#resident_can_cook");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Resident was successfully created.");
    await expect(page.locator(".row-name td")).toHaveText("Dana New");
    await expect(page.locator(".row-unit td")).toHaveText("A");
    await expect(page.locator(".row-active td")).toHaveText("Yes");
  });

  test("renames a resident", async ({ page }) => {
    await login(page);
    await page.goto("/residents/3/edit");
    await expect(page.locator("#resident_name")).toHaveValue("Carol Baker");
    await page.fill("#resident_name", "Carol Brewer");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Resident was successfully updated.");
    await expect(page.locator(".row-name td")).toHaveText("Carol Brewer");
    await page.goto("/residents");
    await expect(page.locator("td.col-name")).toContainText([
      "Alice Cook",
      "Bob Baker",
      "Carol Brewer",
    ]);
  });

  test("retires a resident", async ({ page }) => {
    await login(page);
    // Alice, the only resident of unit A.
    await page.goto("/residents/1/edit");
    await page.uncheck("#resident_active");
    await page.click('input[type="submit"]');

    await expect(page.locator(".row-active td")).toHaveText("No");
    // The unit page lists active residents only.
    await page.goto("/units/1");
    await expect(page.locator(".attributes_table")).not.toContainText(
      "Alice Cook",
    );
  });

  test("changes a resident's price category by hand", async ({ page }) => {
    await login(page);
    // Carol is a child in the seed.
    await page.goto("/residents/3");
    await expect(page.locator(".row-category td")).toHaveText("Child");
    await page.goto("/residents/3/edit");
    await page
      .locator("#resident_multiplier_input label", { hasText: "Adult" })
      .click();
    await page.click('input[type="submit"]');

    await expect(page.locator(".row-category td")).toHaveText("Adult");
  });

  test("moves a resident to another unit", async ({ page }) => {
    await login(page);
    // Bob, from unit B to unit A.
    await page.goto("/residents/2/edit");
    await page.selectOption("#resident_unit_id", { label: "A" });
    await page.click('input[type="submit"]');

    await expect(page.locator(".row-unit td")).toHaveText("A");
    await page.goto("/units/1");
    await expect(page.locator(".attributes_table")).toContainText("Bob Baker");
    await page.goto("/units/2");
    await expect(page.locator(".attributes_table")).not.toContainText(
      "Bob Baker",
    );
  });

  test("grants and removes the reconciler role", async ({ page }) => {
    await login(page);
    await page.goto("/residents/2");
    await expect(page.locator(".row-can_reconcile td")).toHaveText("No");

    await page.goto("/residents/2/edit");
    await page.check("#resident_can_reconcile");
    await page.click('input[type="submit"]');
    await expect(page.locator(".row-can_reconcile td")).toHaveText("Yes");

    await page.goto("/residents/2/edit");
    await page.uncheck("#resident_can_reconcile");
    await page.click('input[type="submit"]');
    await expect(page.locator(".row-can_reconcile td")).toHaveText("No");
  });

  test("refuses to delete a resident with ledger rows, with the reason", async ({
    page,
  }) => {
    await login(page);
    // Alice cooked meal 3, which is settled.
    await page.goto("/residents/1");
    await clickDelete(page);

    await expect(page).toHaveURL(/\/residents$/);
    await expect(alert(page)).toHaveText(
      "Cannot delete record because dependent bills exist",
    );
    await expect(
      page.locator("td.col-name", { hasText: "Alice Cook" }),
    ).toHaveCount(1);
  });

  test("deletes a resident created by mistake", async ({ page }) => {
    await login(page);
    await page.goto("/residents/new");
    await page.fill("#resident_name", "Typo Person");
    await page.fill("#resident_email", "typo@example.com");
    await page.selectOption("#resident_unit_id", { label: "A" });
    await page.click('input[type="submit"]');
    await expect(notice(page)).toHaveText("Resident was successfully created.");

    await clickDelete(page);

    await expect(notice(page)).toHaveText(
      "Resident was successfully destroyed.",
    );
    await expect(
      page.locator("td.col-name", { hasText: "Typo Person" }),
    ).toHaveCount(0);
  });

  test("lists residents by name with their birthdays", async ({ page }) => {
    await login(page);
    await page.goto("/residents");

    const names = await page.locator("td.col-name").allTextContents();
    expect(names.length).toBeGreaterThanOrEqual(3);
    expect(names).toEqual([...names].sort());
    // Carol is the one resident with a birthday.
    const carol = page.locator("tbody tr", { hasText: "Carol" });
    await expect(carol.locator("td.col-birthday")).toHaveText("May 06, 2018");
  });
});

test.describe("Units", () => {
  reseedBeforeGroup();

  test("creates a unit", async ({ page }) => {
    await login(page);
    await page.goto("/units/new");
    await page.fill("#unit_name", "C");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Unit was successfully created.");
    await expect(page.locator(".row-name td")).toHaveText("C");
  });

  test("renames a unit", async ({ page }) => {
    await login(page);
    await page.goto("/units/1/edit");
    await expect(page.locator("#unit_name")).toHaveValue("A");
    await page.fill("#unit_name", "A1");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Unit was successfully updated.");
    await expect(page.locator(".row-name td")).toHaveText("A1");
    // Alice lives in it; the residents index shows the new name.
    await page.goto("/residents");
    await expect(
      page
        .locator("tbody tr", { hasText: "Alice Cook" })
        .locator("td.col-unit"),
    ).toHaveText("A1");
  });

  test("refuses to delete a unit with residents, with the reason", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/units/2");
    await clickDelete(page);

    await expect(page).toHaveURL(/\/units$/);
    await expect(alert(page)).toHaveText(
      "Cannot delete record because dependent residents exist",
    );
  });

  test("deletes an empty unit", async ({ page }) => {
    await login(page);
    await page.goto("/units/new");
    await page.fill("#unit_name", "Empty");
    await page.click('input[type="submit"]');
    await expect(notice(page)).toHaveText("Unit was successfully created.");

    await clickDelete(page);

    await expect(notice(page)).toHaveText("Unit was successfully destroyed.");
    await expect(page.locator("td.col-name", { hasText: "Empty" })).toHaveCount(
      0,
    );
  });
});

test.describe("Rotations", () => {
  reseedBeforeGroup();

  test("refuses to delete a rotation with a cook, with the reason", async ({
    page,
  }) => {
    await login(page);
    // Rotation 1's meal 1 has a bill, so the rotation is touched.
    await page.goto("/rotations/1");
    await clickDelete(page);

    await expect(page).toHaveURL(/\/rotations$/);
    await expect(alert(page)).toContainText(
      "Only an untouched upcoming rotation can be deleted.",
    );
    await expect(page.locator("tbody tr")).toHaveCount(1);
  });
});

test.describe("Community settings", () => {
  reseedBeforeGroup();

  test("changes the cap", async ({ page }) => {
    await login(page);
    await page.goto("/communities/1");
    await expect(page.locator(".row-cap td")).toHaveText("$4.50");

    await page.goto("/communities/1/edit");
    await expect(page.locator("#community_cap")).toHaveValue("4.50");
    await page.fill("#community_cap", "5.25");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText(
      "Community was successfully updated.",
    );
    await expect(page.locator(".row-cap td")).toHaveText("$5.25");
  });

  test("changes the child pricing ages", async ({ page }) => {
    await login(page);
    await page.goto("/communities/1/edit");
    await page.fill("#community_free_below_age", "3");
    await page.fill("#community_full_price_age", "14");
    await page.click('input[type="submit"]');

    await expect(page.locator(".row-child_pricing td")).toHaveText(
      "Children under 3 eat free, children 3 to 13 pay half price, and everyone 14 and older pays full price.",
    );
  });

  test("changes a dinner start time", async ({ page }) => {
    await login(page);
    await page.goto("/communities/1/edit");
    // Monday is wday 1.
    await page.fill("#community_dinner_start_time_1", "18:30");
    await page.click('input[type="submit"]');

    const times = panel(page, "Dinner start times");
    await expect(times.locator("tr", { hasText: "Monday" })).toContainText(
      "18:30",
    );
    await expect(times.locator("tr", { hasText: "Tuesday" })).toContainText(
      "19:00",
    );
  });

  test("changes the time zone", async ({ page }) => {
    await login(page);
    await page.goto("/communities/1/edit");
    await page.selectOption("#community_timezone", {
      label: "Central Time (US & Canada)",
    });
    await page.click('input[type="submit"]');

    await expect(page.locator(".row-timezone td")).toHaveText(
      "America/Chicago",
    );
  });

  test("changes the week grid and meals per rotation, with a live preview", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/communities/1/edit");

    const preview = page.locator("#schedule-preview");
    await expect(preview).toContainText("Upcoming meals under this schedule:");
    const before = await preview.textContent();

    // Add Saturday (wday 6) to the first week row and shorten the rotation.
    await page.check('input[name="community[schedule][0][]"][value="6"]');
    await page.fill("#community_meals_per_rotation", "3");
    await expect(preview.locator("li")).toHaveCount(3);
    expect(await preview.textContent()).not.toBe(before);

    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText(
      "Community was successfully updated.",
    );
    const schedule = panel(page, "Meal schedule");
    await expect(schedule).toContainText("Saturday");
    await expect(
      schedule.locator("tr", { hasText: "Meals per rotation" }),
    ).toContainText("3");
  });
});

test.describe("Admin accounts", () => {
  reseedBeforeGroup();

  test("creates an admin, promotes them, and deletes them", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/admin_users/new");
    await page.fill("#admin_user_email", "new-admin@example.com");
    await page.fill("#admin_user_password", "a-long-enough-password");
    await page.fill(
      "#admin_user_password_confirmation",
      "a-long-enough-password",
    );
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText(
      "Admin user was successfully created.",
    );
    await expect(page.locator(".row-email td")).toHaveText(
      "new-admin@example.com",
    );
    await expect(page.locator(".row-superuser td")).toHaveText("No");

    // Promote without touching the password fields: the form posts them
    // empty, and an empty field means "keep the password".
    await page.locator(".action_items a", { hasText: "Edit" }).click();
    await page.check("#admin_user_superuser");
    await page.click('input[type="submit"]');
    await expect(page.locator(".row-superuser td")).toHaveText("Yes");

    await page.locator(".action_items a", { hasText: "Edit" }).click();
    await page.uncheck("#admin_user_superuser");
    await page.click('input[type="submit"]');
    await expect(page.locator(".row-superuser td")).toHaveText("No");

    await clickDelete(page);
    await expect(notice(page)).toHaveText(
      "Admin user was successfully destroyed.",
    );
    await expect(
      page.locator("td.col-email", { hasText: "new-admin@example.com" }),
    ).toHaveCount(0);
  });

  test("cannot demote or delete yourself", async ({ page }) => {
    await login(page);
    await page.goto("/admin_users/1/edit");
    // The flag is not offered on your own form.
    await expect(page.locator("#admin_user_superuser")).toHaveCount(0);

    await page.goto("/admin_users/1");
    await clickDelete(page);

    await expect(page).toHaveURL(/\/admin_users\/1$/);
    await expect(alert(page)).toHaveText(
      "You cannot delete your own account. Ask another superuser to do it.",
    );
  });
});

test.describe("Read-only token", () => {
  reseedBeforeGroup();

  test("reads the pages the emails link to, and nothing else", async ({
    page,
  }) => {
    // No login: the token is the session.
    await page.goto(`/bills?token=${READ_ONLY_TOKEN}`);
    await expect(page.locator("#page_title")).toHaveText("Cooking Slots");
    await expect(page.locator("tbody tr")).toHaveCount(3);

    await page.goto(`/residents/1?token=${READ_ONLY_TOKEN}`);
    await expect(panel(page, "Settlement statement")).toBeVisible();

    // Admin accounts are not on the allowlist. The refusal sends the
    // visitor to the dashboard without the token, and the dashboard sends
    // a signed-out visitor to the login page.
    await page.goto(`/admin_users?token=${READ_ONLY_TOKEN}`);
    await expect(page).toHaveURL(/\/login$/);
    await expect(alert(page)).toHaveText(
      "You need to sign in or sign up before continuing.",
    );

    // Nor is any write.
    await page.goto(`/residents/1/edit?token=${READ_ONLY_TOKEN}`);
    await expect(page).toHaveURL(/\/login$/);
  });

  test("a wrong token is just a signed-out visitor", async ({ page }) => {
    await page.goto("/bills?token=wrong");
    await expect(page).toHaveURL(/\/login$/);
  });
});
