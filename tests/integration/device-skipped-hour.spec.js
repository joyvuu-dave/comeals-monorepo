const { test, expect } = require("../helpers/test");
const {
  COMMUNITY_TIMEZONE,
  clearStorage,
  loadAuthInfo,
  setupAuthenticatedPage,
} = require("../helpers/integration_setup");
const { zonedInstant } = require("../helpers/zoned_time");

// Saves from a phone in another zone, on nights when a clock changes,
// against the real backend (#129). The forms send the day and the
// times as fields, and the server makes the instant from them in the
// community's zone. Each test reads back what the server stored.
//
// The calendar used to hand the forms and the month each community time
// as a Date in the phone's zone. A time the phone's clock skips cannot
// be one, so it moved forward by the skip.

const auth = loadAuthInfo();
const AS_JANE = { Authorization: `Bearer ${auth.token}` };

// An event the way the event forms send one.
function fields(day, start, end) {
  const [year, month, date] = day.split("-").map(Number);
  const [startHours, startMinutes] = start.split(":");
  const [endHours, endMinutes] = end.split(":");
  return {
    start_year: year,
    start_month: month,
    start_day: date,
    start_hours: startHours,
    start_minutes: startMinutes,
    end_hours: endHours,
    end_minutes: endMinutes,
    all_day: false,
  };
}

async function storedEvent(request, id) {
  const response = await request.get(`/api/v1/events/${id}`, {
    headers: AS_JANE,
  });
  expect(response.status(), await response.text()).toBe(200);
  return response.json();
}

// The same instant, whatever offset the server writes it with.
function instantOf(text) {
  return new Date(text).toISOString();
}

// The event id from an open edit form's URL
// (/calendar/all/<date>/events/edit/<id>).
function openEventId(page) {
  const id = new URL(page.url()).pathname.split("/").filter(Boolean).pop();
  expect(id).toMatch(/^\d+$/);
  return id;
}

// The chip sits in the week of `day`, inside that day's column.
async function expectChipOnDay(page, title, day) {
  const cell = page.locator(".rbc-date-cell:not(.rbc-off-range)", {
    hasText: new RegExp(`^${day}$`),
  });
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

// Each event starts in the hour the phone's clock skips, or shows twice,
// that night.
const NIGHTS = [
  {
    zone: "America/Nuuk",
    night: "Greenland skips from 23:00 to midnight",
    day: "2026-03-28",
    start: "23:30",
    end: "23:45",
  },
  {
    zone: "America/Havana",
    night:
      "Havana skips from midnight to 01:00, and Los Angeles from 02:00 to 03:00",
    day: "2026-03-08",
    start: "00:30",
    end: "01:30",
  },
  {
    zone: "America/Havana",
    night:
      "Havana goes back from 01:00 to midnight, and Los Angeles from 02:00 to 01:00",
    day: "2026-11-01",
    start: "00:30",
    end: "01:30",
  },
];

for (const night of NIGHTS) {
  test.describe(`A phone in ${night.zone} on ${night.day}: ${night.night}`, () => {
    test.use({ timezoneId: night.zone });

    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
      // The phone's own clock really changes that night, or this test
      // tests nothing: its offset at noon the day before and at noon the
      // day after are not the same.
      expect(
        await page.evaluate((day) => {
          const [year, month, date] = day.split("-").map(Number);
          return (
            new Date(year, month - 1, date - 1, 12).getTimezoneOffset() -
            new Date(year, month - 1, date + 1, 12).getTimezoneOffset()
          );
        }, night.day),
      ).not.toBe(0);
    });

    test(`an event at ${night.start} is on its day, and an Update keeps its time`, async ({
      page,
      request,
    }) => {
      const title = `Night owls ${night.zone} ${night.day}`;
      const created = await request.post("/api/v1/events", {
        headers: AS_JANE,
        data: {
          title,
          description: "",
          ...fields(night.day, night.start, night.end),
        },
      });
      expect(created.status(), await created.text()).toBe(200);
      const expected = zonedInstant(
        `${night.day}T${night.start}`,
        COMMUNITY_TIMEZONE,
      ).toISOString();

      let eventId = null;
      try {
        await page.goto(`/calendar/all/${night.day}/`);
        const chip = page.locator(".rbc-event", { hasText: title });
        await expect(chip).toBeVisible({ timeout: 10000 });
        await expectChipOnDay(page, title, night.day.slice(8));

        await chip.click();
        const modal = page.locator(".ReactModal__Content--after-open");
        await expect(modal.locator("#event-edit-title")).toHaveValue(title, {
          timeout: 10000,
        });
        eventId = openEventId(page);
        const before = await storedEvent(request, eventId);
        expect(instantOf(before.start_date)).toBe(expected);

        const [year, month, date] = night.day.split("-");
        await expect(modal.locator("#event-edit-day")).toHaveValue(
          `${month}/${date}/${year}`,
        );
        await expect(modal.locator("#event-edit-start-time")).toHaveValue(
          night.start,
        );
        await expect(modal.locator("#event-edit-end-time")).toHaveValue(
          night.end,
        );

        await modal.locator("#event-edit-title").fill(`${title}, renamed`);
        const updated = page.waitForResponse(
          (r) =>
            r.request().method() === "PATCH" &&
            r.url().includes(`/api/v1/events/${eventId}/update`) &&
            r.ok(),
        );
        await modal.locator("button:has-text('Update')").click();
        await updated;
        await expect(page.locator(".ReactModal__Overlay")).toHaveCount(0, {
          timeout: 10000,
        });

        const stored = await storedEvent(request, eventId);
        expect(stored.title).toBe(`${title}, renamed`);
        expect(instantOf(stored.start_date)).toBe(expected);
        expect(instantOf(stored.end_date)).toBe(instantOf(before.end_date));
      } finally {
        if (eventId !== null) {
          await request.delete(`/api/v1/events/${eventId}/delete`, {
            headers: AS_JANE,
          });
        }
      }
    });
  });
}

// A new event made in the form, on the day both zones move their
// clocks forward.
test.describe("A phone in Havana on Sunday, Mar 8, 2026", () => {
  test.use({ timezoneId: "America/Havana" });

  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  test("a new event picked on Sunday at 7 pm is stored at 7 pm on Sunday in Los Angeles", async ({
    page,
    request,
  }) => {
    const title = "Seed swap on the switch day";
    await page.goto("/calendar/all/2026-03-08/events/new");
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });

    await modal.locator("#event-new-title").fill(title);
    await modal.locator("#event-new-day").click();
    await modal
      .getByRole("button", { name: "Sunday, March 8th, 2026" })
      .click();
    await expect(modal.locator("#event-new-day")).toHaveValue("03/08/2026");
    await modal.locator("#event-new-start-time").selectOption("19:00");
    await modal.locator("#event-new-end-time").selectOption("21:00");
    const created = page.waitForResponse(
      (r) =>
        r.request().method() === "POST" &&
        r.url().includes("/api/v1/events") &&
        r.ok(),
    );
    await modal.locator("button:has-text('Create')").click();
    await created;
    await expect(page.locator(".ReactModal__Overlay")).toHaveCount(0, {
      timeout: 10000,
    });

    let eventId = null;
    try {
      // Read the month from the server again: with Pusher stubbed,
      // nothing tells this page about the new event.
      await clearStorage(page);
      await page.reload();
      const chip = page.locator(".rbc-event", { hasText: title });
      await expect(chip).toBeVisible({ timeout: 10000 });
      await expectChipOnDay(page, title, "08");
      await chip.click();
      await expect(
        page.locator(".ReactModal__Content--after-open #event-edit-title"),
      ).toHaveValue(title, { timeout: 10000 });
      eventId = openEventId(page);

      const stored = await storedEvent(request, eventId);
      expect(instantOf(stored.start_date)).toBe(
        zonedInstant("2026-03-08T19:00", COMMUNITY_TIMEZONE).toISOString(),
      );
      expect(instantOf(stored.end_date)).toBe(
        zonedInstant("2026-03-08T21:00", COMMUNITY_TIMEZONE).toISOString(),
      );
    } finally {
      if (eventId !== null) {
        await request.delete(`/api/v1/events/${eventId}/delete`, {
          headers: AS_JANE,
        });
      }
    }
  });
});
