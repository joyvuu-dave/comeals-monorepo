const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
const {
  FROZEN_NOW,
  NOT_FOUND_MESSAGE,
  NOT_FOUND_LOG,
  rails500,
  setupAuthenticatedPage,
  stubPusher,
  disableIdleTimer,
  mockApi,
} = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");
const calendarFixture = require("../fixtures/calendar.json");
const rotationFixture = require("../fixtures/rotation.json");

/**
 * Visual regression tests.
 *
 * These capture screenshots and compare against golden reference images.
 * On first run, golden images are created in tests/e2e/visual.spec.js-snapshots/.
 * On subsequent runs, new screenshots are diffed against the golden.
 *
 * After a dependency upgrade, if a visual test fails:
 *   - If the change is EXPECTED (library updated its styling): refresh
 *     the goldens with `bin/update-snapshots` (every golden) or
 *     `bin/update-snapshots <name> ...` (only those), then look at each
 *     changed PNG before committing it.
 *   - If the change is UNEXPECTED: you caught a regression!
 *
 * Baselines exist per platform: -darwin for local runs, -linux for CI.
 * bin/update-snapshots deletes the goldens first and records both sets:
 * darwin here, linux in Docker (bin/update-linux-snapshots). A plain
 * `--update-snapshots` rewrites only a golden whose comparison fails, so
 * a golden that is stale but still inside the 0.1% budget keeps showing
 * the old screen (#62). `npm run test:e2e:update` passes
 * `--update-snapshots=all` for that reason. Never refresh the linux set
 * by letting CI fail and downloading its artifact.
 *
 * Time is frozen to noon on 2026-01-15 in Los Angeles (FROZEN_NOW in
 * tests/helpers/setup.js) for deterministic screenshots.
 */
test.describe("Visual Baselines", () => {
  test("login page", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);

    // Freeze time for determinism
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // Wait for the login form to render
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 10000,
    });

    await expect(page).toHaveScreenshot("login-page.png", {
      fullPage: true,
    });
  });

  test("calendar month view", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);

    // Freeze time for determinism
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Wait a moment for all events to render
    await page.waitForTimeout(1000);

    await expect(page).toHaveScreenshot("calendar-month.png", {
      fullPage: true,
    });
  });

  // Months that can only render correctly if the date math is right:
  // the two daylight-saving switches and a leap February. These need
  // the community's timezone because a UTC viewer has no DST — without
  // it these goldens could not show a DST bug (the November escape).
  // The whole suite is pinned to that timezone in playwright.config.js.
  //
  // Each month gets its own calendar answer with chips on the hard day:
  // a meal, its cook, an evening event, a birthday, and a rotation that
  // starts that day and runs two more. The January fixture has no chip
  // in these months, so without them the goldens showed empty grids and
  // could not catch a chip drawn on the wrong day.
  test.describe("calendar edge months", () => {
    // The calendar answer for the month of the edge's day, shaped like
    // the fixture's, with every chip on that day and a rotation to
    // rotationEnd.
    function edgeMonthCalendar(edge) {
      const { day, dinner, evening } = edge;
      const [year, month] = day.split("-").map(Number);
      const [meal] = calendarFixture.meals;
      const [bill] = calendarFixture.bills;
      const [rotation] = calendarFixture.rotations;
      const [birthday] = calendarFixture.birthdays;
      const [event] = calendarFixture.events;
      return {
        ...calendarFixture,
        month,
        year,
        meals: [
          {
            ...meal,
            id: "meals/501",
            title: "Dinner\n4 signed up",
            start: dinner,
            end: dinner,
            url: "/meals/501/edit",
          },
        ],
        bills: [
          {
            ...bill,
            id: "bills/601",
            title: "Cook\nBob - Unit B",
            start: dinner,
            end: dinner,
            url: "/meals/501/edit",
            description: "Cook:  Bob - Unit B",
          },
        ],
        rotations: [
          {
            ...rotation,
            id: "rotations/701",
            title: "Rotation 9",
            start: dinner,
            end: edge.rotationEnd,
            url: "rotations/show/701",
          },
        ],
        birthdays: [
          {
            ...birthday,
            id: "residents/2",
            title: "Bob's B-day!",
            description: "Bob's Birthday!",
            start: day,
            end: day,
          },
        ],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [
          {
            ...event,
            id: "events/801",
            title: " 7:00pm -  9:00pm\nEvent\nPotluck",
            description: "Event\nPotluck",
            start: evening[0],
            end: evening[1],
            url: "events/edit/801",
          },
        ],
      };
    }

    // The header cell of `day` in the grid. An off-range day (from the
    // next month) has its own class.
    function dayCell(page, day, { offRange = false } = {}) {
      const cells = offRange
        ? ".rbc-date-cell.rbc-off-range"
        : ".rbc-date-cell:not(.rbc-off-range)";
      return page.locator(cells, {
        hasText: new RegExp(`^${day.slice(8)}$`),
      });
    }

    // The chip with `text` starts in the column of `first` and ends in
    // the column of `last`, in their week's row. Half a pixel of slack
    // for the chip's own margin; a chip a day off is 150 pixels off.
    async function expectChipOn(page, text, first, last = first) {
      const chip = page.locator(".rbc-event", { hasText: text });
      await expect(chip).toHaveCount(1);
      const chipBox = await chip.boundingBox();
      const firstBox = await first.boundingBox();
      const lastBox = await last.boundingBox();
      const week = await first
        .locator("xpath=ancestor::div[contains(@class, 'rbc-month-row')]")
        .boundingBox();
      expect(chipBox.x).toBeGreaterThanOrEqual(firstBox.x - 0.5);
      expect(chipBox.x).toBeLessThan(firstBox.x + firstBox.width);
      expect(chipBox.x + chipBox.width).toBeGreaterThan(lastBox.x);
      expect(chipBox.x + chipBox.width).toBeLessThanOrEqual(
        lastBox.x + lastBox.width + 0.5,
      );
      expect(chipBox.y).toBeGreaterThan(week.y);
      expect(chipBox.y + chipBox.height).toBeLessThan(week.y + week.height);
    }

    // Times are written out with the offset in force at that hour, the
    // way the server writes them, not computed here: dayjs.tz in Node
    // gets the hour after midnight on a switch day wrong on a machine
    // east of Los Angeles.
    for (const edge of [
      // Clocks go back at 2am: a 25-hour day, the first Sunday of
      // November, which is also the first cell of the grid.
      {
        name: "calendar-november-dst",
        day: "2026-11-01",
        dinner: "2026-11-01T00:01:00.000-07:00",
        evening: [
          "2026-11-01T19:00:00.000-08:00",
          "2026-11-01T21:00:00.000-08:00",
        ],
        rotationEndDay: "2026-11-03",
        rotationEnd: "2026-11-03T23:59:00.000-08:00",
      },
      // Clocks go forward at 2am: a 23-hour day.
      {
        name: "calendar-march-dst",
        day: "2026-03-08",
        dinner: "2026-03-08T00:01:00.000-08:00",
        evening: [
          "2026-03-08T19:00:00.000-07:00",
          "2026-03-08T21:00:00.000-07:00",
        ],
        rotationEndDay: "2026-03-10",
        rotationEnd: "2026-03-10T23:59:00.000-07:00",
      },
      // February 29, with the rotation running into March, which shows
      // as the grid's last week.
      {
        name: "calendar-february-leap",
        day: "2028-02-29",
        dinner: "2028-02-29T00:01:00.000-08:00",
        evening: [
          "2028-02-29T19:00:00.000-08:00",
          "2028-02-29T21:00:00.000-08:00",
        ],
        rotationEndDay: "2028-03-02",
        rotationEnd: "2028-03-02T23:59:00.000-08:00",
        rotationEndsNextMonth: true,
      },
    ]) {
      test(edge.name, async ({ page, context }) => {
        await setupAuthenticatedPage(page, context, {
          calendarData: edgeMonthCalendar(edge),
        });
        await page.clock.setFixedTime(FROZEN_NOW);

        await page.goto(`/calendar/all/${edge.day}/`);
        await page.waitForLoadState("networkidle");
        await expect(page.locator(".rbc-calendar")).toBeVisible({
          timeout: 10000,
        });
        await expect(
          page.locator(".rbc-event", { hasText: "Potluck" }),
        ).toBeVisible({ timeout: 10000 });

        // Guard the story before diffing pixels: every chip is on the
        // hard day, and the rotation covers it and the two days after.
        const hardDay = dayCell(page, edge.day);
        for (const text of [
          "4 signed up",
          "Bob - Unit B",
          "Potluck",
          "Bob's B-day!",
        ]) {
          await expectChipOn(page, text, hardDay);
        }
        await expectChipOn(
          page,
          "Rotation 9",
          hardDay,
          dayCell(page, edge.rotationEndDay, {
            offRange: Boolean(edge.rotationEndsNextMonth),
          }),
        );
        await page.waitForTimeout(1000);

        await expect(page).toHaveScreenshot(`${edge.name}.png`, {
          fullPage: true,
        });
      });
    }
  });

  test("meal edit page", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);

    // Freeze time for determinism
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    // Wait for residents to render in attendee table
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-edit.png", {
      fullPage: true,
    });
  });

  test("event creation form", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);

    // Freeze time for determinism
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Open event creation modal
    const eventButton = page.locator("text=Event").first();
    await expect(eventButton).toBeVisible({ timeout: 5000 });
    await eventButton.click();

    await expect(page.locator(".ReactModal__Content--after-open")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("event-form.png", {
      fullPage: true,
    });
  });

  test("day picker overlay", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);

    // Freeze time for determinism
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });

    // Open event creation modal
    const eventButton = page.locator("text=Event").first();
    await expect(eventButton).toBeVisible({ timeout: 5000 });
    await eventButton.click();

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 5000 });

    // Open the react-day-picker overlay. The library's own stylesheet
    // drives how the picker looks, so a library upgrade can change the
    // rendering without failing any functional test — this snapshot
    // catches that. The modal's defaultMonth comes from the URL date and
    // time is frozen to the same date, so the picker always shows
    // January 2026 with the today ring on the 15th.
    await modal.locator("input[readonly]").click();
    const overlay = modal.locator(".rdp-root");
    await expect(overlay).toBeVisible({ timeout: 3000 });

    // Guard the pin before diffing pixels: a wrong month means the test
    // is broken, not the styling.
    await expect(overlay.getByText("January 2026")).toBeVisible();
    await page.waitForTimeout(500);

    await expect(overlay).toHaveScreenshot("day-picker.png");
  });

  test("event edit form", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    // The modal opens straight from the URL; mockApi serves event 70.
    await page.goto("/calendar/all/2026-01-15/events/edit/70/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("#event-edit-title")).toHaveValue(
      "Community Meeting",
      { timeout: 5000 },
    );
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("event-edit.png", { fullPage: true });
  });

  test("delete confirmation modal", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/events/edit/70/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("#event-edit-title")).toHaveValue(
      "Community Meeting",
      { timeout: 5000 },
    );

    await modal.locator("button:has-text('Delete')").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(
      confirmOverlay.locator("text=Do you really want to delete this event?"),
    ).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("confirm-delete.png", {
      fullPage: true,
    });
  });

  test("common house reservation form", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/common-house-reservations/new/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("#ch-new-resident")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("common-house-form.png", {
      fullPage: true,
    });
  });

  test("common house reservation edit form", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    // mockApi serves reservation 50 ("Book Club").
    await page.goto(
      "/calendar/all/2026-01-15/common-house-reservations/edit/50/",
    );
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("#ch-edit-title")).toHaveValue("Book Club", {
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("common-house-edit.png", {
      fullPage: true,
    });
  });

  test("guest room reservation form", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/guest-room-reservations/new/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("#guest-room-new-host")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("guest-room-form.png", {
      fullPage: true,
    });
  });

  test("guest room reservation edit form", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    // mockApi serves reservation 60 with resident_id 1 (Jane).
    await page.goto(
      "/calendar/all/2026-01-15/guest-room-reservations/edit/60/",
    );
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator("#guest-room-edit-host")).toHaveValue("1", {
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("guest-room-edit.png", {
      fullPage: true,
    });
  });

  test("rotation modal", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/rotations/show/10/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    // The fixture rotation's description is its meals' date range.
    await expect(modal.locator("text=Jan 13–17, 2026")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("rotation-modal.png", {
      fullPage: true,
    });
  });

  // The fixture's residents have both signed up to cook. A resident who
  // has not is drawn bold and italic, not struck through.
  test("rotation modal with a resident not signed up yet", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await page.route("**/api/v1/rotations/*", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          ...rotationFixture,
          residents: rotationFixture.residents.map((resident) =>
            resident.id === 2 ? { ...resident, signed_up: false } : resident,
          ),
        }),
      }),
    );

    await page.goto("/calendar/all/2026-01-15/rotations/show/10/");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("text=Jan 13–17, 2026")).toBeVisible({
      timeout: 10000,
    });
    await expect(
      modal.locator("li", { hasText: "B - Bob Johnson" }),
    ).toHaveClass("text-bold text-italic");
    await expect(
      modal.locator("li", { hasText: "A - Jane Smith" }),
    ).toHaveClass("text-muted");
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("rotation-modal-not-signed-up.png", {
      fullPage: true,
    });
  });

  // The modal before its rotation arrives: the request is held open.
  test("rotation modal loading", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/rotations/*", "GET");

    const request = page.waitForRequest("**/api/v1/rotations/10");
    await page.goto("/calendar/all/2026-01-15/rotations/show/10/");
    await request;
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(
      modal.getByRole("heading", { name: "Loading..." }),
    ).toBeVisible({ timeout: 10000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("rotation-modal-loading.png", {
      fullPage: true,
    });
  });

  test("meal history modal", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const historyLink = page.locator("text=history").first();
    await expect(historyLink).toBeVisible({ timeout: 10000 });
    await historyLink.click();

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 5000 });
    await expect(
      modal.getByRole("cell", { name: "Jane added", exact: true }),
    ).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-history.png", {
      fullPage: true,
    });
  });

  // The history modal before its list arrives: the request is held open.
  test("meal history modal loading", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/meals/*/history*", "GET");

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });

    const request = page.waitForRequest("**/api/v1/meals/42/history");
    await page.locator("text=history").first().click();
    await request;
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(
      modal.getByRole("heading", { name: "Loading..." }),
    ).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-history-loading.png", {
      fullPage: true,
    });
  });

  test("password reset page", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/reset-password/test-reset-token/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    await expect(modal.locator('input[type="password"]')).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("password-reset.png", {
      fullPage: true,
    });
  });

  test("closed meal page with extras", async ({ page, context }) => {
    // This golden documents the closed-meal row colors. The rule
    // (attendees_box.jsx + resident.canRemove): an attendee who signed
    // up BEFORE the meal closed is locked in — green with a grayscale
    // filter. One added AFTER the close (an extra) can still remove
    // themselves — bright green. closed_at sits after the fixture's
    // signups (18:30 and 19:00 LA on Jan 14), so Jane and Alice render
    // gray; Bob is added as an extra after the close and renders green.
    await setupAuthenticatedPage(page, context, {
      mealData: {
        ...mealFixture,
        closed: true,
        closed_at: "2026-01-15T08:00:00Z",
        residents: mealFixture.residents.map((resident) =>
          resident.id === 2
            ? {
                ...resident,
                attending: true,
                attending_at: "2026-01-15T01:00:00.000-08:00",
              }
            : resident,
        ),
      },
    });
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator("text=Extras")).toBeVisible({ timeout: 5000 });

    // Guard the story before diffing pixels (the day-picker pattern):
    // a screenshot alone stays green when the state it depicts changes
    // meaning — that is how the all-green version of this golden
    // slipped through in 286544a. Jane must be locked in (green cell
    // with the grayscale filter), Bob must be a removable extra (green
    // cell, no filter). If these fail, the test data is broken, not
    // the styling.
    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(janeCell).toHaveClass(/background-green/);
    await expect(janeCell).toHaveAttribute("style", /grayscale/);
    await expect(bobCell).toHaveClass(/background-green/);
    await expect(bobCell).not.toHaveAttribute("style", /grayscale/);
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-closed.png", {
      fullPage: true,
    });
  });

  test("close confirm bar with blank cook cost", async ({ page, context }) => {
    // A second cook with a blank cost makes the close button ask first.
    await setupAuthenticatedPage(page, context, {
      mealData: {
        ...mealFixture,
        bills: [
          ...mealFixture.bills,
          {
            id: 202,
            meal_id: 42,
            resident_id: 2,
            amount: "",
            no_cost: false,
          },
        ],
      },
    });
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    await page.locator("text=Open / Close Meal").click();
    await expect(
      page.locator("text=hasn’t entered a cost yet").first(),
    ).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("close-confirm-bar.png", {
      fullPage: true,
    });
  });

  test("guest dropdown open", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    const janeCell = page.getByRole("cell", {
      name: "A - Jane Smith",
      exact: true,
    });
    await expect(janeCell).toBeVisible({ timeout: 10000 });

    const janeRow = janeCell.locator("xpath=ancestor::tr");
    await janeRow.locator(".dropdown-add").click();
    await expect(janeRow.locator(".dropdown-menu")).toBeVisible({
      timeout: 3000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("guest-dropdown.png", {
      fullPage: true,
    });
  });

  test("error toast", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // Reset with an empty email raises the error toast. An error stays
    // until a person closes it, so the screenshot cannot race a timer.
    await page.getByRole("button", { name: "Reset your password" }).click();
    const toast = page.locator(".toast--error");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(toast).toHaveScreenshot("toast-error.png");
  });

  // Messages stack up, newest on top, up to three at once (#137). On a
  // phone, where most residents open the app. Each write the meal page
  // makes here fails with its own words, the words the server or the
  // app really uses: the same words twice make one message, not two.
  test.describe("message stack", () => {
    test.use({
      viewport: { width: 375, height: 667 },
      allowedConsoleErrors: combinePatterns(
        httpFailurePattern,
        /^Bad response from server/,
        /^Error: no response received from server\.$/,
      ),
    });

    // MealsController#conflict_rejection.
    const MEAL_CONFLICT =
      "Someone else was changing this meal at the same time. Nothing was saved. Try again.";
    // MealsController#reconciled_rejection.
    const SETTLED = "Change not permitted. Meal has already been reconciled.";
    // MealsController#verify_resident_exists.
    const NOT_FOUND = "Resident not found.";
    // ThirdCookWarning.
    const THIRD_COOK =
      "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.";
    // A refused sign-up or guest request names the person whose row was
    // tapped first (S2). One with no answer says it may not have been
    // saved.
    const BOB_CONFLICT = `Bob Johnson: ${MEAL_CONFLICT}`;
    const JANE_SETTLED = `Jane Smith: ${SETTLED}`;
    const ALICE_NOT_FOUND = `Alice Williams: ${NOT_FOUND}`;
    const JANE_GUEST_MAYBE =
      "Jane Smith: this change may not have been saved. The meal will load again and show what was saved.";

    function refuse(status, message) {
      return (route) =>
        route.fulfill({
          status,
          contentType: "application/json",
          body: JSON.stringify({ message }),
        });
    }

    async function openMeal(page, context, options = {}) {
      await setupAuthenticatedPage(page, context, options);
      await page.clock.setFixedTime(FROZEN_NOW);
      // Registered after mockApi, so these win.
      await page.route(
        "**/api/v1/meals/*/residents/2",
        refuse(409, MEAL_CONFLICT),
      );
      await page.route("**/api/v1/meals/*/residents/1", refuse(400, SETTLED));
      await page.route("**/api/v1/meals/*/residents/3", refuse(400, NOT_FOUND));
      await page.route("**/api/v1/meals/*/description*", rails500);
      await page.route("**/api/v1/meals/*/residents/1/guests", (route) =>
        route.abort("connectionfailed"),
      );
      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");
      await expect(
        page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
      ).toBeVisible({ timeout: 10000 });
    }

    const messages = (page) => page.locator(".toast__message");

    // The taps scroll the page by an amount that depends on the fonts,
    // and the page shows between the messages. The top of the meal page
    // is what a person sees first.
    async function scrollToTop(page) {
      await page.evaluate(() => window.scrollTo(0, 0));
    }

    // Each step makes one write fail, and waits until its message shows
    // on top.
    async function tapResident(page, name, words) {
      await page.getByRole("cell", { name, exact: true }).click();
      await expect(messages(page).first()).toHaveText(words);
    }

    async function signUpBob(page) {
      await tapResident(page, "B - Bob Johnson", BOB_CONFLICT);
    }

    async function signOffJane(page) {
      await tapResident(page, "A - Jane Smith", JANE_SETTLED);
    }

    async function signOffAlice(page) {
      await tapResident(page, "C - Alice Williams", ALICE_NOT_FOUND);
    }

    async function changeMenu(page) {
      await page
        .getByLabel("Enter meal description")
        .fill("Pasta night with garlic bread and salad");
      await expect(messages(page).first()).toHaveText(
        "The server had a problem. Please try again.",
        { timeout: 10000 },
      );
    }

    async function addGuestForJane(page) {
      const janeRow = page
        .getByRole("cell", { name: "A - Jane Smith", exact: true })
        .locator("xpath=ancestor::tr");
      await janeRow.locator(".dropdown-add").click();
      await janeRow.locator(".dropdown-menu img[alt='cow-icon']").click();
      await expect(messages(page).first()).toHaveText(JANE_GUEST_MAYBE);
    }

    // An error under a message that is not one. The info message closes
    // itself after 5 seconds, so the screenshot follows at once.
    test("two messages", async ({ page, context }) => {
      await openMeal(page, context, { billsWarning: THIRD_COOK });
      await signUpBob(page);
      await page.getByLabel("Select meal cook").nth(1).selectOption("2");
      await expect(messages(page).first()).toHaveText(
        `Cooks saved. ${THIRD_COOK}`,
      );

      await expect(messages(page)).toHaveText([
        `Cooks saved. ${THIRD_COOK}`,
        BOB_CONFLICT,
      ]);
      await scrollToTop(page);
      await expect(page.locator(".toast-container")).toHaveScreenshot(
        "message-stack-two.png",
      );
    });

    test("three messages", async ({ page, context }) => {
      await openMeal(page, context);
      await signUpBob(page);
      await signOffJane(page);
      await changeMenu(page);
      await scrollToTop(page);
      await page.waitForTimeout(500);

      await expect(messages(page)).toHaveText([
        "The server had a problem. Please try again.",
        JANE_SETTLED,
        BOB_CONFLICT,
      ]);
      await expect(page.getByRole("button", { name: /more/ })).toHaveCount(0);
      await expect(page.locator(".toast-container")).toHaveScreenshot(
        "message-stack-three.png",
      );
    });

    // Five errors: the newest three show, and a line under them says
    // there are two more. The whole screen, to show how much of the
    // meal page the stack covers on a phone.
    test("more messages than show", async ({ page, context }) => {
      await openMeal(page, context);
      await signUpBob(page);
      await signOffJane(page);
      await signOffAlice(page);
      await changeMenu(page);
      await addGuestForJane(page);
      await scrollToTop(page);
      await page.waitForTimeout(500);

      await expect(messages(page)).toHaveText([
        JANE_GUEST_MAYBE,
        "The server had a problem. Please try again.",
        ALICE_NOT_FOUND,
      ]);
      await expect(
        page.getByRole("button", { name: "Show 2 more messages" }),
      ).toBeVisible();
      await expect(page).toHaveScreenshot("message-stack-more.png");

      // Tapped, the line shows every message.
      await page.getByRole("button", { name: "Show 2 more messages" }).click();
      await expect(messages(page)).toHaveText([
        JANE_GUEST_MAYBE,
        "The server had a problem. Please try again.",
        ALICE_NOT_FOUND,
        JANE_SETTLED,
        BOB_CONFLICT,
      ]);
      await page.waitForTimeout(500);
      await expect(page).toHaveScreenshot("message-stack-all.png");
    });

    // The stack sits at the bottom of the screen, so the top keeps the
    // navigation a person needs. On a phone that is "← Calendar", the
    // meal's date and its arrows (#137). The whole screen, to show both.
    test("the stack at the bottom of a phone's screen", async ({
      page,
      context,
    }) => {
      await openMeal(page, context);
      await signUpBob(page);
      await scrollToTop(page);
      await page.waitForTimeout(500);

      await expect(messages(page)).toHaveText([BOB_CONFLICT]);
      await expect(page).toHaveScreenshot("message-stack-phone.png");
    });

    // The person leaves a meal while its costs are being saved, and both
    // tries of the save get no answer. The second try may have been
    // written, so the message says the costs may not have been saved,
    // and names the meal, because the person is no longer on it (#137).
    test("may not have been saved, for a meal the person left", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      let answerTheSave;
      const onTheCalendar = new Promise((resolve) => {
        answerTheSave = resolve;
      });
      await page.route("**/api/v1/meals/42/bills*", async (route) => {
        await onTheCalendar;
        await route.abort("connectionfailed");
      });
      await page.goto("/meals/42/edit/");
      const cost = page
        .getByRole("spinbutton", { name: "Set meal cost" })
        .first();
      await expect(cost).toHaveValue("25.50", { timeout: 10000 });
      const sent = page.waitForRequest(
        (r) =>
          r.method() === "PATCH" && r.url().includes("/api/v1/meals/42/bills"),
      );
      await cost.fill("30.00");
      await sent;

      await page.getByRole("button", { name: "Calendar" }).click();
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });
      answerTheSave();
      await expect(messages(page)).toHaveText([
        "The cooks and costs you entered for Thu, Jan 15th may not have been saved. Please open that meal and check them.",
      ]);
      await page.waitForTimeout(500);

      await expect(page.locator(".toast-container")).toHaveScreenshot(
        "message-maybe-not-saved.png",
      );
    });
  });

  // A calendar form's own error shows inside the form, under its title,
  // and not in the stack of messages, which is drawn under the open form
  // (#137).
  test.describe("a form's own error", () => {
    // The refused create makes the browser log a request failure.
    test.use({ allowedConsoleErrors: httpFailurePattern });

    test("event form with its own error", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      // What EventsController#create sends for an event with no title.
      await page.route("**/api/v1/events", (route) =>
        route.fulfill({
          status: 400,
          contentType: "application/json",
          body: JSON.stringify({ message: "Title can't be blank" }),
        }),
      );

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });
      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });
      await modal.getByRole("button", { name: "Create" }).click();
      await expect(modal.locator(".form-message__text")).toHaveText(
        "Title can't be blank",
      );
      await expect(page.locator(".toast")).toHaveCount(0);
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("event-form-error.png", {
        fullPage: true,
      });
    });
  });

  test.describe("with a 401 backend", () => {
    // The mocked 401 makes the browser log a request failure, and
    // handle_axios_error logs the server's message.
    test.use({
      allowedConsoleErrors: combinePatterns(
        httpFailurePattern,
        /^You are not authenticated\.$/,
      ),
    });

    test("session expired banner", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);

      // A 401 from the calendar fetch raises the signed-out banner.
      await page.route("**/api/v1/communities/*/calendar/*", (route) => {
        route.fulfill({
          status: 401,
          contentType: "application/json",
          body: JSON.stringify({ message: "You are not authenticated." }),
        });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await expect(
        page.locator("text=Heads up — you've been signed out"),
      ).toBeVisible({ timeout: 10000 });
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("session-expired.png", {
        fullPage: true,
      });
    });
  });

  test("version banner", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);

    // The banner compares the running entry file (read from the DOM)
    // against the served manifest every five minutes. Serve a manifest
    // naming a different entry file, install a fake clock, and jump
    // past one poll interval to make the banner appear.
    await page.route("**/.vite/manifest.json", (route) => {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          "index.html": {
            isEntry: true,
            file: "vite-assets/index-NEWBUILD.js",
          },
        }),
      });
    });

    await page.clock.install({ time: FROZEN_NOW });
    await page.goto("/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 10000,
    });

    await page.clock.fastForward(5 * 60 * 1000 + 1000);
    const banner = page.locator("text=A new version is available.");
    await expect(banner).toBeVisible({ timeout: 10000 });

    await expect(page).toHaveScreenshot("version-banner.png", {
      fullPage: true,
    });
  });

  // The looks below are the states a screen can take beyond its first
  // paint. bin/visual-coverage lists the markup branches no golden
  // shows; each test here closes one or more of those.

  // A request that never answers, so a form stays in its saving look.
  async function holdRoute(page, url, method) {
    await page.route(url, async (route) => {
      if (method && route.request().method() !== method) {
        return route.fallback();
      }
      await new Promise((resolve) => setTimeout(resolve, 60000));
      return route.fulfill({ status: 200, body: "{}" });
    });
  }

  // Offline: the browser's own event flips the header's ONLINE word.
  test("calendar offline", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator(".rbc-calendar")).toBeVisible({ timeout: 10000 });
    await page.waitForTimeout(1000);

    await context.setOffline(true);
    await expect(page.locator(".offline")).toHaveText("OFFLINE");
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("calendar-offline.png", {
      fullPage: true,
    });
  });

  test("meal page offline", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });

    await context.setOffline(true);
    await expect(page.locator(".offline")).toHaveText("OFFLINE");
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-offline.png", { fullPage: true });
  });

  test("login page offline", async ({ page, context }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator('input[aria-label="email"]')).toBeVisible({
      timeout: 10000,
    });

    await context.setOffline(true);
    await expect(page.locator(".offline")).toHaveText("OFFLINE");
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("login-offline.png", {
      fullPage: true,
    });
  });

  // The picker over an edit form: the reservation's day is marked.
  test("day picker with a chosen day", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/calendar/all/2026-01-15/events/edit/70/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#event-edit-title")).toHaveValue(
      "Community Meeting",
      { timeout: 10000 },
    );

    await modal.locator("#event-edit-day").click();
    const overlay = modal.locator(".rdp-root");
    await expect(overlay).toBeVisible({ timeout: 3000 });
    await expect(overlay.locator(".rdp-selected")).toHaveCount(1);
    await page.waitForTimeout(500);

    await expect(overlay).toHaveScreenshot("day-picker-selected.png");
  });

  // The saving look of each form: the button spins and the picker dims
  // until the server answers.
  test("event form submitting", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/events", "POST");

    await page.goto("/calendar/all/2026-01-15/events/new/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await modal.locator("#event-new-title").fill("Movie Night");
    await modal.getByRole("button", { name: "Create" }).click();
    await expect(modal.locator(".button-loader")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("event-form-submitting.png", {
      fullPage: true,
    });
  });

  test("common house form submitting", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/common-house-reservations", "POST");

    await page.goto("/calendar/all/2026-01-15/common-house-reservations/new/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#ch-new-resident")).toBeVisible({
      timeout: 10000,
    });
    await modal.getByRole("button", { name: "Create" }).click();
    await expect(modal.locator(".button-loader")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("common-house-form-submitting.png", {
      fullPage: true,
    });
  });

  test("guest room form submitting", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/guest-room-reservations", "POST");

    await page.goto("/calendar/all/2026-01-15/guest-room-reservations/new/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#guest-room-new-host")).toBeVisible({
      timeout: 10000,
    });
    await modal.getByRole("button", { name: "Create" }).click();
    await expect(modal.locator(".button-loader")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("guest-room-form-submitting.png", {
      fullPage: true,
    });
  });

  test("event edit updating", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/events/**", "PATCH");

    await page.goto("/calendar/all/2026-01-15/events/edit/70/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#event-edit-title")).toHaveValue(
      "Community Meeting",
      { timeout: 10000 },
    );
    await modal.getByRole("button", { name: "Update" }).click();
    await expect(modal.locator(".button-loader")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("event-edit-updating.png", {
      fullPage: true,
    });
  });

  test("event edit deleting", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/events/**", "DELETE");

    await page.goto("/calendar/all/2026-01-15/events/edit/70/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#event-edit-title")).toHaveValue(
      "Community Meeting",
      { timeout: 10000 },
    );
    await modal.getByRole("button", { name: "Delete" }).click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(
      confirmOverlay.locator("text=Do you really want to delete this event?"),
    ).toBeVisible({ timeout: 5000 });
    // The confirm button is armed after 400ms.
    await page.waitForTimeout(600);
    await confirmOverlay.getByRole("button", { name: "Delete" }).click();
    await expect(modal.locator(".button-loader")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("event-edit-deleting.png", {
      fullPage: true,
    });
  });

  // A settled meal: every control frozen, a name that is not attending
  // dimmed plain, and a vegetarian guest's carrot badge.
  test("reconciled meal page", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context, {
      mealData: {
        ...mealFixture,
        closed: true,
        closed_at: "2026-01-15T08:00:00Z",
        reconciled: true,
        guests: mealFixture.guests.map((guest) => ({
          ...guest,
          vegetarian: true,
        })),
      },
    });
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "RECONCILED" })).toBeVisible({
      timeout: 10000,
    });
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCell).toHaveAttribute("style", /not-allowed/);
    await expect(page.locator('img[alt="carrot-icon"]').first()).toBeVisible();
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-reconciled.png", {
      fullPage: true,
    });
  });

  // A closed meal with no seat left: the name and switches of someone not
  // signed up are locked, and a cook who has not entered a cost shows
  // "pending".
  test("closed meal with no seats left", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context, {
      mealData: {
        ...mealFixture,
        closed: true,
        closed_at: "2026-01-15T08:00:00Z",
        // Jane and Alice attend, plus one guest: three seats, all taken.
        max: 3,
        bills: [
          ...mealFixture.bills,
          { resident_id: 2, amount: "", no_cost: false },
        ],
      },
    });
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 10000,
    });
    await expect(
      page.getByLabel("Toggle Late for B - Bob Johnson"),
    ).toBeDisabled();
    // Bob is not signed up and there is no seat for him, so his name is
    // locked too: no pointer, and the not-allowed cursor.
    const bobCell = page.getByRole("cell", {
      name: "B - Bob Johnson",
      exact: true,
    });
    await expect(bobCell).toHaveAttribute("style", /cursor: not-allowed/);
    await expect(bobCell).toHaveAttribute("style", /pointer-events: none/);
    await expect(page.getByPlaceholder("pending")).toBeVisible();
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("meal-closed-full.png", {
      fullPage: true,
    });
  });

  test("close confirm bar with two blank cook costs", async ({
    page,
    context,
  }) => {
    await setupAuthenticatedPage(page, context, {
      mealData: {
        ...mealFixture,
        bills: [
          { resident_id: 1, amount: "", no_cost: false },
          { resident_id: 2, amount: "", no_cost: false },
        ],
      },
    });
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
      timeout: 10000,
    });

    await page.locator("text=Open / Close Meal").click();
    await expect(
      page.locator("text=Some cooks haven’t entered a cost yet"),
    ).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("close-confirm-bar-two-cooks.png", {
      fullPage: true,
    });
  });

  // A cook row with no cook takes no cost (#145). Its cost field is off
  // and dimmed, like the No cost switch next to it. Jane's row has a
  // cook, so her cost field is on.
  test("cook rows with no cook", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    const costs = page.getByRole("spinbutton", { name: "Set meal cost" });
    await expect(costs.first()).toHaveValue("25.50", { timeout: 10000 });
    await expect(costs.first()).toBeEnabled();
    await expect(costs.nth(1)).toBeDisabled();
    await expect(costs.nth(2)).toBeDisabled();
    await page.waitForTimeout(500);

    const cooksBox = page
      .getByRole("heading", { name: "Cooks" })
      .locator("xpath=ancestor::div[contains(@class, 'offwhite')][1]");
    await expect(cooksBox).toHaveScreenshot("cooks-no-cook.png");
  });

  // A cook row whose save has waited more than a second (#150): a small
  // spinner inside its cost box. The save never gets an answer here, so
  // the row stays in that look.
  test("cook row saving", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/meals/*/bills*", "PATCH");

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    const costs = page.getByRole("spinbutton", { name: "Set meal cost" });
    await expect(costs.first()).toHaveValue("25.50", { timeout: 10000 });
    await costs.first().fill("30.00");
    await costs.first().press("Enter");
    await expect(costs.first()).toHaveAttribute("aria-busy", "true", {
      timeout: 5000,
    });
    await expect(page.locator(".cost-spinner")).toBeVisible();
    await page.waitForTimeout(500);

    const cooksBox = page
      .getByRole("heading", { name: "Cooks" })
      .locator("xpath=ancestor::div[contains(@class, 'offwhite')][1]");
    await expect(cooksBox).toHaveScreenshot("cooks-saving.png");
  });

  // Turning "no cost" on over a typed cost asks first.
  test("no-cost confirm bar", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    await expect(
      page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
    ).toBeVisible({ timeout: 10000 });

    // The checkbox is drawn as a switch; its label is the thing to tap.
    await page.locator('label[for^="no_cost_switch-"]').first().click();
    await expect(page.getByRole("alertdialog", { name: /^Erase/ })).toBeVisible(
      {
        timeout: 5000,
      },
    );
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("no-cost-confirm-bar.png", {
      fullPage: true,
    });
  });

  // Carol cooked and was retired after (#91), so only her own row offers
  // her. Picking another name there would remove her bill, so it asks
  // first, with No on the left under the menu.
  test("remove retired cook confirm bar", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context, {
      mealData: {
        ...mealFixture,
        bills: [
          ...mealFixture.bills,
          { resident_id: 4, amount: "40.0", no_cost: false },
        ],
        residents: [
          ...mealFixture.residents,
          {
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
          },
        ],
      },
    });
    await page.clock.setFixedTime(FROZEN_NOW);

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");
    const carolsMenu = page
      .getByRole("combobox", { name: "Select meal cook" })
      .nth(1);
    await expect(carolsMenu).toHaveValue("4", { timeout: 10000 });

    await carolsMenu.selectOption("2");
    await expect(
      page.getByRole("alertdialog", { name: "Remove Carol Davis as a cook?" }),
    ).toBeVisible({ timeout: 5000 });
    // The menu still shows Carol until a Yes.
    await expect(carolsMenu).toHaveValue("4");
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("remove-cook-confirm-bar.png", {
      fullPage: true,
    });
  });

  test("login submitting", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/residents/token", "POST");

    await page.goto("/");
    await page.waitForLoadState("networkidle");
    await page.locator('input[aria-label="email"]').fill("jane@example.com");
    await page.locator('input[aria-label="password"]').fill("hunter2");
    await page.getByRole("button", { name: "Submit" }).click();
    await expect(page.locator(".button-loader")).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("login-submitting.png", {
      fullPage: true,
    });
  });

  test("password reset submitting", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    await page.clock.setFixedTime(FROZEN_NOW);
    await holdRoute(page, "**/api/v1/residents/password-reset/*", "POST");

    await page.goto("/reset-password/test-reset-token/");
    await page.waitForLoadState("networkidle");
    const modal = page.locator(".ReactModal__Content--after-open");
    await modal.locator('input[type="password"]').fill("hunter2hunter2");
    await modal.getByRole("button", { name: "Submit" }).click();
    await expect(modal.locator(".button-loader")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("password-reset-submitting.png", {
      fullPage: true,
    });
  });

  // The looks a failing server produces, with the answers the server
  // really gives: Rails' own 500 page for an error the API does not
  // rescue, and ApiController's sentence for a record that is not there.
  // The browser logs each failed request, and the app logs what it got.
  test.describe("with a failing backend", () => {
    test.use({
      allowedConsoleErrors: combinePatterns(
        httpFailurePattern,
        /^Bad response from server/,
        NOT_FOUND_LOG,
        /^Could not use the meal from the server:/,
        /^Error: no response received from server\.$/,
      ),
    });

    test("meal load failing", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/meals/42/cooks*", rails500);

      await page.goto("/meals/42/edit/");
      await expect(page.getByText("Trouble loading this meal.")).toBeVisible({
        timeout: 10000,
      });
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("meal-load-failed.png", {
        fullPage: true,
      });
    });

    test("meal not found", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/meals/999/cooks*", (route) =>
        route.fulfill({
          status: 404,
          contentType: "application/json",
          body: JSON.stringify({ message: NOT_FOUND_MESSAGE }),
        }),
      );

      await page.goto("/meals/999/edit/");
      await expect(page.getByText("This meal could not be found.")).toBeVisible(
        { timeout: 10000 },
      );
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("meal-not-found.png", {
        fullPage: true,
      });
    });

    // A 200 the page cannot use (#110): a bug, not a network state, so
    // the notice offers the way back and nothing retries.
    test("meal answer the page cannot use", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/meals/42/cooks*", (route) =>
        route.fulfill({
          status: 200,
          contentType: "application/json",
          body: "{}",
        }),
      );

      await page.goto("/meals/42/edit/");
      await expect(page.getByRole("alert")).toHaveText(
        /Something went wrong showing this meal\./,
        { timeout: 10000 },
      );
      await expect(
        page.getByRole("button", { name: "Back to calendar" }),
      ).toBeVisible();
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("meal-load-broken.png", {
        fullPage: true,
      });
    });

    // Rails' page has no message, so the toast says the server had a
    // problem, and the menu says it will try again.
    test("menu not saved", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/meals/*/description*", rails500);

      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");
      const textarea = page.getByLabel("Enter meal description");
      await expect(textarea).toBeEnabled({ timeout: 10000 });
      await textarea.fill("Pasta night with garlic bread and salad");
      // The menu's own status line, not the messages' polite region.
      await expect(
        page.getByRole("status").filter({ hasText: "Not saved" }),
      ).toBeVisible({ timeout: 10000 });
      await expect(page.locator(".toast--error .toast__message")).toHaveText(
        "The server had a problem. Please try again.",
      );
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("menu-not-saved.png", {
        fullPage: true,
      });
    });

    test("rotation failed to load", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/rotations/*", rails500);

      await page.goto("/calendar/all/2026-01-15/rotations/show/10/");
      await expect(page.getByText("Failed to load rotation.")).toBeVisible({
        timeout: 10000,
      });
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("rotation-failed.png", {
        fullPage: true,
      });
    });

    test("meal history failed to load", async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/meals/*/history*", rails500);

      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");
      const historyLink = page.locator("text=history").first();
      await expect(historyLink).toBeVisible({ timeout: 10000 });
      await historyLink.click();

      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal.getByText("Failed to load history.")).toBeVisible({
        timeout: 5000,
      });
      await expect(modal.getByText("Loading...")).toHaveCount(0);
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("meal-history-failed.png", {
        fullPage: true,
      });
    });

    // No answer at all for the reset link's name: the page says so
    // instead of "Loading..." forever, and stays (#115).
    test("password reset page with no answer", async ({ page }) => {
      await stubPusher(page);
      await disableIdleTimer(page);
      await mockApi(page);
      await page.clock.setFixedTime(FROZEN_NOW);
      await page.route("**/api/v1/residents/name/*", (route) =>
        route.abort("failed"),
      );

      await page.goto("/reset-password/test-reset-token/");
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(
        modal.getByText(
          "Could not load this page. Check your connection and try again.",
        ),
      ).toBeVisible({ timeout: 10000 });
      await expect(page).toHaveURL(/\/reset-password\/test-reset-token\/?$/);
      await page.waitForTimeout(500);

      await expect(page).toHaveScreenshot("password-reset-failed.png", {
        fullPage: true,
      });
    });
  });
});
