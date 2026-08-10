const { test, expect } = require("../helpers/test");
const {
  setupAuthenticatedPage,
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

  test("event lifecycle: create, edit, delete, each persisted", async ({
    page,
  }) => {
    await openCalendar(page);

    // CREATE — the form's Day defaults to the URL date.
    await page.locator("text=Event").first().click();
    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 5000 });
    await modal.locator("#event-new-title").fill("Lifecycle Test Party");
    // The real backend requires a day and times (the mocked suite
    // never enforced that): pick the 15th and 6-8 pm.
    await modal.locator("input[readonly]").click();
    await modal.locator(".rdp-root .rdp-day_button", { hasText: "15" }).click();
    await modal.locator("#event-new-start-time").selectOption("18:00");
    await modal.locator("#event-new-end-time").selectOption("20:00");
    const created = page.waitForResponse(
      (r) =>
        r.request().method() === "POST" &&
        r.url().includes("/api/v1/events") &&
        r.ok(),
    );
    await modal.locator("button:has-text('Create')").click();
    await created;

    await page.reload();
    await expect(page.locator("text=Lifecycle Test Party")).toBeVisible({
      timeout: 10000,
    });

    // EDIT — open by clicking the tile, change the title.
    await page.locator("text=Lifecycle Test Party").click();
    const editModal = page.locator(".ReactModal__Content--after-open");
    await expect(editModal.locator("#event-edit-title")).toHaveValue(
      "Lifecycle Test Party",
      { timeout: 10000 },
    );
    await editModal.locator("#event-edit-title").fill("Renamed Test Party");
    const updated = page.waitForResponse(
      (r) =>
        r.request().method() === "PATCH" &&
        r.url().includes("/api/v1/events") &&
        r.ok(),
    );
    await editModal.locator("button:has-text('Update')").click();
    await updated;

    await page.reload();
    await expect(page.locator("text=Renamed Test Party")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator("text=Lifecycle Test Party")).toBeHidden();

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
        r.url().includes("/api/v1/events") &&
        r.ok(),
    );
    await confirmOverlay.locator('.button-warning:has-text("Delete")').click();
    await deleted;

    await page.reload();
    await expect(page.locator("text=Renamed Test Party")).toBeHidden({
      timeout: 10000,
    });
  });

  test("discarding a dirty event form creates nothing", async ({ page }) => {
    await openCalendar(page);

    await page.locator("text=Event").first().click();
    const modal = page.locator(".ReactModal__Content--after-open").first();
    await modal.locator("#event-new-title").fill("Never Created");

    // Dismissing a dirty form asks; Discard closes without a POST.
    await modal.locator(".close-button").click();
    const confirmOverlay = page.locator(".ReactModal__Overlay").last();
    await expect(
      confirmOverlay.locator("text=Discard your changes?"),
    ).toBeVisible({ timeout: 5000 });
    await confirmOverlay.locator('button:has-text("Discard")').click();

    await page.reload();
    await expect(page.locator("text=Never Created")).toBeHidden({
      timeout: 10000,
    });
  });
});
