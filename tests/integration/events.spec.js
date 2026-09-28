const { test, expect } = require("../helpers/test");
const {
  setupAuthenticatedPage,
  reloadCalendar,
  FAKE_TODAY,
} = require("../helpers/integration_setup");

// The event lifecycle against the real backend (plan item 4): create,
// edit, delete, each proven by a reload. The test creates its own
// event and deletes it, so the seeded calendar is left as found.

test.describe("Events (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  async function openCalendar(page) {
    await page.goto(`/calendar/all/${FAKE_TODAY}/`);
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });
  }

  // A successful save closes the modal by navigating back to the
  // calendar URL, and that happens after the response arrives. Wait
  // for the close before reloading: a reload that fires first lands
  // on the modal's own URL and reopens the modal on top of the
  // calendar (the race behind the 2026-08-10 CI failure in the
  // reservations spec — this spec shares the pattern).
  async function modalClosed(page) {
    await expect(page.locator(".ReactModal__Overlay")).toHaveCount(0, {
      timeout: 10000,
    });
  }

  // The event id from an open edit modal's URL
  // (/calendar/all/<date>/events/edit/<id>/).
  function openEventId(page) {
    const id = new URL(page.url()).pathname.split("/").filter(Boolean).pop();
    expect(id).toMatch(/^\d+$/);
    return id;
  }

  // Fill a new-event form the server would accept: a title, the 15th,
  // 6-8 pm. The real backend refuses an event with no day or times.
  async function fillNewEvent(modal, title) {
    await modal.locator("#event-new-title").fill(title);
    await modal.locator("input[readonly]").click();
    await modal.locator(".rdp-root .rdp-day_button", { hasText: "15" }).click();
    await modal.locator("#event-new-start-time").selectOption("18:00");
    await modal.locator("#event-new-end-time").selectOption("20:00");
  }

  test("event lifecycle: create, edit, delete, each persisted", async ({
    page,
  }) => {
    await openCalendar(page);

    // CREATE — the form starts with no day, so the test picks one.
    await page.locator("text=Event").first().click();
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 5000 });
    await fillNewEvent(modal, "Lifecycle Test Party");
    const created = page.waitForResponse(
      (r) =>
        r.request().method() === "POST" &&
        r.url().includes("/api/v1/events") &&
        r.ok(),
    );
    await modal.locator("button:has-text('Create')").click();
    await created;
    await modalClosed(page);

    await reloadCalendar(page);
    await expect(page.locator("text=Lifecycle Test Party")).toBeVisible();

    // EDIT — open by clicking the tile, change the title.
    await page.locator("text=Lifecycle Test Party").click();
    const editModal = page.locator(".ReactModal__Content--after-open");
    await expect(editModal.locator("#event-edit-title")).toHaveValue(
      "Lifecycle Test Party",
      { timeout: 10000 },
    );
    const eventId = openEventId(page);
    await editModal.locator("#event-edit-title").fill("Renamed Test Party");
    const updated = page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes(`/api/v1/events/${eventId}/update`) &&
        r.ok(),
    );
    await editModal.locator("button:has-text('Update')").click();
    await updated;
    await modalClosed(page);

    await reloadCalendar(page);
    await expect(page.locator("text=Renamed Test Party")).toBeVisible();
    await expect(page.locator("text=Lifecycle Test Party")).toHaveCount(0);

    // DELETE — through the armed confirm dialog.
    await page.locator("text=Renamed Test Party").click();
    const deleteModal = page.locator(".ReactModal__Content--after-open");
    await expect(deleteModal.locator("#event-edit-title")).toBeVisible({
      timeout: 10000,
    });
    await deleteModal.locator("button:has-text('Delete')").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(
      confirmOverlay.locator("text=Do you really want to delete this event?"),
    ).toBeVisible({ timeout: 5000 });
    // The destructive button ignores clicks while it arms.
    await page.waitForTimeout(500);
    const deleted = page.waitForResponse(
      (r) =>
        r.request().method() === "DELETE" &&
        r.url().includes(`/api/v1/events/${eventId}/delete`) &&
        r.ok(),
    );
    await confirmOverlay.locator('.button-warning:has-text("Delete")').click();
    await deleted;
    await modalClosed(page);

    // reloadCalendar waits for the month to be drawn, so a tile that
    // is still there would be found.
    await reloadCalendar(page);
    await expect(page.locator("text=Renamed Test Party")).toHaveCount(0);
  });

  test("discarding a dirty event form creates nothing", async ({ page }) => {
    const posts = [];
    page.on("request", (r) => {
      if (r.method() === "POST" && r.url().includes("/api/v1/events")) {
        posts.push(r.url());
      }
    });
    await openCalendar(page);

    // A form the server would accept, so a Discard that sent it would
    // really create an event.
    await page.locator("text=Event").first().click();
    const modal = page.locator(".ReactModal__Content--after-open").first();
    await fillNewEvent(modal, "Never Created");

    // Dismissing a dirty form asks first.
    await modal.locator(".close-button").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(
      confirmOverlay.locator("text=Discard your changes?"),
    ).toBeVisible({ timeout: 5000 });
    // Discard ignores clicks for its first 400 ms.
    await page.waitForTimeout(450);
    await confirmOverlay.locator('button:has-text("Discard")').click();

    // Discard closes the form, back on the calendar, and sends nothing.
    await modalClosed(page);
    await expect(page).toHaveURL(new RegExp(`/calendar/all/${FAKE_TODAY}/?$`));
    expect(posts).toEqual([]);

    await reloadCalendar(page);
    await expect(page.locator("text=Never Created")).toHaveCount(0);
  });
});
