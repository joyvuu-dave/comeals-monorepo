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
// A table row inside a panel, by the exact text of one of its cells.
const row = (container, name) =>
  container.locator("tbody tr").filter({
    has: container.page().getByRole("cell", { name, exact: true }),
  });

test.describe("Meals", () => {
  reseedBeforeGroup();

  // The New Meal form's rotation menu (#100). The seed has two
  // rotations: rotation 2 ("Rotation 1") with meals on 2026-01-02,
  // 2026-01-04, 2026-01-05 and 2026-01-06, and rotation 1 ("Rotation 2")
  // with meals on 2027-02-02 and 2027-02-04. The script in active_admin.js chooses the rotation
  // whose dates contain the date typed.
  test("picks the rotation by date and creates a meal", async ({ page }) => {
    await login(page);
    await page.goto("/meals/new");
    const rotationMenu = page.locator("#meal_rotation_id");
    await expect(rotationMenu).toHaveValue("");
    // A day before rotation 1's first meal: nothing is chosen.
    await page.fill("#meal_date", "2027-02-01");
    await expect(rotationMenu).toHaveValue("");
    // Pick the 3rd in the datepicker, the way an admin does. A key press
    // makes the datepicker read the typed date and show February 2027.
    await page.locator("#meal_date").press("End");
    await page
      .locator(".ui-datepicker:visible")
      .getByRole("link", { name: "3", exact: true })
      .click();
    await expect(page.locator("#meal_date")).toHaveValue("2027-02-03");
    await expect(rotationMenu).toHaveValue("1");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Meal was successfully created.");
    await expect(page.locator(".row-date td")).toHaveText("February 03, 2027");
    // The rotation's page lists the new meal.
    await page.goto("/rotations/1");
    await expect(
      page.getByRole("link", { name: "2027-02-03", exact: true }),
    ).toBeVisible();
  });

  // A gap date is one between two rotations. The menu is blank after the
  // last rotation too, but that date is refused (the group after this
  // one).
  test("asks for a rotation for a gap date", async ({ page }) => {
    await login(page);
    await page.goto("/meals/new");
    const rotationMenu = page.locator("#meal_rotation_id");
    // Inside rotation 1 first, so the menu has a choice to clear.
    await page.fill("#meal_date", "2027-02-03");
    await expect(rotationMenu).toHaveValue("1");
    // After the last rotation.
    await page.fill("#meal_date", "2027-03-01");
    await expect(rotationMenu).toHaveValue("");
    // Between the two rotations.
    await page.fill("#meal_date", "2026-06-01");
    await expect(rotationMenu).toHaveValue("");

    // Saved with no rotation: refused, with the reason.
    await page.click('input[type="submit"]');
    await expect(page).toHaveURL(/\/meals$/);
    await expect(page.locator(".errors")).toContainText(
      "Rotation must be chosen. Every meal belongs to a rotation.",
    );

    // The admin chooses one, and the meal saves.
    await page.selectOption("#meal_rotation_id", {
      label: "Rotation 1: Jan 2–6, 2026",
    });
    await page.click('input[type="submit"]');
    await expect(notice(page)).toHaveText("Meal was successfully created.");
    await expect(page.locator(".row-date td")).toHaveText("June 01, 2026");
    await page.goto("/rotations/2");
    await expect(
      page.getByRole("link", { name: "2026-06-01", exact: true }),
    ).toBeVisible();
  });

  // To an earlier day: a later one is after the last rotation (the
  // next group).
  test("moves a meal to another date", async ({ page }) => {
    await login(page);
    await page.goto("/meals/1/edit");
    await expect(page.locator("#meal_date")).toHaveValue("2027-02-04");
    await page.fill("#meal_date", "2027-02-01");
    await page.click('input[type="submit"]');

    await expect(notice(page)).toHaveText("Meal was successfully updated.");
    await expect(page.locator(".row-date td")).toHaveText("February 01, 2027");
    // The index shows the moved meal with its new weekday.
    await page.goto("/meals");
    await expect(
      page.locator("td.col-date", { hasText: "Mon, Feb 1 2027" }),
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

  // ADR 0011 rule 11. Meal 5's cook has not entered a cost, so it can be
  // cancelled. Each button asks first, and Restore brings it back.
  test("cancels a dinner and restores it", async ({ page }) => {
    await login(page);
    await page.goto("/meals/5");
    const questions = [];
    page.on("dialog", (dialog) => {
      questions.push(dialog.message());
      dialog.accept();
    });

    await page.locator(".action_items a", { hasText: /^Cancel$/ }).click();
    await expect(notice(page)).toHaveText("Dinner cancelled.");
    await expect(page.locator("tr.row-cancelled")).toHaveCount(1);

    await page.locator(".action_items a", { hasText: /^Restore$/ }).click();
    await expect(notice(page)).toHaveText("Dinner restored.");
    await expect(page.locator("tr.row-cancelled")).toHaveCount(0);
    expect(questions).toEqual(["Cancel this dinner?", "Restore this dinner?"]);
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

// Both forms refuse a date after the last meal of the calendar (#143):
// the nightly job starts the next rotation the day after the last meal,
// so a meal after it would leave schedule days with no meal. The test
// reads the end from every meal, and the tests in "Meals" add, move and
// delete meals, so it has a group and a fresh seed of its own. In the
// seed the last meal is meal 1, on 2027-02-04.
test.describe("Meals: a date after the last rotation", () => {
  reseedBeforeGroup();

  test("refuses a date after the last rotation", async ({ page }) => {
    const refusal =
      "This date is after the last rotation, which ends Feb 4, 2027. " +
      "Add the meal once the calendar reaches that date.";
    await login(page);

    // The New Meal form. The menu stays blank after the last rotation,
    // and choosing a rotation does not make the date allowed.
    await page.goto("/meals/new");
    await page.fill("#meal_date", "2027-03-01");
    // Leave the field, as a click on the menu does. That fires the
    // field's change event, and the script picks again then; without it,
    // that would happen on the submit click and clear the choice below.
    await page.locator("#meal_date").blur();
    await expect(page.locator("#meal_rotation_id")).toHaveValue("");
    await page.selectOption("#meal_rotation_id", "1");
    await page.click('input[type="submit"]');
    await expect(page).toHaveURL(/\/meals$/);
    await expect(page.locator(".errors")).toHaveText(refusal);

    // The edit form: the last meal cannot move later.
    await page.goto("/meals/1/edit");
    await page.fill("#meal_date", "2027-02-05");
    await page.click('input[type="submit"]');
    await expect(page).toHaveURL(/\/meals\/1$/);
    await expect(page.locator(".errors")).toHaveText(refusal);
    await page.goto("/meals/1");
    await expect(page.locator(".row-date td")).toHaveText("February 04, 2027");
  });
});

test.describe("Settlement", () => {
  reseedBeforeGroup();

  // The form opens a preview, and the preview has the Create button
  // (ADR 0011 rule 4).
  test("settles a period from the preview", async ({ page }) => {
    await login(page);
    await page.goto("/reconciliations/new");
    // Meal 4 (2026-01-05, closed, one $20 bill) is the only meal on or
    // before this cutoff that can settle. Meal 6 (2026-01-04) has no
    // cook, and meal 5, the next day, waits for a cost; the next two
    // tests deal with them.
    await page.fill("#reconciliation_end_date", "2026-01-05");
    await page.click('input[type="submit"]');

    await expect(page).toHaveURL(/\/reconciliations\/preview\?/);
    await expect(panel(page, "Dinners that will settle (1)")).toContainText(
      "2026-01-05",
    );
    // The amounts the settlement will store, before anything is saved.
    const amounts = panel(page, "Each person's amount");
    await expect(row(amounts, "Bob Baker").locator("td").last()).toHaveText(
      "is owed $9.00",
    );
    await expect(row(amounts, "Alice Cook").locator("td").last()).toHaveText(
      "owes $9.00",
    );
    await page.getByRole("button", { name: "Create Reconciliation" }).click();

    await expect(page).toHaveURL(/\/reconciliations\/2$/);
    await expect(notice(page)).toHaveText(
      "Reconciliation was successfully created.",
    );
    await expect(page.locator(".row-number_of_meals td")).toHaveText("1");
    // Bob cooked ($20) and he and Alice ate, two units each. The cap of
    // $4.50 a unit makes the cost $18.00, so each eater is charged
    // $9.00 and Bob is credited $18.00. The words come from
    // BalanceDisplayHelper, never a sign, and each must sit on its own
    // person's row: a swap is the worst display bug this app can have.
    const balances = panel(page, "Settlement Balances");
    await expect(balances.locator("tbody tr")).toHaveCount(2);
    await expect(
      row(balances, "Bob Baker").locator("td.col-balance"),
    ).toHaveText("is owed $9.00");
    await expect(
      row(balances, "Alice Cook").locator("td.col-balance"),
    ).toHaveText("owes $9.00");
    // Alice lives in unit A, Bob in unit B. Nobody has moved out, so the
    // Moved out line is $0.00 (ADR 0011 rule 7).
    const units = panel(page, "Unit Balances");
    await expect(units.locator("tbody tr")).toHaveCount(3);
    await expect(row(units, "Moved out").locator("td").last()).toHaveText(
      "$0.00",
    );
    await expect(row(units, "A").locator("td").last()).toHaveText("owes $9.00");
    await expect(row(units, "B").locator("td").last()).toHaveText(
      "is owed $9.00",
    );
    await expect(panel(page, "Meals")).toContainText("2026-01-05");
  });

  // A cook signed up and left the cost blank. Once the admin has asked
  // the cook, the preview's button marks it No cost, and the dinner can
  // settle (ADR 0011 rule 4).
  test("marks a blank cost No cost from the preview", async ({ page }) => {
    await login(page);
    // The clock is frozen at 2026-01-20, so 2026-01-06 is the latest
    // cutoff allowed, 14 days before today.
    await page.goto(
      "/reconciliations/preview?reconciliation%5Bend_date%5D=2026-01-06",
    );
    await expect(panel(page, "Dinners that will wait (2)")).toContainText(
      "Alice Cook has not entered a cost for 2026-01-06.",
    );
    await page
      .getByRole("link", { name: "Mark this blank cost as No cost" })
      .click();

    // The list, and a yes or no.
    await expect(page.locator("#page_title")).toHaveText(
      "Mark Blank Costs as No Cost",
    );
    await expect(page.locator("tbody tr")).toHaveCount(1);
    await expect(
      row(page.locator("#main_content"), "Alice Cook"),
    ).toContainText("After this, it is free for everyone who ate.");
    await page.getByRole("button", { name: "Yes, mark it No cost" }).click();

    // Back on the preview: the dinner no longer waits, and it settles.
    // Meal 6 still waits for a cook.
    await expect(page).toHaveURL(/\/reconciliations\/preview\?/);
    await expect(notice(page)).toHaveText("Marked 1 cost as No cost.");
    await expect(panel(page, "Dinners that will wait (1)")).not.toContainText(
      "2026-01-06",
    );
    await expect(
      panel(page, /^Dinners that will settle \(\d\)$/),
    ).toContainText("2026-01-06");
  });

  // Carol signed up for meal 6 and no cook did. If the dinner did not
  // happen, the preview's button marks it cancelled, and it settles with
  // nobody charged (ADR 0011 rule 11).
  test("marks a dinner nobody cooked as cancelled from the preview", async ({
    page,
  }) => {
    await login(page);
    await page.goto(
      "/reconciliations/preview?reconciliation%5Bend_date%5D=2026-01-06",
    );
    await expect(panel(page, "Dinners that will wait (1)")).toContainText(
      "1 person signed up to eat on 2026-01-04, but no bill was submitted.",
    );
    await page
      .getByRole("link", { name: "Mark this dinner as cancelled" })
      .click();

    // The list, and a yes or no.
    await expect(page.locator("#page_title")).toHaveText(
      "Mark Dinners as Cancelled",
    );
    await expect(page.locator("tbody tr")).toHaveCount(1);
    await expect(
      row(page.locator("#main_content"), "2026-01-04").locator("td").last(),
    ).toHaveText("1");
    await page
      .getByRole("button", { name: "Yes, mark it as cancelled" })
      .click();

    // Back on the preview: nothing waits, and the dinner settles.
    await expect(page).toHaveURL(/\/reconciliations\/preview\?/);
    await expect(notice(page)).toHaveText("Marked 1 dinner as cancelled.");
    await expect(panel(page, "Dinners that will wait (0)")).toBeVisible();
    await expect(
      panel(page, /^Dinners that will settle \(\d\)$/),
    ).toContainText("2026-01-04");
    await expect(panel(page, "Notes")).toContainText(
      "The dinner on 2026-01-04 was cancelled.",
    );
  });

  test("refuses a cutoff less than 14 days before today", async ({ page }) => {
    await login(page);
    await page.goto("/reconciliations/new");
    // The clock is frozen at 2026-01-20, so the latest cutoff is
    // 2026-01-06. A cook may still fix a cost on a newer dinner.
    await page.fill("#reconciliation_end_date", "2026-01-07");
    await page.click('input[type="submit"]');

    // The form is shown again with the reason; nothing was created.
    await expect(page).toHaveURL(/\/reconciliations\/preview\?/);
    await expect(page.locator(".errors, .inline-errors")).toContainText(
      "must be on or before 2026-01-06, 14 days before today",
    );
  });

  test("offers no Create button when nothing can settle", async ({ page }) => {
    await login(page);
    await page.goto("/reconciliations/new");
    // Meal 3 (2026-01-02) is already settled; the next meal is on the
    // 4th.
    await page.fill("#reconciliation_end_date", "2026-01-03");
    await page.click('input[type="submit"]');

    await expect(page).toHaveURL(/\/reconciliations\/preview\?/);
    await expect(panel(page, "Dinners that will settle (0)")).toContainText(
      "No dinner on or before 2026-01-03 can be settled now.",
    );
    await expect(
      page.getByRole("button", { name: "Create Reconciliation" }),
    ).toHaveCount(0);
  });

  test("shows the reconciliation page with balances and meals", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/reconciliations/1");

    await expect(page.locator(".row-number_of_meals td")).toHaveText("1");
    // Meal 3: Alice cooked ($75). Alice and Bob ate at two units each,
    // Carol (a child) at one, and Bob's guest at two: 7 units. The $4.50
    // cap makes the cost $31.50, so Alice is credited $31.50 and charged
    // $9.00, Bob is charged $9.00 and $9.00 for his guest, and Carol
    // $4.50.
    const residents = panel(page, "Settlement Balances");
    await expect(residents.locator("tbody tr")).toHaveCount(3);
    await expect(
      row(residents, "Alice Cook").locator("td.col-balance"),
    ).toHaveText("is owed $22.50");
    await expect(
      row(residents, "Bob Baker").locator("td.col-balance"),
    ).toHaveText("owes $18.00");
    await expect(
      row(residents, "Carol Baker").locator("td.col-balance"),
    ).toHaveText("owes $4.50");
    // Alice lives in unit A; Bob and Carol in unit B. Nobody has moved
    // out (ADR 0011 rule 7).
    const units = panel(page, "Unit Balances");
    await expect(units.locator("tbody tr")).toHaveCount(3);
    await expect(row(units, "A").locator("td").last()).toHaveText(
      "is owed $22.50",
    );
    await expect(row(units, "B").locator("td").last()).toHaveText(
      "owes $22.50",
    );
    const meals = panel(page, "Meals");
    await expect(meals).toContainText("2026-01-02");
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
    await expect(heading).toContainText("Jan 2, 2026");
    await expect(heading).toContainText("settled: is owed $22.50");
    // Her two lines for meal 3 (another settlement in this group can add
    // lines for other meals): credited for cooking, charged for eating.
    const lines = statement.locator("tbody tr", { hasText: "2026-01-02" });
    await expect(lines).toHaveCount(2);
    await expect(lines.filter({ hasText: "Cooked" })).toContainText(
      "credited $31.50",
    );
    await expect(lines.filter({ hasText: "Attended" })).toContainText(
      "charged $9.00",
    );
  });
});

test.describe("Settlement marks", () => {
  reseedBeforeGroup();

  // ADR 0011 rule 8: after a settlement, each line can be marked Paid or
  // Let go, with a note. The seed marks Bob's line in settlement 1 Paid;
  // this marks Carol's.
  test("marks a settlement line Paid from the settlement page", async ({
    page,
  }) => {
    await login(page);
    await page.goto("/reconciliations/1");
    const balances = panel(page, "Settlement Balances");
    await expect(
      row(balances, "Bob Baker").locator("td.col-mark"),
    ).toContainText("Paid");

    await page
      .getByLabel("Mark for Carol Baker", { exact: true })
      .selectOption("paid");
    await page.getByLabel("Note for Carol Baker").fill("Cash, at the meeting");
    await page
      .getByRole("button", { name: "Save the mark for Carol Baker" })
      .click();

    await expect(notice(page)).toHaveText("Carol Baker: Paid.");
    await expect(
      row(balances, "Carol Baker").locator("td.col-mark"),
    ).toContainText("Paid Cash, at the meeting by admin@example.com");
    await expect(panel(page, "Marks (2)")).toContainText(
      "Cash, at the meeting",
    );
  });
});

test.describe("Corrections", () => {
  reseedBeforeGroup();

  // ADR 0011 rule 6: a settled dinner is fixed by a correction, which
  // the next settlement carries. The preview shows each person's change
  // and saves nothing; Save saves what the preview showed.
  test("corrects a settled dinner from its page", async ({ page }) => {
    await login(page);
    // Meal 3 (2026-01-02) is settled. Alice spent $75, and Alice, Bob,
    // Bob's guest and Carol, a child, ate: 7 units at the $4.50 cap,
    // $31.50.
    await page.goto("/meals/3");
    await page.getByRole("link", { name: "Correct this dinner" }).click();
    await expect(page.locator("#page_title")).toHaveText(
      "Correct the 2026-01-02 Dinner",
    );

    await page.getByLabel("New cost for Alice Cook").fill("21");
    await page.getByLabel("Reason").fill("The receipt says $21");
    await page.getByRole("button", { name: "Preview correction" }).click();

    // $21 is under the cap: $3.00 a unit. Alice is credited $21 and
    // charged $6, where she was credited $31.50 and charged $9. Bob was
    // charged $18 for himself and his guest and now $12; Carol $4.50 and
    // now $3.
    const shown = panel(page, "What this correction does");
    await expect(shown.locator("li")).toHaveText([
      "Changed Alice Cook's cost from $75.00 to $21.00.",
    ]);
    await expect(row(shown, "Alice Cook").locator("td").last()).toHaveText(
      "charged $7.50",
    );
    await expect(row(shown, "Bob Baker").locator("td").last()).toHaveText(
      "credited $6.00",
    );
    await expect(row(shown, "Carol Baker").locator("td").last()).toHaveText(
      "credited $1.50",
    );
    await page.getByRole("button", { name: "Save correction" }).click();

    await expect(page).toHaveURL(/\/meals\/3$/);
    await expect(notice(page)).toHaveText(
      "The correction is saved. The next settlement carries it.",
    );
    await expect(page.locator(".row-total_cost td")).toHaveText("$21.00");
    const corrections = panel(page, "Corrections (1)");
    await expect(corrections).toContainText("Waits for the next settlement");
    await expect(corrections).toContainText("Reason: The receipt says $21");
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

  test("refuses to call a child an adult while the birthday says child", async ({
    page,
  }) => {
    await login(page);
    // Carol is a child in the seed, with a birthday.
    await page.goto("/residents/3");
    await expect(page.locator(".row-category td")).toHaveText("Child");
    await page.goto("/residents/3/edit");
    await page
      .locator("#resident_kind_input label", { hasText: "Adult" })
      .click();
    await page.click('input[type="submit"]');

    await expect(page.locator("body")).toContainText(
      "makes this person a child. Choose Child, or check the date.",
    );
    await page.goto("/residents/3");
    await expect(page.locator(".row-category td")).toHaveText("Child");
  });

  test("removes an adult's birthday from the calendar", async ({ page }) => {
    await login(page);
    // Alice is an adult with no birthday in the seed. Give her one, then
    // take it off again from her page.
    await page.goto("/residents/1/edit");
    await page.fill("#resident_birthday", "1985-03-15");
    await page.click('input[type="submit"]');
    await expect(page.locator(".row-birthday td")).toContainText("1985");
    await expect(page.locator(".row-category td")).toHaveText("Adult");

    page.once("dialog", (dialog) => dialog.accept());
    await page.click("text=Remove birthday");

    // ActiveAdmin shows a blank attribute as the word Empty.
    await expect(page.locator(".row-birthday td")).toHaveText("Empty");
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
    // Both seeded rotations are still listed.
    await expect(page.locator("tbody tr")).toHaveCount(2);
    await expect(page.locator("tr#rotation_1")).toHaveCount(1);
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

    // The seed has timed events and bookings, and a new zone moves them
    // on the clock, so the first submit only shows what would move
    // (#173). The second one saves.
    await expect(page.locator(".zone-change-warning")).toContainText(
      "would show at different clock times",
    );
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
    await expect(page.locator("tbody tr")).toHaveCount(4);

    await page.goto(`/residents/1?token=${READ_ONLY_TOKEN}`);
    await expect(panel(page, "Settlement statement")).toBeVisible();

    // The common house email links to the settlement's page. The token
    // sees Bob's mark and when it was made, not which admin made it.
    await page.goto(`/reconciliations/1?token=${READ_ONLY_TOKEN}`);
    await expect(panel(page, "Settlement Balances")).toContainText("Paid");
    await expect(page.locator("#main_content")).not.toContainText(
      "admin@example.com",
    );

    // Admin accounts are not on the allowlist. The refusal sends the
    // visitor to the dashboard without the token, and the dashboard sends
    // a signed-out visitor to the login page.
    await page.goto(`/admin_users?token=${READ_ONLY_TOKEN}`);
    await expect(page).toHaveURL(/\/login$/);
    // Devise's words, without its "or sign up": the admin has no sign-up.
    await expect(alert(page)).toHaveText(
      "You need to sign in before continuing.",
    );

    // Nor is any write.
    await page.goto(`/residents/1/edit?token=${READ_ONLY_TOKEN}`);
    await expect(page).toHaveURL(/\/login$/);
  });

  test("a wrong token is just a signed-out visitor", async ({ page }) => {
    await page.goto("/bills?token=wrong");
    await expect(page).toHaveURL(/\/login$/);
    await expect(alert(page)).toHaveText(
      "You need to sign in before continuing.",
    );
  });
});
