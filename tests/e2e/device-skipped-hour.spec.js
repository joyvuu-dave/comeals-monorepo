const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");
const calendarFixture = require("../fixtures/calendar.json");

// The calendar shows every time in the community's zone, on every
// device (#129). The community is in Los Angeles and the phone is in a
// zone whose clocks skip an hour on a day this file looks at. The app
// used to hand the calendar and the date pickers each community time as
// a Date in the phone's own zone. A time the phone's clock skips cannot
// be such a Date, so it moved forward by the skip: in Greenland an event
// at 23:30 on Saturday was drawn on Sunday.
//
// Greenland (America/Nuuk) skips from 23:00 to midnight on Saturday,
// Mar 28, 2026. Havana skips from midnight to 01:00 on Sunday, Mar 8,
// 2026, the same day Los Angeles skips from 02:00 to 03:00.

// A month with only these events, the way the server sends it.
function monthWith(month, events, commonHouse = []) {
  return {
    ...calendarFixture,
    month,
    meals: [],
    bills: [],
    rotations: [],
    birthdays: [],
    guest_room_reservations: [],
    common_house_reservations: commonHouse,
    events,
  };
}

function chip(title, start, end, url) {
  return { id: `chip/${title}`, title, start, end, url, color: "#7ebc35" };
}

// The record an edit form reads, and the body of the form's save.
// Returns a function that gives the body once the form has sent it.
async function serveRecord(page, path, record) {
  let saved = null;
  await page.route(`**/api/v1/${path}**`, (route) => {
    if (route.request().method() === "GET") {
      return route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(record),
      });
    }
    saved = route.request().postDataJSON();
    return route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ message: "Updated." }),
    });
  });
  return () => saved;
}

// The date cell of `day` ("28") in the month on screen.
function dayCell(page, day) {
  return page.locator(".rbc-date-cell:not(.rbc-off-range)", {
    hasText: new RegExp(`^${day}$`),
  });
}

// The chip sits in the week of `day`, inside that day's column.
async function expectChipOnDay(page, title, day) {
  const cell = dayCell(page, day);
  const week = cell.locator(
    "xpath=ancestor::div[contains(@class, 'rbc-month-row')]",
  );
  await expect(week.locator(".rbc-event", { hasText: title })).toHaveCount(1);
  const cellBox = await cell.boundingBox();
  const chipBox = await page
    .locator(".rbc-event", { hasText: title })
    .boundingBox();
  const chipMiddle = chipBox.x + chipBox.width / 2;
  expect(chipMiddle).toBeGreaterThan(cellBox.x);
  expect(chipMiddle).toBeLessThan(cellBox.x + cellBox.width);
}

// Run the block's tests on a phone set to `zone`, and check that the
// phone's own clock skips the hour this file depends on: a Date made in
// the phone's zone for `skipped` (year, month from 0, day, hour, minute)
// moves forward to `movedTo` (day, hour). Otherwise this file tests
// nothing. The check is on the clock, not the zone's name: Chromium
// names America/Nuuk by its old name, America/Godthab.
function useZone(zone, skipped, movedTo) {
  test.use({ timezoneId: zone });
  test.beforeEach(async ({ page }) => {
    expect(
      await page.evaluate((fields) => {
        const moved = new Date(...fields);
        return [moved.getDate(), moved.getHours()];
      }, skipped),
    ).toEqual(movedTo);
  });
}

test.describe("A phone in Greenland on the night its clocks skip", () => {
  useZone("America/Nuuk", [2026, 2, 28, 23, 30], [29, 0]);

  // 23:30 in Los Angeles on Saturday, Mar 28: already 05:30 on Sunday
  // in Greenland.
  const LATE_SATURDAY = new Date("2026-03-28T23:30:00-07:00");
  const LATE_EVENT = {
    id: 71,
    title: "Late talk",
    description: "",
    start_date: "2026-03-28T23:30:00.000-07:00",
    end_date: "2026-03-28T23:45:00.000-07:00",
    allday: false,
    created_at: "2026-03-01T09:00:00.000-08:00",
    updated_at: "2026-03-01T09:00:00.000-08:00",
  };
  const LATE_RESERVATION = {
    event: {
      id: 51,
      resident_id: 1,
      title: "Night swim",
      start_date: "2026-03-28T23:00:00.000-07:00",
      end_date: "2026-03-28T23:45:00.000-07:00",
    },
  };

  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context, {
      mealData: { ...mealFixture, date: "2026-03-28" },
      calendarData: monthWith(
        3,
        [
          chip(
            "Late talk",
            LATE_EVENT.start_date,
            LATE_EVENT.end_date,
            "events/edit/71",
          ),
        ],
        [
          chip(
            "Night swim",
            LATE_RESERVATION.event.start_date,
            LATE_RESERVATION.event.end_date,
            "common-house-reservations/edit/51",
          ),
        ],
      ),
    });
    await page.clock.setFixedTime(LATE_SATURDAY);
  });

  test("the month draws the 23:30 event on Saturday and marks Saturday as today", async ({
    page,
  }) => {
    await page.goto("/calendar/all/2026-03-28/");
    await expect(
      page.locator(".rbc-event", { hasText: "Late talk" }),
    ).toBeVisible({ timeout: 10000 });

    await expectChipOnDay(page, "Late talk", "28");
    await expectChipOnDay(page, "Night swim", "28");
    await expect(page.locator(".rbc-date-cell.rbc-now")).toHaveText("28");
  });

  test("the event form shows Saturday and saves 23:30 on Saturday", async ({
    page,
  }) => {
    const saved = await serveRecord(page, "events/71", LATE_EVENT);
    await page.goto("/calendar/all/2026-03-28/events/edit/71");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("fieldset[data-populated]")).toBeVisible({
      timeout: 10000,
    });

    await expect(modal.locator("#event-edit-day")).toHaveValue("03/28/2026");
    await modal.locator("#event-edit-day").click();
    // Saturday is the chosen day, and it is today in Los Angeles.
    await expect(
      modal.getByRole("button", {
        name: "Today, Saturday, March 28th, 2026, selected",
      }),
    ).toBeVisible();
    // Close the picker without choosing.
    await modal.locator("#event-edit-title").click();

    await modal.locator("#event-edit-title").fill("Late talk, moved");
    await modal.getByRole("button", { name: "Update" }).click();

    await expect.poll(saved, { timeout: 5000 }).toBeTruthy();
    expect(saved()).toEqual({
      title: "Late talk, moved",
      description: "",
      start_year: 2026,
      start_month: 3,
      start_day: 28,
      start_hours: "23",
      start_minutes: "30",
      end_hours: "23",
      end_minutes: "45",
      all_day: false,
    });
    await expect(modal).toHaveCount(0);
  });

  test("the common house form shows Saturday and saves 23:00 on Saturday", async ({
    page,
  }) => {
    const saved = await serveRecord(
      page,
      "common-house-reservations/51",
      LATE_RESERVATION,
    );
    await page.goto(
      "/calendar/all/2026-03-28/common-house-reservations/edit/51",
    );
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("fieldset[data-populated]")).toBeVisible({
      timeout: 10000,
    });

    await expect(modal.locator("#ch-edit-day")).toHaveValue("03/28/2026");
    await modal.locator("#ch-edit-day").click();
    await expect(
      modal.getByRole("button", {
        name: "Today, Saturday, March 28th, 2026, selected",
      }),
    ).toBeVisible();
    await modal.locator("#ch-edit-title").click();

    await modal.locator("#ch-edit-title").fill("Night swim, longer");
    await modal.getByRole("button", { name: "Update" }).click();

    await expect.poll(saved, { timeout: 5000 }).toBeTruthy();
    expect(saved()).toEqual({
      resident_id: 1,
      start_year: 2026,
      start_month: 3,
      start_day: 28,
      start_hours: "23",
      start_minutes: "00",
      end_hours: "23",
      end_minutes: "45",
      title: "Night swim, longer",
    });
    await expect(modal).toHaveCount(0);
  });

  test("the meal page shows Saturday's meal as today", async ({ page }) => {
    await page.goto("/meals/42/edit/");

    await expect(
      page.getByRole("heading", { level: 2, name: /Mar \d/ }),
    ).toHaveText("Sat, Mar 28th", { timeout: 10000 });
    await expect(page.locator("h3.text-black")).toHaveText("Today");
  });
});

test.describe("A phone in Havana on the day both zones skip an hour", () => {
  useZone("America/Havana", [2026, 2, 8, 0, 30], [8, 1]);

  // Noon in Los Angeles on Sunday, Mar 8 (15:00 in Havana). Both zones
  // moved their clocks forward earlier that day.
  const SUNDAY_NOON = new Date("2026-03-08T12:00:00-07:00");
  const EVENING_EVENT = {
    id: 72,
    title: "Potluck",
    description: "",
    start_date: "2026-03-08T19:00:00.000-07:00",
    end_date: "2026-03-08T21:00:00.000-07:00",
    allday: false,
    created_at: "2026-03-01T09:00:00.000-08:00",
    updated_at: "2026-03-01T09:00:00.000-08:00",
  };
  const EVENING_RESERVATION = {
    event: {
      id: 52,
      resident_id: 2,
      title: "Choir",
      start_date: "2026-03-08T18:00:00.000-07:00",
      end_date: "2026-03-08T20:00:00.000-07:00",
    },
  };

  function setup(page, context, mealDate) {
    return setupAuthenticatedPage(page, context, {
      mealData: { ...mealFixture, date: mealDate },
      calendarData: monthWith(3, [
        // Listed out of order, so the calendar must sort them.
        chip(
          "At one",
          "2026-03-08T01:00:00.000-08:00",
          "2026-03-08T01:15:00.000-08:00",
          "events/edit/73",
        ),
        chip(
          "At half past midnight",
          "2026-03-08T00:30:00.000-08:00",
          "2026-03-08T00:45:00.000-08:00",
          "events/edit/74",
        ),
      ]),
    });
  }

  test.beforeEach(async ({ page }) => {
    await page.clock.setFixedTime(SUNDAY_NOON);
  });

  test("the month keeps Sunday's early events in the order of their times", async ({
    page,
    context,
  }) => {
    await setup(page, context, "2026-03-08");
    await page.goto("/calendar/all/2026-03-08/");
    const early = page.locator(".rbc-event", {
      hasText: "At half past midnight",
    });
    const late = page.locator(".rbc-event", { hasText: "At one" });
    await expect(early).toBeVisible({ timeout: 10000 });

    await expectChipOnDay(page, "At half past midnight", "08");
    await expectChipOnDay(page, "At one", "08");
    expect((await early.boundingBox()).y).toBeLessThan(
      (await late.boundingBox()).y,
    );
    await expect(page.locator(".rbc-date-cell.rbc-now")).toHaveText("08");
  });

  test("the event form shows Sunday and saves 19:00 on Sunday", async ({
    page,
    context,
  }) => {
    await setup(page, context, "2026-03-08");
    const saved = await serveRecord(page, "events/72", EVENING_EVENT);
    await page.goto("/calendar/all/2026-03-08/events/edit/72");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("fieldset[data-populated]")).toBeVisible({
      timeout: 10000,
    });

    await expect(modal.locator("#event-edit-day")).toHaveValue("03/08/2026");
    await modal.locator("#event-edit-day").click();
    await expect(
      modal.getByRole("button", {
        name: "Today, Sunday, March 8th, 2026, selected",
      }),
    ).toBeVisible();
    await modal.locator("#event-edit-title").click();

    await modal.locator("#event-edit-title").fill("Potluck, moved");
    await modal.getByRole("button", { name: "Update" }).click();

    await expect.poll(saved, { timeout: 5000 }).toBeTruthy();
    expect(saved()).toEqual({
      title: "Potluck, moved",
      description: "",
      start_year: 2026,
      start_month: 3,
      start_day: 8,
      start_hours: "19",
      start_minutes: "00",
      end_hours: "21",
      end_minutes: "00",
      all_day: false,
    });
  });

  test("the common house form shows Sunday and saves 18:00 on Sunday", async ({
    page,
    context,
  }) => {
    await setup(page, context, "2026-03-08");
    const saved = await serveRecord(
      page,
      "common-house-reservations/52",
      EVENING_RESERVATION,
    );
    await page.goto(
      "/calendar/all/2026-03-08/common-house-reservations/edit/52",
    );
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("fieldset[data-populated]")).toBeVisible({
      timeout: 10000,
    });

    await expect(modal.locator("#ch-edit-day")).toHaveValue("03/08/2026");
    await modal.locator("#ch-edit-day").click();
    await expect(
      modal.getByRole("button", {
        name: "Today, Sunday, March 8th, 2026, selected",
      }),
    ).toBeVisible();
    await modal.locator("#ch-edit-title").click();

    await modal.locator("#ch-edit-title").fill("Choir, longer");
    await modal.getByRole("button", { name: "Update" }).click();

    await expect.poll(saved, { timeout: 5000 }).toBeTruthy();
    expect(saved()).toEqual({
      resident_id: 2,
      start_year: 2026,
      start_month: 3,
      start_day: 8,
      start_hours: "18",
      start_minutes: "00",
      end_hours: "20",
      end_minutes: "00",
      title: "Choir, longer",
    });
  });

  test("a new event made in the picker on Sunday is saved on Sunday", async ({
    page,
    context,
  }) => {
    await setup(page, context, "2026-03-08");
    let created = null;
    await page.route(/\/api\/v1\/events(\?.*)?$/, (route) => {
      created = route.request().postDataJSON();
      return route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Event has been created" }),
      });
    });
    await page.goto("/calendar/all/2026-03-08/events/new");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });

    await modal.locator("#event-new-title").fill("Seed swap");
    await modal.locator("#event-new-day").click();
    await modal
      .getByRole("button", { name: "Today, Sunday, March 8th, 2026" })
      .click();
    await expect(modal.locator("#event-new-day")).toHaveValue("03/08/2026");
    await modal
      .locator("#event-new-start-time")
      .selectOption({ label: "7:00 PM" });
    await modal
      .locator("#event-new-end-time")
      .selectOption({ label: "9:00 PM" });
    await modal.getByRole("button", { name: "Create" }).click();

    await expect.poll(() => created, { timeout: 5000 }).toBeTruthy();
    expect(created).toEqual({
      title: "Seed swap",
      description: "",
      start_year: 2026,
      start_month: 3,
      start_day: 8,
      start_hours: "19",
      start_minutes: "00",
      end_hours: "21",
      end_minutes: "00",
      all_day: false,
    });
  });

  // new Date(2026, 2, 9) is midnight on Monday in Havana, and
  // dayjs("2026-03-08") is 01:00 on Sunday, because Sunday has no
  // midnight there. 23 hours apart counted as 0 days: the meal page said
  // "Today" for Monday's meal, and "Tomorrow" for Tuesday's.
  test("the meal page shows Monday's meal as tomorrow", async ({
    page,
    context,
  }) => {
    await setup(page, context, "2026-03-09");
    await page.goto("/meals/42/edit/");

    await expect(
      page.getByRole("heading", { level: 2, name: /Mar \d/ }),
    ).toHaveText("Mon, Mar 9th", { timeout: 10000 });
    await expect(page.locator("h3.text-black")).toHaveText("Tomorrow");
  });

  test("the meal page shows Sunday's meal as today", async ({
    page,
    context,
  }) => {
    await setup(page, context, "2026-03-08");
    await page.goto("/meals/42/edit/");

    await expect(
      page.getByRole("heading", { level: 2, name: /Mar \d/ }),
    ).toHaveText("Sun, Mar 8th", { timeout: 10000 });
    await expect(page.locator("h3.text-black")).toHaveText("Today");
  });
});
