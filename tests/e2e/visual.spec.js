const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
const {
  setupAuthenticatedPage,
  stubPusher,
  disableIdleTimer,
  mockApi,
} = require("../helpers/setup");
const mealFixture = require("../fixtures/meal.json");

/**
 * Visual regression tests.
 *
 * These capture screenshots and compare against golden reference images.
 * On first run, golden images are created in tests/e2e/visual.spec.js-snapshots/.
 * On subsequent runs, new screenshots are diffed against the golden.
 *
 * After a dependency upgrade, if a visual test fails:
 *   - If the change is EXPECTED (library updated its styling): update the golden
 *     with `npx playwright test --update-snapshots`
 *   - If the change is UNEXPECTED: you caught a regression!
 *
 * Baselines exist per platform: -darwin for local runs, -linux for CI.
 * `npm run test:e2e:update` refreshes the darwin set; run
 * `bin/update-linux-snapshots` (Docker) to refresh the linux set in the
 * same sitting — never by letting CI fail and downloading its artifact.
 *
 * Time is frozen to 2026-01-15 12:00 for deterministic screenshots.
 */
test.describe("Visual Baselines", () => {
  test("login page", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);

    // Freeze time for determinism
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
  // the two daylight-saving transitions and a leap February. Pinned to
  // the community's timezone because a UTC viewer has no DST — without
  // it these goldens could not show a DST bug (the November escape).
  test.describe("calendar edge months", () => {
    test.use({ timezoneId: "America/Los_Angeles" });

    for (const [name, date] of [
      ["calendar-november-dst", "2026-11-15"],
      ["calendar-march-dst", "2026-03-15"],
      ["calendar-february-leap", "2028-02-15"],
    ]) {
      test(name, async ({ page, context }) => {
        await setupAuthenticatedPage(page, context);
        await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

        await page.goto(`/calendar/all/${date}/`);
        await page.waitForLoadState("networkidle");
        await expect(page.locator(".rbc-calendar")).toBeVisible({
          timeout: 10000,
        });
        await page.waitForTimeout(1000);

        await expect(page).toHaveScreenshot(`${name}.png`, {
          fullPage: true,
        });
      });
    }
  });

  test("meal edit page", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);

    // Freeze time for determinism
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    await page.goto("/calendar/all/2026-01-15/common_house_reservations/new/");
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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    // mockApi serves reservation 50 ("Book Club").
    await page.goto(
      "/calendar/all/2026-01-15/common_house_reservations/edit/50/",
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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    await page.goto("/calendar/all/2026-01-15/guest_room_reservations/new/");
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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    // mockApi serves reservation 60 with resident_id 1 (Jane).
    await page.goto(
      "/calendar/all/2026-01-15/guest_room_reservations/edit/60/",
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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    await page.goto("/calendar/all/2026-01-15/rotations/show/10/");
    await page.waitForLoadState("networkidle");

    const modal = page.locator(".ReactModal__Content--after-open");
    await expect(modal).toBeVisible({ timeout: 10000 });
    // The fixture rotation's description is its meals' date range.
    await expect(modal.locator("text=Jan 15–17, 2026")).toBeVisible({
      timeout: 5000,
    });
    await page.waitForTimeout(500);

    await expect(page).toHaveScreenshot("rotation-modal.png", {
      fullPage: true,
    });
  });

  test("meal history modal", async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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

  test("password reset page", async ({ page }) => {
    await stubPusher(page);
    await disableIdleTimer(page);
    await mockApi(page);
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    await page.goto("/meals/42/edit/");
    await page.waitForLoadState("networkidle");

    await expect(page.locator("h1", { hasText: "CLOSED" })).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator("text=Extras")).toBeVisible({ timeout: 5000 });
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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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
    await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // Reset with an empty email raises the error toast. Error toasts
    // stay for 15 seconds, so the screenshot cannot race the dismiss.
    await page.getByRole("button", { name: "Reset your password" }).click();
    const toast = page.locator(".toast--error");
    await expect(toast).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    await expect(toast).toHaveScreenshot("toast-error.png");
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
      await page.clock.setFixedTime(new Date("2026-01-15T12:00:00"));

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

    await page.clock.install({ time: new Date("2026-01-15T12:00:00") });
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
});
