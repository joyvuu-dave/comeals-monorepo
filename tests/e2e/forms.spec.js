const { test, expect } = require("../helpers/test");
const { setupAuthenticatedPage } = require("../helpers/setup");
const eventFixture = require("../fixtures/event.json");

// A create answered the way the server answers it: 200 and a message.
// The forms ignore the body on success, but it still matches the server's.
function fulfillCreated(route, message) {
  return route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify({ message }),
  });
}

test.describe("Form CRUD", () => {
  test.describe("Events", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("create a new event sends POST with form data", async ({ page }) => {
      let eventPayload = null;
      let eventMethod = null;
      await page.route(/\/api\/v1\/events(\?.*)?$/, (route) => {
        eventMethod = route.request().method();
        if (eventMethod === "POST") {
          eventPayload = route.request().postDataJSON();
        }
        fulfillCreated(route, "Event has been created");
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

      // Fill in every field the server needs: a title, a day, and the
      // start and end times.
      await modal.locator("#event-new-title").fill("Test Event");
      await modal.locator("#event-new-day").click();
      await modal.getByRole("button", { name: /January 20/ }).click();
      await modal
        .locator("#event-new-start-time")
        .selectOption({ label: "7:00 PM" });
      await modal
        .locator("#event-new-end-time")
        .selectOption({ label: "9:00 PM" });

      // Submit
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // API: POST with every field, each from its own input
      await expect.poll(() => eventPayload, { timeout: 5000 }).toBeTruthy();
      expect(eventMethod).toBe("POST");
      expect(eventPayload).toEqual({
        title: "Test Event",
        description: "",
        start_year: 2026,
        start_month: 1,
        start_day: 20,
        start_hours: "19",
        start_minutes: "00",
        end_hours: "21",
        end_minutes: "00",
        all_day: false,
      });

      // Saved: the form closes without asking.
      await expect(modal).toHaveCount(0);
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

    // The whole gate must work without a mouse: Escape asks, Enter is
    // a no that puts focus back in the field, Tab + Enter is a
    // deliberate yes.
    test("keyboard only: Escape asks, Enter keeps editing with focus restored, Tab+Enter discards", async ({
      page,
    }) => {
      await page.goto("/calendar/all/2026-01-15/events/new/");
      await page.waitForLoadState("networkidle");
      const modal = page.locator(".ReactModal__Content--after-open").first();
      await expect(modal.locator("#event-new-title")).toBeVisible();

      await modal.locator("#event-new-title").focus();
      await page.keyboard.type("Movie Night");

      await page.keyboard.press("Escape");
      await expect(page.locator("text=Discard your changes?")).toBeVisible();

      // Keep editing holds focus, so Enter is a no — and focus goes
      // back to the field the user was typing in.
      await page.keyboard.press("Enter");
      await expect(
        page.locator("text=Discard your changes?"),
      ).not.toBeVisible();
      await expect(modal.locator("#event-new-title")).toBeFocused();

      // Escape again, Tab to Discard (armed after 400ms), Enter closes.
      await page.keyboard.press("Escape");
      await expect(page.locator("text=Discard your changes?")).toBeVisible();
      await page.waitForTimeout(450);
      await page.keyboard.press("Tab");
      await page.keyboard.press("Enter");
      await page.waitForSelector(".ReactModal__Content--after-open", {
        state: "detached",
      });
    });

    test("edit an existing event loads its data into the form", async ({
      page,
    }) => {
      // The shared mock serves the generated event fixture; this route
      // only records the GET and hands it on.
      let eventGetUrl = null;
      await page.route("**/api/v1/events/**", (route) => {
        if (route.request().method() === "GET") {
          eventGetUrl = route.request().url();
        }
        route.fallback();
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
      await expect(modal.locator("h2:has-text('Edit Event')")).toBeVisible({
        timeout: 10000,
      });

      // The fields show the loaded event: 2026-01-28, 7:00 PM to
      // 9:00 PM in the community's zone.
      await expect(modal.locator("#event-edit-title")).toHaveValue(
        eventFixture.title,
      );
      await expect(modal.locator("#event-edit-description")).toHaveValue(
        eventFixture.description,
      );
      await expect(modal.locator("#event-edit-day")).toHaveValue("01/28/2026");
      await expect(modal.locator("#event-edit-start-time")).toHaveValue(
        "19:00",
      );
      await expect(modal.locator("#event-edit-end-time")).toHaveValue("21:00");
      await expect(modal.locator("#event-edit-all-day")).not.toBeChecked();

      // API: GET for event 70, the id the calendar tile links to
      expect(eventGetUrl).toMatch(
        new RegExp(`/api/v1/events/${eventFixture.id}$`),
      );
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
          fulfillCreated(route, "Event has been removed");
          return;
        }
        // The GET falls through to the shared mock and its fixture.
        route.fallback();
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
      await expect(modal.locator("#event-edit-title")).toHaveValue(
        eventFixture.title,
        { timeout: 10000 },
      );

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

      // API: DELETE to /events/70/delete, the only delete route the
      // server has for an event (config/routes.rb)
      await expect.poll(() => deleteMethod, { timeout: 5000 }).toBe("DELETE");
      expect(deleteUrl).toMatch(
        new RegExp(`/api/v1/events/${eventFixture.id}/delete$`),
      );

      // Deleted: every modal closes.
      await expect(
        page.locator(".ReactModal__Content--after-open"),
      ).toHaveCount(0);
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
      await page.route(
        /\/api\/v1\/common-house-reservations(\?.*)?$/,
        (route) => {
          postMethod = route.request().method();
          if (postMethod === "POST") {
            postPayload = route.request().postDataJSON();
          }
          fulfillCreated(route, "Common House Reservation has been created");
        },
      );

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Click "Common House" button in sidebar
      await page.locator("text=Common House").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Pick Bob (id 2 in hosts.json), not the first host, so a select
      // that sent the first option no matter what would fail.
      const residentSelect = modal.locator("#ch-new-resident");
      await expect(residentSelect).toBeVisible({ timeout: 3000 });
      await residentSelect.selectOption({ label: "B - Bob Johnson" });
      await modal.locator("#ch-new-title").fill("Book Club");
      await modal.locator("#ch-new-day").click();
      await modal.getByRole("button", { name: /January 20/ }).click();
      await modal
        .locator("#ch-new-start-time")
        .selectOption({ label: "7:00 PM" });
      await modal
        .locator("#ch-new-end-time")
        .selectOption({ label: "9:00 PM" });

      // Submit
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // API: POST with every field, each from its own input
      await expect.poll(() => postPayload, { timeout: 5000 }).toBeTruthy();
      expect(postMethod).toBe("POST");
      expect(postPayload).toEqual({
        resident_id: "2",
        title: "Book Club",
        start_year: 2026,
        start_month: 1,
        start_day: 20,
        start_hours: "19",
        start_minutes: "00",
        end_hours: "21",
        end_minutes: "00",
      });

      // Saved: the form closes without asking.
      await expect(modal).toHaveCount(0);
    });
  });

  test.describe("Guest Room Reservations", () => {
    test.beforeEach(async ({ page, context }) => {
      await setupAuthenticatedPage(page, context);
    });

    test("create a new guest room reservation sends POST", async ({ page }) => {
      let postPayload = null;
      let postMethod = null;
      await page.route(
        /\/api\/v1\/guest-room-reservations(\?.*)?$/,
        (route) => {
          postMethod = route.request().method();
          if (postMethod === "POST") {
            postPayload = route.request().postDataJSON();
          }
          fulfillCreated(route, "Guest Room Reservation has been created");
        },
      );

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Click "Guest Room" button in sidebar
      await page
        .getByRole("button", { name: "Guest Room", exact: true })
        .click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Pick Bob (id 2 in hosts.json), not the first host, and a day.
      const hostSelect = modal.locator("#guest-room-new-host");
      await expect(hostSelect).toBeVisible({ timeout: 3000 });
      await hostSelect.selectOption({ label: "B - Bob Johnson" });
      await modal.locator("#guest-room-new-day").click();
      await modal.getByRole("button", { name: /January 20/ }).click();

      // Submit
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // API: POST with the picked host and day
      await expect.poll(() => postPayload, { timeout: 5000 }).toBeTruthy();
      expect(postMethod).toBe("POST");
      expect(postPayload).toEqual({ resident_id: "2", date: "2026-01-20" });

      // Saved: the form closes without asking.
      await expect(modal).toHaveCount(0);
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
      await page.goto("/calendar/all/2026-01-15/guest-room-reservations/new/");
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
