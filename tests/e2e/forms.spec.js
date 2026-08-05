const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");

test.describe("Form CRUD", () => {
  test.describe("Events", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("create a new event sends POST with form data", async ({ page }) => {
      let eventPayload = null;
      let eventMethod = null;
      await page.route("**/api/v1/events?*", (route) => {
        eventMethod = route.request().method();
        if (eventMethod === "POST") {
          eventPayload = route.request().postDataJSON();
        }
        route.fulfill({ status: 200, body: "{}" });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Click "Event" button in sidebar to open create modal
      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Fill in the title
      const titleInput = modal.locator('input[type="text"]').first();
      await titleInput.fill("Test Event");

      // Submit
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // API: POST with title in the payload
      await expect.poll(() => eventPayload, { timeout: 5000 }).toBeTruthy();
      expect(eventMethod).toBe("POST");
      expect(eventPayload.title).toBe("Test Event");
    });

    // The discard gate (ADR 0006): a dirty form never closes silently.
    test("dismissing a dirty form asks, Keep editing keeps it, Discard closes it", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open").first();
      await expect(modal).toBeVisible({ timeout: 5000 });
      await modal.locator("#event-new-title").fill("Movie Night");

      // Escape on a dirty form asks instead of closing.
      await page.keyboard.press("Escape");
      const confirmOverlay = page.locator(".ReactModal__Overlay").last();
      await expect(
        confirmOverlay.locator("text=Discard your changes?"),
      ).toBeVisible({ timeout: 5000 });

      // Keep editing returns to the form with the changes intact.
      await confirmOverlay.locator('button:has-text("Keep editing")').click();
      await expect(modal.locator("#event-new-title")).toHaveValue(
        "Movie Night",
      );

      // The X asks too; Discard (armed after 400ms) closes the modal.
      await modal.locator(".close-button").click();
      await expect(
        page
          .locator(".ReactModal__Overlay")
          .last()
          .locator("text=Discard your changes?"),
      ).toBeVisible({ timeout: 5000 });
      await page.waitForTimeout(450);
      await page
        .locator(".ReactModal__Overlay")
        .last()
        .locator('button:has-text("Discard")')
        .click();
      await page.waitForSelector(".ReactModal__Content--after-open", {
        state: "detached",
      });
    });

    test("edit an existing event loads data via GET", async ({ page }) => {
      let eventGetUrl = null;
      await page.route("**/api/v1/events/**", (route) => {
        if (route.request().method() === "GET") {
          eventGetUrl = route.request().url();
        }
        route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            id: 70,
            title: "Community Meeting",
            description: "Monthly community meeting",
            start_date: "2026-01-28T19:00:00",
            end_date: "2026-01-28T21:00:00",
            allday: false,
          }),
        });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Click event to open edit modal
      await page.locator("text=Community Meeting").click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 10000 });

      // Should show the edit fieldset
      await expect(modal.locator("fieldset legend")).toBeVisible({
        timeout: 10000,
      });

      // API: GET to fetch event data (URL contains event ID 70)
      expect(eventGetUrl).toBeTruthy();
      expect(eventGetUrl).toContain("/events/70");
    });

    test("delete an event sends DELETE after confirmation", async ({
      page,
    }) => {
      let deleteUrl = null;
      let deleteMethod = null;
      await page.route("**/api/v1/events/**", (route) => {
        const method = route.request().method();
        if (method === "DELETE") {
          deleteMethod = method;
          deleteUrl = route.request().url();
        }
        if (method === "GET") {
          route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify({
              id: 70,
              title: "Community Meeting",
              description: "Monthly community meeting",
              start_date: "2026-01-28T19:00:00",
              end_date: "2026-01-28T21:00:00",
              allday: false,
            }),
          });
        } else {
          route.fulfill({ status: 200, body: "{}" });
        }
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Open event edit modal
      await page.locator("text=Community Meeting").click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 10000 });
      await expect(modal.locator("fieldset legend")).toBeVisible({
        timeout: 10000,
      });

      // Click delete
      await modal.locator("button:has-text('Delete')").click();

      // Confirmation modal should appear
      const confirmOverlay = page.locator(".ReactModal__Overlay").last();
      await expect(
        confirmOverlay.locator("text=Do you really want to delete this event?"),
      ).toBeVisible({ timeout: 5000 });
      // The confirm button is armed only after 400ms (ConfirmModal's
      // armMs), so a click cannot land before a person could read the
      // question. Wait past the delay, then click.
      await page.waitForTimeout(450);
      await confirmOverlay
        .locator('.button-warning:has-text("Delete")')
        .click();

      // API: DELETE to /events/70/delete
      await expect.poll(() => deleteMethod, { timeout: 5000 }).toBe("DELETE");
      expect(deleteUrl).toContain("/events/70");
    });
  });

  test.describe("Common House Reservations", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("create a new common house reservation sends POST", async ({
      page,
    }) => {
      let postPayload = null;
      let postMethod = null;
      await page.route("**/api/v1/common-house-reservations?*", (route) => {
        postMethod = route.request().method();
        if (postMethod === "POST") {
          postPayload = route.request().postDataJSON();
        }
        route.fulfill({ status: 200, body: "{}" });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Click "Common House" button in sidebar
      await page.locator("text=Common House").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Select a resident from dropdown
      const residentSelect = modal.locator("#ch-new-resident");
      await expect(residentSelect).toBeVisible({ timeout: 3000 });
      await residentSelect.selectOption({ index: 1 });

      // Submit
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // API: POST with resident_id
      await expect.poll(() => postPayload, { timeout: 5000 }).toBeTruthy();
      expect(postMethod).toBe("POST");
      expect(postPayload.resident_id).toBeDefined();
    });
  });

  test.describe("Guest Room Reservations", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("create a new guest room reservation sends POST", async ({ page }) => {
      let postPayload = null;
      let postMethod = null;
      await page.route("**/api/v1/guest-room-reservations?*", (route) => {
        postMethod = route.request().method();
        if (postMethod === "POST") {
          postPayload = route.request().postDataJSON();
        }
        route.fulfill({ status: 200, body: "{}" });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Click "Guest Room" button in sidebar
      await page.locator("text=Guest Room").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Select a host from dropdown
      const hostSelect = modal.locator("#guest-room-new-host");
      await expect(hostSelect).toBeVisible({ timeout: 3000 });
      await hostSelect.selectOption({ index: 1 });

      // Submit
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // API: POST with resident_id
      await expect.poll(() => postPayload, { timeout: 5000 }).toBeTruthy();
      expect(postMethod).toBe("POST");
      expect(postPayload.resident_id).toBeDefined();
    });

    // Regression: react-day-picker stops its day click's propagation,
    // which used to strand react-modal's shouldClose flag at false —
    // after picking a day, the first click outside the form was
    // silently eaten and only the second one raised the discard
    // question. The overlay now closes on its own mousedown (see
    // calendar/show.jsx), so ONE click must ask.
    test("after picking a day, one click outside the form asks", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-01-15/guest_room_reservations/new/");
      await page.waitForLoadState("networkidle");
      const modal = page.locator(".ReactModal__Content--after-open").first();
      await expect(modal.locator("#guest-room-new-day")).toBeVisible({
        timeout: 5000,
      });

      await modal.locator("#guest-room-new-day").click();
      await modal.getByRole("button", { name: /January 20/ }).click();

      await page
        .locator(".ReactModal__Overlay")
        .first()
        .click({ position: { x: 8, y: 8 } });

      await expect(
        page
          .locator(".ReactModal__Overlay")
          .last()
          .locator("text=Discard your changes?"),
      ).toBeVisible({ timeout: 3000 });
    });
  });
});
