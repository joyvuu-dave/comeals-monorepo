const { test, expect } = require("../helpers/test");
const {
  setupAuthenticatedPage,
  FAKE_TODAY,
} = require("../helpers/integration_setup");

// Both reservation types against the real backend (plan item 4):
// create, edit, delete, each proven by a reload; plus the discard
// gate on a dirty form. Tests create their own reservations and
// delete them, leaving the seeded calendar as found.

test.describe("Reservations (real backend)", () => {
  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
  });

  async function openCalendar(page) {
    await page.goto(`/calendar/all/${FAKE_TODAY}/`);
    await expect(page.locator(".rbc-calendar")).toBeVisible({
      timeout: 10000,
    });
  }

  function response(page, method, urlPart) {
    return page.waitForResponse(
      (r) =>
        r.request().method() === method && r.url().includes(urlPart) && r.ok(),
    );
  }

  test("common house lifecycle: create, edit, delete, each persisted", async ({
    page,
  }) => {
    await openCalendar(page);

    // CREATE — resident + title; day and times keep their defaults.
    await page.locator("text=Common House").first().click();
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#ch-new-resident")).toBeVisible({
      timeout: 5000,
    });
    await modal.locator("#ch-new-resident").selectOption({ index: 1 });
    await modal.locator("#ch-new-title").fill("Lifecycle Test Meetup");
    // The real backend requires a day and times.
    await modal.locator("input[readonly]").click();
    await modal.locator(".rdp-root .rdp-day_button", { hasText: "15" }).click();
    // 2-4 pm: the seeded Book Club holds 10-12 on this day, and the
    // server refuses overlapping reservations with a 400.
    await modal.locator("#ch-new-start-time").selectOption("14:00");
    await modal.locator("#ch-new-end-time").selectOption("16:00");
    const created = response(page, "POST", "/api/v1/common-house-reservations");
    await modal.locator("button:has-text('Create')").click();
    await created;

    await page.reload();
    // The tile title is multiline (time range, "Common House", the
    // title, the resident) — find it by the unique title line.
    const tile = page.locator('.rbc-event:has-text("Lifecycle Test Meetup")');
    await expect(tile).toBeVisible({ timeout: 10000 });

    // EDIT — retitle through the tile's modal.
    await tile.click();
    const editModal = page.locator(".ReactModal__Content--after-open");
    await expect(editModal.locator("#ch-edit-title")).toHaveValue(
      "Lifecycle Test Meetup",
      { timeout: 10000 },
    );
    await editModal.locator("#ch-edit-title").fill("Renamed Test Meetup");
    const updated = response(
      page,
      "PATCH",
      "/api/v1/common-house-reservations",
    );
    await editModal.locator("button:has-text('Update')").click();
    await updated;

    await page.reload();
    await expect(
      page.locator('.rbc-event:has-text("Renamed Test Meetup")'),
    ).toBeVisible({ timeout: 10000 });

    // DELETE — through the armed confirm dialog.
    await page.locator('.rbc-event:has-text("Renamed Test Meetup")').click();
    const deleteModal = page.locator(".ReactModal__Content--after-open");
    await expect(deleteModal.locator("#ch-edit-title")).toBeVisible({
      timeout: 10000,
    });
    await deleteModal.locator("button:has-text('Delete')").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(confirmOverlay.locator(".button-warning")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);
    const deleted = response(
      page,
      "DELETE",
      "/api/v1/common-house-reservations",
    );
    await confirmOverlay.locator('.button-warning:has-text("Delete")').click();
    await deleted;

    await page.reload();
    await expect(
      page.locator('.rbc-event:has-text("Renamed Test Meetup")'),
    ).toBeHidden({ timeout: 10000 });
  });

  test("guest room lifecycle: create, edit, delete, each persisted", async ({
    page,
  }) => {
    await openCalendar(page);

    // CREATE — pick Alice as host; the day keeps its default.
    await page.locator("text=Guest Room").first().click();
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal.locator("#guest-room-new-host")).toBeVisible({
      timeout: 5000,
    });
    await modal
      .locator("#guest-room-new-host")
      .selectOption({ label: "C - Alice Williams" });
    // The real backend requires a day.
    await modal.locator("input[readonly]").click();
    await modal.locator(".rdp-root .rdp-day_button", { hasText: "20" }).click();
    const created = response(page, "POST", "/api/v1/guest-room-reservations");
    await modal.locator("button:has-text('Create')").click();
    await created;

    await page.reload();
    // The tile is "Guest Room" plus the host; scope by unit so the
    // seeded reservation (Bob, Unit B) never matches.
    const tile = page.locator(
      '.rbc-event:has-text("Guest Room"):has-text("Unit C")',
    );
    await expect(tile).toBeVisible({ timeout: 10000 });

    // EDIT — hand the reservation to Jane.
    await tile.click();
    const editModal = page.locator(".ReactModal__Content--after-open");
    await expect(editModal.locator("#guest-room-edit-host")).toBeVisible({
      timeout: 10000,
    });
    await editModal
      .locator("#guest-room-edit-host")
      .selectOption({ label: "A - Jane Smith" });
    const updated = response(page, "PATCH", "/api/v1/guest-room-reservations");
    await editModal.locator("button:has-text('Update')").click();
    await updated;

    await page.reload();
    const janeTile = page.locator(
      '.rbc-event:has-text("Guest Room"):has-text("Unit A")',
    );
    await expect(janeTile).toBeVisible({ timeout: 10000 });

    // DELETE — through the armed confirm dialog.
    await janeTile.click();
    const deleteModal = page.locator(".ReactModal__Content--after-open");
    await expect(deleteModal.locator("#guest-room-edit-host")).toBeVisible({
      timeout: 10000,
    });
    await deleteModal.locator("button:has-text('Delete')").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(confirmOverlay.locator(".button-warning")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);
    const deleted = response(page, "DELETE", "/api/v1/guest-room-reservations");
    await confirmOverlay.locator('.button-warning:has-text("Delete")').click();
    await deleted;

    await page.reload();
    await expect(janeTile).toBeHidden({ timeout: 10000 });
  });

  test("discarding a dirty reservation form creates nothing", async ({
    page,
  }) => {
    await openCalendar(page);

    await page.locator("text=Common House").first().click();
    const modal = page.locator(".ReactModal__Content--after-open").first();
    await modal.locator("#ch-new-title").fill("Never Reserved");

    await modal.locator(".close-button").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(
      confirmOverlay.locator("text=Discard your changes?"),
    ).toBeVisible({ timeout: 5000 });
    await confirmOverlay.locator('button:has-text("Discard")').click();

    await page.reload();
    await expect(
      page.locator('.rbc-event:has-text("Never Reserved")'),
    ).toBeHidden({ timeout: 10000 });
  });
});
