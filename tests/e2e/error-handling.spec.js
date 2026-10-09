const {
  test,
  expect,
  httpFailurePattern,
  combinePatterns,
} = require("../helpers/test");
// rails500 answers with Rails' own 500 page, what production sends for
// an exception ApiController does not rescue. NOT_FOUND_MESSAGE is
// ApiController's answer for a record that is not there.
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

// Every test here makes the app hit a mocked failure, so the
// browser's request-failed log lines are the point. A silent caller
// (the meal load) logs the server's message verbatim, and
// handle_axios_error logs any error answer that has no message.
test.use({
  allowedConsoleErrors: combinePatterns(
    httpFailurePattern,
    NOT_FOUND_LOG,
    /^Bad response from server/,
    /^Could not use the meal from the server:/,
    /^Error: no response received from server\.$/,
  ),
});

// The words handle_axios_error shows for an error answer with no message.
const SERVER_PROBLEM = "The server had a problem. Please try again.";

// What EventsController#create sends for an event with no title.
const EVENT_REFUSED = "Title can't be blank";

// The 409 every meal write answers when it loses a race for the meal's
// lock (MealsController#conflict_rejection).
const MEAL_CONFLICT =
  "Someone else was changing this meal at the same time. Nothing was saved. Try again.";

test.describe("Error Handling & Edge Cases", () => {
  test.describe("API Error Responses", () => {
    // The server's refusal carries its own sentence, and the toast shows
    // it word for word.
    test("an attendance refusal reverts the cell and shows the server's message", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      await page.route("**/api/v1/meals/*/residents/2*", (route) => {
        route.fulfill({
          status: 409,
          contentType: "application/json",
          body: JSON.stringify({ message: MEAL_CONFLICT }),
        });
      });

      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const bobCell = page.getByRole("cell", {
        name: "B - Bob Johnson",
        exact: true,
      });
      await expect(bobCell).toBeVisible({ timeout: 10000 });

      // Before: Bob not attending
      await expect(bobCell).not.toHaveClass(/background-green/);

      // Click to toggle attending (will optimistically turn green, then revert)
      await bobCell.click();

      const toast = page.locator(".toast--error");
      await expect(toast).toBeVisible({ timeout: 5000 });
      await expect(toast.locator(".toast__message")).toHaveText(MEAL_CONFLICT);

      // Background should revert to NOT green (state rolled back)
      await expect(bobCell).not.toHaveClass(/background-green/, {
        timeout: 3000,
      });
    });

    // An exception the API does not rescue answers with Rails' 500 page,
    // which has no message. The tap must still say it failed (#108).
    test("an attendance write that hits Rails' 500 page reverts the cell and says the server had a problem", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);
      await page.route("**/api/v1/meals/*/residents/2*", rails500);

      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const bobCell = page.getByRole("cell", {
        name: "B - Bob Johnson",
        exact: true,
      });
      await expect(bobCell).toBeVisible({ timeout: 10000 });
      await expect(bobCell).not.toHaveClass(/background-green/);

      await bobCell.click();

      const toast = page.locator(".toast--error");
      await expect(toast).toBeVisible({ timeout: 5000 });
      await expect(toast.locator(".toast__message")).toHaveText(SERVER_PROBLEM);
      await expect(bobCell).not.toHaveClass(/background-green/, {
        timeout: 3000,
      });
    });

    // A failed FIRST load of a meal used to stay silent forever: the
    // page said "loading..." with nothing to tap and no retry. Now it
    // shows a notice, retries on its own with a growing wait, and
    // offers a retry button.

    test("a failed meal load shows a retry notice and heals on its own", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      let failuresLeft = 1;
      await page.route("**/api/v1/meals/42/cooks*", (route) => {
        if (route.request().method() !== "GET") return route.fallback();
        if (failuresLeft > 0) {
          failuresLeft -= 1;
          return rails500(route);
        }
        return route.fallback();
      });

      await page.goto("/meals/42/edit/");
      await expect(page.getByText("Trouble loading this meal.")).toBeVisible({
        timeout: 5000,
      });

      // The notice floats over the page, ConfirmBar-style: its box
      // overlaps the content below it. An in-flow banner would push
      // the content down instead and fail this.
      const barBox = await page
        .getByText("Trouble loading this meal.")
        .boundingBox();
      const wrapperBox = await page.locator(".wrapper").boundingBox();
      expect(barBox.y + barBox.height).toBeGreaterThan(wrapperBox.y);

      // The first automatic retry (2s) reaches a healthy server.
      await expect(
        page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
      ).toBeVisible({ timeout: 10000 });
      await expect(page.getByText("Trouble loading this meal.")).toHaveCount(0);
    });

    test("the retry button reloads the meal right away", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      let healthy = false;
      let cooksRequests = 0;
      await page.route("**/api/v1/meals/42/cooks*", (route) => {
        if (route.request().method() !== "GET") return route.fallback();
        cooksRequests += 1;
        if (!healthy) {
          return rails500(route);
        }
        return route.fallback();
      });

      await page.goto("/meals/42/edit/");
      await expect(page.getByText("Trouble loading this meal.")).toBeVisible({
        timeout: 5000,
      });

      // Wait out the first automatic retry (2s), which also fails. The
      // next automatic one comes 4s after that — a quiet window in
      // which only the button can heal the page.
      await expect
        .poll(() => cooksRequests, { timeout: 5000 })
        .toBeGreaterThanOrEqual(2);
      healthy = true;
      await page.getByRole("button", { name: "Retry now" }).click();
      await expect(
        page.getByRole("cell", { name: "A - Jane Smith", exact: true }),
      ).toBeVisible({ timeout: 2500 });
      await expect(page.getByText("Trouble loading this meal.")).toHaveCount(0);
    });

    // An answer the page cannot use is a bug, not a network state: the
    // page must not say "loading..." forever, and must not retry it
    // (#110).
    test("a meal answer the page cannot use shows a notice and a way back, and nothing retries", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      let cooksRequests = 0;
      await page.route("**/api/v1/meals/42/cooks*", (route) => {
        if (route.request().method() !== "GET") return route.fallback();
        cooksRequests += 1;
        // A 200 with no id in it.
        return route.fulfill({
          status: 200,
          contentType: "application/json",
          body: "{}",
        });
      });

      await page.goto("/meals/42/edit/");
      const notice = page.getByRole("alert");
      await expect(notice).toHaveText(
        /Something went wrong showing this meal\./,
        { timeout: 5000 },
      );
      await expect(page.getByText("Trouble loading this meal.")).toHaveCount(0);

      // The first automatic retry would come at 2s. None comes.
      await page.waitForTimeout(2500);
      expect(cooksRequests).toBe(1);

      await page.getByRole("button", { name: "Back to calendar" }).click();
      await expect(page).toHaveURL(/\/calendar\//, { timeout: 5000 });
    });

    test("a meal that does not exist shows a message and a way back", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      await page.route("**/api/v1/meals/999/cooks*", (route) =>
        route.fulfill({
          status: 404,
          contentType: "application/json",
          body: JSON.stringify({ message: NOT_FOUND_MESSAGE }),
        }),
      );

      await page.goto("/meals/999/edit/");
      await expect(page.getByText("This meal could not be found.")).toBeVisible(
        { timeout: 5000 },
      );

      // No retry notice: retrying cannot fix a 404.
      await expect(page.getByText("Trouble loading this meal.")).toHaveCount(0);

      await page.getByRole("button", { name: "Back to calendar" }).click();
      await expect(page).toHaveURL(/\/calendar\//, { timeout: 5000 });
    });

    // A refused close shows the server's sentence; a close that hits
    // Rails' 500 page, which has no message, still says it failed (#108).
    // Either way the refetch after the answer puts OPEN back.
    for (const [label, answer, words] of [
      [
        "a refusal shows the server's message",
        (route) =>
          route.fulfill({
            status: 409,
            contentType: "application/json",
            body: JSON.stringify({ message: MEAL_CONFLICT }),
          }),
        MEAL_CONFLICT,
      ],
      [
        "Rails' 500 page says the server had a problem",
        rails500,
        SERVER_PROBLEM,
      ],
    ]) {
      test(`closing the meal: ${label}, and the status goes back to OPEN`, async ({
        page,
        context,
      }) => {
        await setupAuthenticatedPage(page, context);
        await page.route("**/api/v1/meals/*/closed*", answer);

        await page.goto("/meals/42/edit/");
        await page.waitForLoadState("networkidle");

        // Before: OPEN
        await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
          timeout: 10000,
        });

        // Try to close
        await page.locator("text=Open / Close Meal").click();

        const toast = page.locator(".toast--error");
        await expect(toast).toBeVisible({ timeout: 5000 });
        await expect(toast.locator(".toast__message")).toHaveText(words);

        // Status should revert to OPEN
        await expect(page.locator("h1", { hasText: "OPEN" })).toBeVisible({
          timeout: 5000,
        });
      });
    }

    // EventsController#create answers a record it cannot save with 400
    // and the model's own sentences.
    test("an event the server refuses shows the server's message", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      await page.route("**/api/v1/events", (route) => {
        route.fulfill({
          status: 400,
          contentType: "application/json",
          body: JSON.stringify({ message: EVENT_REFUSED }),
        });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Open event creation modal
      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });

      // Submit without filling in title
      const submitButton = modal.locator("button:has-text('Create')");
      await expect(submitButton).toBeVisible();
      await submitButton.click();

      // The form's own error shows inside the form, under its title, and
      // not in the stack of messages (#137).
      const error = modal.locator(".form-message--error");
      await expect(error).toBeVisible({ timeout: 5000 });
      await expect(error.locator(".form-message__text")).toHaveText(
        EVENT_REFUSED,
      );
      await expect(page.locator(".toast")).toHaveCount(0);
    });

    test("a form's own error goes with the form when it closes", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      await page.route("**/api/v1/events", (route) => {
        route.fulfill({
          status: 400,
          contentType: "application/json",
          body: JSON.stringify({ message: EVENT_REFUSED }),
        });
      });

      await page.goto("/calendar/all/2026-01-15/");
      await page.waitForLoadState("networkidle");
      await expect(page.locator(".rbc-calendar")).toBeVisible({
        timeout: 10000,
      });

      // Open event creation modal and submit to trigger error
      await page.locator("text=Event").first().click();
      const modal = page.locator(".ReactModal__Content--after-open");
      await expect(modal).toBeVisible({ timeout: 5000 });
      await modal.locator("button:has-text('Create')").click();

      await expect(modal.locator(".form-message--error")).toBeVisible({
        timeout: 5000,
      });

      // Close the modal via X button
      await modal.locator(".close-button").click();

      await expect(modal).not.toBeVisible();
      await expect(page.locator(".form-message")).toHaveCount(0);
      await expect(page.locator(".toast")).toHaveCount(0);
    });

    // #148. react-modal listens for Escape only on the dialog, so it
    // gets the key only while focus is inside the dialog. Chrome takes
    // focus off a button when the button is disabled (a form disables
    // its buttons while its request is out). Both browsers take focus
    // off an element that is removed (a dismissed message, the day
    // picker after a pick). Focus then went to the page's <body>, and
    // Escape did nothing. WebKit does not focus a button on a click, so
    // there only the removals broke Escape.
    test.describe("Escape closes a calendar form", () => {
      function refuse(words) {
        return (route) =>
          route.fulfill({
            status: 400,
            contentType: "application/json",
            body: JSON.stringify({ message: words }),
          });
      }

      const RESERVATION_REFUSED = "Resident can't be blank";

      for (const [label, path, api, submit, words] of [
        [
          "New Event",
          "/calendar/all/2026-01-15/events/new/",
          "**/api/v1/events",
          "Create",
          EVENT_REFUSED,
        ],
        [
          "New Common House reservation",
          "/calendar/all/2026-01-15/common-house-reservations/new/",
          "**/api/v1/common-house-reservations",
          "Create",
          RESERVATION_REFUSED,
        ],
        [
          "New Guest Room reservation",
          "/calendar/all/2026-01-15/guest-room-reservations/new/",
          "**/api/v1/guest-room-reservations",
          "Create",
          RESERVATION_REFUSED,
        ],
        [
          "Edit Event",
          "/calendar/all/2026-01-15/events/edit/70",
          "**/api/v1/events/70/update",
          "Update",
          EVENT_REFUSED,
        ],
        [
          "Edit Common House reservation",
          "/calendar/all/2026-01-15/common-house-reservations/edit/50",
          "**/api/v1/common-house-reservations/50/update",
          "Update",
          RESERVATION_REFUSED,
        ],
        [
          "Edit Guest Room reservation",
          "/calendar/all/2026-01-15/guest-room-reservations/edit/60",
          "**/api/v1/guest-room-reservations/60/update",
          "Update",
          RESERVATION_REFUSED,
        ],
      ]) {
        test(`${label}: after its ${submit} is refused`, async ({
          page,
          context,
        }) => {
          await setupAuthenticatedPage(page, context);
          await page.route(api, refuse(words));
          await page.goto(path);
          const modal = page.locator(".ReactModal__Content--after-open");
          const button = modal.getByRole("button", { name: submit });
          // An edit form turns its buttons on once the record is loaded.
          await expect(button).toBeEnabled({ timeout: 10000 });

          await button.click();
          await expect(modal.locator(".form-message__text")).toHaveText(words);

          await page.keyboard.press("Escape");
          await expect(modal).toHaveCount(0);
        });
      }

      test("Edit Event: after its Delete is refused", async ({
        page,
        context,
      }) => {
        await setupAuthenticatedPage(page, context);
        const DELETE_REFUSED = "Event could not be removed.";
        await page.route("**/api/v1/events/70/delete", refuse(DELETE_REFUSED));
        await page.goto("/calendar/all/2026-01-15/events/edit/70");
        const modal = page
          .locator(".ReactModal__Content--after-open")
          .filter({ hasText: "Edit Event" });
        const remove = modal.getByRole("button", { name: "Delete" });
        await expect(remove).toBeEnabled({ timeout: 10000 });

        await remove.click();
        const confirm = page
          .locator(".ReactModal__Content--after-open")
          .filter({ hasText: "Do you really want to delete this event?" });
        // The confirm button is armed only after 400ms (ConfirmModal).
        await page.waitForTimeout(450);
        await confirm.getByRole("button", { name: "Delete" }).click();
        await expect(modal.locator(".form-message__text")).toHaveText(
          DELETE_REFUSED,
        );

        await page.keyboard.press("Escape");
        await expect(modal).toHaveCount(0);
      });

      // The confirm dialog gives focus back to Delete when it closes,
      // but Delete is disabled by then, so focus goes to the form.
      test("Edit Event: while its Delete is out", async ({ page, context }) => {
        await setupAuthenticatedPage(page, context);
        let deleteSent = false;
        await page.route("**/api/v1/events/70/delete", () => {
          // No answer: the request stays out.
          deleteSent = true;
        });
        await page.goto("/calendar/all/2026-01-15/events/edit/70");
        const modal = page
          .locator(".ReactModal__Content--after-open")
          .filter({ hasText: "Edit Event" });
        const remove = modal.getByRole("button", { name: "Delete" });
        await expect(remove).toBeEnabled({ timeout: 10000 });

        await remove.click();
        const confirm = page
          .locator(".ReactModal__Content--after-open")
          .filter({ hasText: "Do you really want to delete this event?" });
        await page.waitForTimeout(450);
        await confirm.getByRole("button", { name: "Delete" }).click();
        await expect.poll(() => deleteSent).toBe(true);
        await expect(remove).toBeDisabled();

        await page.keyboard.press("Escape");
        await expect(modal).toHaveCount(0);
      });

      test("New Event: after its message is dismissed", async ({
        page,
        context,
      }) => {
        await setupAuthenticatedPage(page, context);
        await page.route("**/api/v1/events", refuse(EVENT_REFUSED));
        await page.goto("/calendar/all/2026-01-15/events/new/");
        const modal = page.locator(".ReactModal__Content--after-open");
        await modal.getByRole("button", { name: "Create" }).click();
        await modal.getByRole("button", { name: "Dismiss" }).click();
        await expect(modal.locator(".form-message")).toHaveCount(0);

        await page.keyboard.press("Escape");
        await expect(modal).toHaveCount(0);
      });

      // A picked day makes the form dirty, so Escape asks first.
      test("New Event: after a day is picked", async ({ page, context }) => {
        await setupAuthenticatedPage(page, context);
        await page.goto("/calendar/all/2026-01-15/events/new/");
        const modal = page.locator(".ReactModal__Content--after-open");
        await modal.locator("#event-new-day").click();
        await modal.getByRole("button", { name: /January 20/ }).click();
        await expect(modal.locator("#event-new-day")).toHaveValue("01/20/2026");

        await page.keyboard.press("Escape");
        await expect(page.getByText("Discard your changes?")).toBeVisible();
      });
    });

    // #137. The person leaves a meal while its costs are still being
    // saved, and the save fails. On the calendar, the message that names
    // the meal is the only sign the costs were lost. A calendar form's
    // own error shows inside the form, the stack is drawn under the
    // open form, and closing the form leaves the message about the meal.
    test.describe("the message about a meal not saved", () => {
      // A refusal that is final, so the save is not sent again. The
      // store logs the server's words for a meal the person left.
      const REFUSED = "Invalid cook assignment.";
      test.use({
        allowedConsoleErrors: combinePatterns(
          httpFailurePattern,
          /^Invalid cook assignment\.$/,
        ),
      });

      // True when a tap in the middle of the stack's top message lands on
      // that message, and not on something drawn over it. A new message
      // slides in from the right edge, so this waits until it is in
      // place.
      async function stackOnTop(page) {
        return page.evaluate(async () => {
          const toast = window.document.querySelector(".toast");
          await Promise.all(toast.getAnimations().map((a) => a.finished));
          const box = toast.getBoundingClientRect();
          const hit = window.document.elementFromPoint(
            box.left + box.width / 2,
            box.top + box.height / 2,
          );
          return toast.contains(hit);
        });
      }

      test("stays under a form's own error, under the open form, and after the form closes", async ({
        page,
        context,
      }) => {
        const NOT_SAVED =
          "The cooks and costs you entered for Thu, Jan 15th were not saved. Please open that meal and enter them again.";
        await setupAuthenticatedPage(page, context);

        // The bills save waits until the person is on the calendar, then
        // the server refuses it.
        let answerTheSave;
        const onTheCalendar = new Promise((resolve) => {
          answerTheSave = resolve;
        });
        await page.route("**/api/v1/meals/42/bills*", async (route) => {
          await onTheCalendar;
          await route.fulfill({
            status: 400,
            contentType: "application/json",
            body: JSON.stringify({ message: REFUSED }),
          });
        });
        await page.route("**/api/v1/events", (route) => {
          route.fulfill({
            status: 400,
            contentType: "application/json",
            body: JSON.stringify({ message: EVENT_REFUSED }),
          });
        });

        await page.goto("/meals/42/edit/");
        const cost = page
          .getByRole("spinbutton", { name: "Set meal cost" })
          .first();
        await expect(cost).toHaveValue("25.50", { timeout: 10000 });
        const sent = page.waitForRequest(
          (r) =>
            r.method() === "PATCH" &&
            r.url().includes("/api/v1/meals/42/bills"),
        );
        await cost.fill("30.00");
        await sent;

        await page.getByRole("button", { name: "Calendar" }).click();
        await expect(page.locator(".rbc-calendar")).toBeVisible({
          timeout: 10000,
        });
        answerTheSave();
        const messages = page.locator(".toast__message");
        await expect(messages).toHaveText([NOT_SAVED]);
        expect(await stackOnTop(page)).toBe(true);

        // The form's error shows inside the form. The stack keeps the
        // message about the meal, under the open form.
        await page.locator("text=Event").first().click();
        const modal = page.locator(".ReactModal__Content--after-open");
        await expect(modal).toBeVisible({ timeout: 5000 });
        await modal.locator("button:has-text('Create')").click();
        await expect(modal.locator(".form-message__text")).toHaveText(
          EVENT_REFUSED,
        );
        await expect(messages).toHaveText([NOT_SAVED]);
        expect(await stackOnTop(page)).toBe(false);
        // While the form is open, react-modal hides #root from screen
        // readers with aria-hidden. The form's error is inside the
        // dialog, and the stack is drawn outside #root, so aria-hidden
        // hides neither.
        await expect(page.locator("#root")).toHaveAttribute(
          "aria-hidden",
          "true",
        );
        await expect(modal.getByRole("alert")).toContainText(EVENT_REFUSED);
        await expect(page.getByRole("alert")).toHaveCount(2);

        // The stack is under the form, so the form's X can be tapped.
        await modal.locator(".close-button").click();
        await expect(modal).not.toBeVisible();
        await expect(page.locator(".form-message")).toHaveCount(0);
        await expect(messages).toHaveText([NOT_SAVED]);
        expect(await stackOnTop(page)).toBe(true);
      });
    });

    // The stack sits at the bottom of the screen at every width, because
    // the top of the screen holds the navigation (toast.css). On a screen
    // narrower than 416px it is as wide as the screen less its margins.
    // On a wider screen it sits at the right, 24rem wide.
    test.describe("where the stack sits", () => {
      test.use({
        allowedConsoleErrors: combinePatterns(
          httpFailurePattern,
          /^Bad response from server/,
          /^Error: no response received from server\.$/,
        ),
      });

      // What the server sends for each write these tests make fail.
      // MealsController#reconciled_rejection and
      // MealsController#verify_resident_exists.
      const SETTLED = "Change not permitted. Meal has already been reconciled.";
      const NOT_FOUND = "Resident not found.";

      const messages = (page) => page.locator(".toast__message");

      function refuse(status, message) {
        return (route) =>
          route.fulfill({
            status,
            contentType: "application/json",
            body: JSON.stringify({ message }),
          });
      }

      // A new message slides in from the right edge. This waits until
      // every message is in its place.
      async function settled(page) {
        await page.evaluate(async () => {
          const toasts = Array.from(window.document.querySelectorAll(".toast"));
          await Promise.all(
            toasts
              .flatMap((toast) => toast.getAnimations())
              .map((a) => a.finished),
          );
        });
      }

      // True when a tap in the middle of this element lands on it, and
      // not on something drawn over it.
      async function tappable(locator) {
        return locator.evaluate((element) => {
          const box = element.getBoundingClientRect();
          const hit = window.document.elementFromPoint(
            box.left + box.width / 2,
            box.top + box.height / 2,
          );
          return element.contains(hit);
        });
      }

      // Five writes on the meal page fail, each with its own words, so
      // three messages show, with a line for two more. The taps happen
      // on the screen given here, where the stack does not get in their
      // way. Each test then gives the screen the size it checks.
      async function fiveErrors(page, screen) {
        await page.setViewportSize(screen);
        await page.route(
          "**/api/v1/meals/*/residents/2",
          refuse(409, MEAL_CONFLICT),
        );
        await page.route("**/api/v1/meals/*/residents/1", refuse(400, SETTLED));
        await page.route(
          "**/api/v1/meals/*/residents/3",
          refuse(400, NOT_FOUND),
        );
        await page.route("**/api/v1/meals/*/description*", rails500);
        await page.route("**/api/v1/meals/*/residents/1/guests", (route) =>
          route.abort("connectionfailed"),
        );
        await page.goto("/meals/42/edit/");
        await page.waitForLoadState("networkidle");
        for (const [name, words] of [
          ["B - Bob Johnson", MEAL_CONFLICT],
          ["A - Jane Smith", SETTLED],
          ["C - Alice Williams", NOT_FOUND],
        ]) {
          await page.getByRole("cell", { name, exact: true }).click();
          await expect(messages(page).first()).toHaveText(words);
        }
        await page
          .getByLabel("Enter meal description")
          .fill("Pasta night with garlic bread and salad");
        await expect(messages(page).first()).toHaveText(SERVER_PROBLEM, {
          timeout: 10000,
        });
        const janeRow = page
          .getByRole("cell", { name: "A - Jane Smith", exact: true })
          .locator("xpath=ancestor::tr");
        await janeRow.locator(".dropdown-add").click();
        await janeRow.locator(".dropdown-menu img[alt='cow-icon']").click();
        await expect(messages(page).first()).toHaveText(
          "Error: no response received from server.",
        );
      }

      async function showAllFive(page) {
        await page
          .getByRole("button", { name: "Show 2 more messages" })
          .click();
        await expect(messages(page)).toHaveCount(5);
      }

      for (const [label, viewport, width] of [
        [
          "at the bottom on a narrow phone, as wide as the screen less its margins",
          { width: 375, height: 667 },
          null,
        ],
        [
          "at the bottom right on a wide screen, 24rem wide",
          { width: 1280, height: 720 },
          24 * 16,
        ],
      ]) {
        test(label, async ({ page, context }) => {
          await page.setViewportSize(viewport);
          await setupAuthenticatedPage(page, context);
          await page.route(
            "**/api/v1/meals/*/residents/2*",
            refuse(409, MEAL_CONFLICT),
          );
          await page.goto("/meals/42/edit/");
          await page.waitForLoadState("networkidle");
          await page
            .getByRole("cell", { name: "B - Bob Johnson", exact: true })
            .click();

          // The message a person sees. The stack's own box is a little
          // bigger: it has room around the messages for their shadows
          // (toast.css).
          const message = page.locator(".toast");
          await expect(message).toBeVisible({ timeout: 5000 });
          await settled(page);
          const box = await message.boundingBox();
          // The part of the window the page draws in, without a scroll
          // bar.
          const screen = await page.evaluate(() => ({
            width: window.document.documentElement.clientWidth,
            height: window.document.documentElement.clientHeight,
          }));
          const gap = 16; // var(--space-4)
          expect(box.y + box.height).toBeCloseTo(screen.height - gap, 0);
          expect(box.x + box.width).toBeCloseTo(screen.width - gap, 0);
          expect(box.width).toBeCloseTo(width ?? screen.width - 2 * gap, 0);
        });
      }

      // The stack is a box that scrolls, and on a wide screen it sits
      // over the bottom right of the page. The mouse wheel over it must
      // still scroll the page, even when the stack has nothing of its
      // own to scroll. Chrome did not, while the stack had
      // overscroll-behavior: contain.
      test("on a wide screen, the mouse wheel over the stack scrolls the page", async ({
        page,
        context,
      }) => {
        await page.setViewportSize({ width: 1280, height: 720 });
        await setupAuthenticatedPage(page, context);
        await page.route(
          "**/api/v1/meals/*/residents/2*",
          refuse(409, MEAL_CONFLICT),
        );
        await page.goto("/meals/42/edit/");
        await page.waitForLoadState("networkidle");
        await page
          .getByRole("cell", { name: "B - Bob Johnson", exact: true })
          .click();
        const message = page.locator(".toast");
        await expect(message).toBeVisible({ timeout: 5000 });
        await settled(page);
        await page.evaluate(() => window.scrollTo(0, 0));

        const box = await message.boundingBox();
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.wheel(0, 200);
        await expect
          .poll(() => page.evaluate(() => window.scrollY))
          .toBeGreaterThan(0);
      });

      // On a wide screen the stack covers none of the controls at the
      // top of a page, even with all five messages showing: on the meal
      // page "Open / Close Meal", "history" and "logout", and on the
      // calendar "today", the month arrows and "logout".
      test("on a wide screen, the stack covers none of the controls at the top of a page", async ({
        page,
        context,
      }) => {
        await setupAuthenticatedPage(page, context);
        await fiveErrors(page, { width: 1280, height: 1400 });
        await page.setViewportSize({ width: 1280, height: 720 });
        await showAllFive(page);

        async function expectClear(controls) {
          await page.evaluate(() => window.scrollTo(0, 0));
          await settled(page);
          const stack = await page.locator(".toast-container").boundingBox();
          for (const control of controls) {
            const box = await control.boundingBox();
            expect(stack.y).toBeGreaterThanOrEqual(box.y + box.height);
            expect(await tappable(control)).toBe(true);
          }
        }

        await expectClear([
          page.getByRole("button", { name: "Open / Close Meal" }),
          page.getByRole("button", { name: "history" }),
          page.getByRole("button", { name: /^logout/ }),
        ]);

        await page.getByRole("button", { name: "Calendar" }).click();
        await expect(page.locator(".rbc-calendar")).toBeVisible({
          timeout: 10000,
        });
        await expect(messages(page)).toHaveCount(5);
        await expectClear([
          page.getByRole("button", { name: "today" }),
          page.getByRole("button", { name: "Goto Last Month" }),
          page.getByRole("button", { name: "Goto Next Month" }),
          page.getByRole("button", { name: /^logout/ }),
        ]);
      });

      // An error stays until a person closes it, so the stack can sit
      // over the end of a page for a long time. While messages show, the
      // page has room at its bottom as tall as the stack, so the last
      // sign-up row and the last week of the calendar can be scrolled
      // above the stack and tapped.
      for (const [label, viewport, tapScreen] of [
        [
          "on a phone",
          { width: 375, height: 667 },
          { width: 375, height: 667 },
        ],
        [
          "on a wide screen",
          { width: 1280, height: 720 },
          { width: 1280, height: 1400 },
        ],
      ]) {
        test(`${label}, the end of each page can be scrolled above the stack`, async ({
          page,
          context,
        }) => {
          await setupAuthenticatedPage(page, context);
          await fiveErrors(page, tapScreen);
          await page.setViewportSize(viewport);
          await showAllFive(page);

          // Scrolled to its end, the page's last part is above the stack.
          // A tap near the bottom right corner of the part that shows
          // lands on it: before the scroll, the stack was over that spot.
          // The room follows the stack's height at the browser's next
          // frame after the stack changes (toast_container.jsx), so the
          // check tries again until the room has caught up.
          async function expectAboveStack(part) {
            await settled(page);
            await expect(async () => {
              await page.evaluate(() =>
                window.scrollTo(
                  0,
                  window.document.documentElement.scrollHeight,
                ),
              );
              const stack = await page
                .locator(".toast-container")
                .boundingBox();
              const box = await part.boundingBox();
              expect(box.y + box.height).toBeLessThanOrEqual(stack.y);
            }).toPass({ timeout: 5000 });
            const tapped = await part.evaluate((element) => {
              const box = element.getBoundingClientRect();
              const right = Math.min(
                box.right,
                window.document.documentElement.clientWidth,
              );
              const hit = window.document.elementFromPoint(
                right - 10,
                box.bottom - 10,
              );
              return element.contains(hit);
            });
            expect(tapped).toBe(true);
          }

          // Alice is last on the sign-up list.
          await expectAboveStack(
            page
              .getByRole("cell", { name: "C - Alice Williams", exact: true })
              .locator("xpath=ancestor::tr"),
          );

          await page.getByRole("button", { name: "Calendar" }).click();
          await expect(page.locator(".rbc-calendar")).toBeVisible({
            timeout: 10000,
          });
          await expect(messages(page)).toHaveCount(5);
          await expectAboveStack(page.locator(".rbc-month-row").last());
        });
      }

      // A banner sits at the top of the screen and the stack at the
      // bottom, so neither covers the other: a person can tap the
      // banner's button and close the message. The new-version banner
      // stays until someone taps Refresh, and an error stays until a
      // person closes it.
      async function expectBothTappable(page, banner, words) {
        await expect(banner).toBeVisible({ timeout: 10000 });
        await expect(messages(page)).toHaveText([words]);
        await settled(page);
        expect(await tappable(banner.getByRole("button"))).toBe(true);
        expect(await tappable(page.locator(".toast__dismiss"))).toBe(true);

        await page.locator(".toast__dismiss").click();
        await expect(messages(page)).toHaveCount(0);
      }

      test("on a wide screen, the new-version banner's button and the stack's X can both be tapped", async ({
        page,
        context,
      }) => {
        await page.setViewportSize({ width: 1280, height: 720 });
        await setupAuthenticatedPage(page, context);
        // A manifest that names another build, so the banner shows at
        // its first look, five minutes after the page loads.
        await page.route("**/.vite/manifest.json", (route) =>
          route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify({
              "index.html": {
                isEntry: true,
                file: "vite-assets/index-NEWBUILD.js",
              },
            }),
          }),
        );
        await page.route(
          "**/api/v1/meals/*/residents/2*",
          refuse(409, MEAL_CONFLICT),
        );
        await page.clock.install({ time: FROZEN_NOW });
        await page.goto("/meals/42/edit/");
        const bob = page.getByRole("cell", {
          name: "B - Bob Johnson",
          exact: true,
        });
        await expect(bob).toBeVisible({ timeout: 10000 });
        await page.clock.fastForward(5 * 60 * 1000 + 1000);
        await expect(page.locator(".app-banner--info")).toBeVisible({
          timeout: 10000,
        });

        await bob.click();

        await expectBothTappable(
          page,
          page.locator(".app-banner--info"),
          MEAL_CONFLICT,
        );
      });

      test("on a wide screen, the signed-out banner's button and the stack's X can both be tapped", async ({
        page,
        context,
      }) => {
        // ApiController#authenticate's answer once the session is gone.
        const SIGNED_OUT = "You are not authenticated.";
        await page.setViewportSize({ width: 1280, height: 720 });
        await setupAuthenticatedPage(page, context);
        await page.route(
          "**/api/v1/meals/*/residents/2*",
          refuse(401, SIGNED_OUT),
        );
        await page.goto("/meals/42/edit/");
        await page.waitForLoadState("networkidle");

        await page
          .getByRole("cell", { name: "B - Bob Johnson", exact: true })
          .click();

        await expectBothTappable(
          page,
          page.locator(".app-banner--error"),
          SIGNED_OUT,
        );
      });

      // A yes/no question on the page is drawn over the stack, so a
      // message that comes while the question is open cannot cover its
      // Yes or its No. Here three writes fail while the question is
      // open, and their messages reach up over it. On a phone the close
      // question ("Close the meal anyway?") is low enough on the screen
      // for that. On a wide screen the stack stops below the close
      // question, but the questions in the cooks box are lower, and the
      // stack reaches them. This test uses the one that asks to erase
      // Jane's $25.50, which the page asks when a person turns on "no
      // cost" for her.
      for (const [label, viewport, ask] of [
        [
          "on a phone, the close question",
          { width: 375, height: 480 },
          (page) =>
            page.getByRole("button", { name: "Open / Close Meal" }).click(),
        ],
        [
          "on a wide screen, the question that erases a cost",
          { width: 1280, height: 600 },
          // The switch is drawn by its label, so the label is what a
          // person taps.
          (page) =>
            page.locator('label[for^="no_cost_switch-"]').first().click(),
        ],
      ]) {
        test(`${label}, a yes/no question on the page is drawn over the stack`, async ({
          page,
          context,
        }) => {
          await page.setViewportSize(viewport);
          // A cook with no cost yet, so the close button asks first.
          // Jane's $25.50 is in the fixture.
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
          let answerTheWrites;
          const questionOpen = new Promise((resolve) => {
            answerTheWrites = resolve;
          });
          for (const [resident, status, words] of [
            [2, 409, MEAL_CONFLICT],
            [1, 400, SETTLED],
            [3, 400, NOT_FOUND],
          ]) {
            await page.route(
              `**/api/v1/meals/*/residents/${resident}`,
              async (route) => {
                await questionOpen;
                await refuse(status, words)(route);
              },
            );
          }
          await page.goto("/meals/42/edit/");
          await page.waitForLoadState("networkidle");
          for (const name of [
            "B - Bob Johnson",
            "A - Jane Smith",
            "C - Alice Williams",
          ]) {
            await page.getByRole("cell", { name, exact: true }).click();
          }
          await page.evaluate(() => window.scrollTo(0, 0));

          await ask(page);
          const question = page.locator(".confirm-bar");
          await expect(question).toBeVisible();
          answerTheWrites();
          await expect(messages(page)).toHaveCount(3);
          await settled(page);

          // The stack reaches over the middle of each answer, so this
          // test shows something only while the two overlap.
          const stack = await page.locator(".toast-container").boundingBox();
          for (const answer of ["Yes", "No"]) {
            const button = question.getByRole("button", { name: answer });
            const box = await button.boundingBox();
            const middle = {
              x: box.x + box.width / 2,
              y: box.y + box.height / 2,
            };
            expect(middle.x).toBeGreaterThan(stack.x);
            expect(middle.x).toBeLessThan(stack.x + stack.width);
            expect(middle.y).toBeGreaterThan(stack.y);
            expect(middle.y).toBeLessThan(stack.y + stack.height);
            expect(await tappable(button)).toBe(true);
          }
          await question.getByRole("button", { name: "No" }).click();
          await expect(question).toBeHidden();
        });
      }

      // On a phone the stack sits at the bottom, and grows up. It must
      // stop before the top of the meal page: "← Calendar", the meal's
      // arrows and its date. A taller stack scrolls inside its own box.
      // Five errors: three show with a line for two more, and a tap on
      // the line shows all five. On a 375px phone the header takes two
      // lines, and three with a long name on the logout button (#151),
      // so the date is lower, and the stack must stop lower too.
      for (const [label, viewport, name] of [
        ["on a phone", { width: 375, height: 480 }, null],
        [
          "on a phone, with a long name",
          { width: 375, height: 480 },
          "Bartholomew Fitzgerald-Montgomery",
        ],
        ["on a short phone on its side", { width: 568, height: 320 }, null],
      ]) {
        test(`${label}, the stack stays under the meal's date and arrows`, async ({
          page,
          context,
        }) => {
          await setupAuthenticatedPage(page, context);
          if (name) {
            await context.addCookies([
              { name: "username", value: name, domain: "localhost", path: "/" },
            ]);
          }
          await fiveErrors(page, { width: viewport.width, height: 667 });
          await page.setViewportSize(viewport);

          async function expectTopClear() {
            await page.evaluate(() => window.scrollTo(0, 0));
            await settled(page);
            const stack = await page.locator(".toast-container").boundingBox();
            const date = await page.locator("h3").first().boundingBox();
            for (const control of [
              page.getByRole("button", { name: "Calendar" }),
              page.getByRole("button", { name: "Previous meal" }),
              page.getByRole("button", { name: "Next meal" }),
            ]) {
              const box = await control.boundingBox();
              expect(stack.y).toBeGreaterThanOrEqual(box.y + box.height);
              expect(await tappable(control)).toBe(true);
            }
            expect(stack.y).toBeGreaterThanOrEqual(date.y + date.height);
          }

          await expectTopClear();
          await showAllFive(page);
          await expectTopClear();
        });
      }
    });

    // The one warning the server sends: the bills write answers 400
    // with type "warning" and saves the bills anyway
    // (MealsController#save_bills, ThirdCookWarning). The bills store
    // shows it as an info toast that starts "Cooks saved.", never as an
    // error or a warning toast.
    test("a warning from the bills write says the cooks were saved, in an info toast", async ({
      page,
      context,
    }) => {
      const warning =
        "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.";
      await setupAuthenticatedPage(page, context, { billsWarning: warning });

      await page.goto("/meals/42/edit/");
      const cooks = page.locator('[aria-label="Select meal cook"]');
      await expect(cooks.first()).toHaveValue("1", { timeout: 10000 });
      // A screen reader says a message that is not an error through a
      // polite region that is on the page before the message comes
      // (toast_container.jsx).
      const polite = page.locator(".visually-hidden[role='status']");
      await expect(polite).toHaveText("");

      const answered = page.waitForResponse(
        (r) =>
          r.request().method() === "PATCH" &&
          r.url().includes("/api/v1/meals/42/bills"),
      );
      await cooks.nth(1).selectOption("2");
      expect((await answered).status()).toBe(400);

      const toast = page.locator(".toast--info");
      await expect(toast.locator(".toast__message")).toHaveText(
        `Cooks saved. ${warning}`,
        { timeout: 5000 },
      );
      await expect(page.locator(".toast--error")).toHaveCount(0);
      await expect(page.locator(".toast--warning")).toHaveCount(0);
      await expect(cooks.nth(1)).toHaveValue("2");
      await expect(polite).toHaveText(`Cooks saved. ${warning}`);
    });

    // Another page saved Jane's cost after this page loaded the meal
    // (#135). This page's save says it changes her cost from the $25.50
    // it shows, which the server no longer has, so the server writes
    // nothing and answers 409 with type "stale". The page shows the
    // server's words, does not send the save again, and loads the meal
    // again, so it shows the cost the other page saved.
    test("a save built on a cost another page changed shows the server's words, and the meal loads again", async ({
      page,
      context,
    }) => {
      const server = await setupAuthenticatedPage(page, context);

      await page.goto("/meals/42/edit/");
      const cost = page
        .getByRole("spinbutton", { name: "Set meal cost" })
        .first();
      await expect(cost).toHaveValue("25.50", { timeout: 10000 });

      // The other page's save.
      server.mealState.bills = [
        { resident_id: 1, amount: "30.0", no_cost: false },
      ];

      const saves = [];
      page.on("request", (request) => {
        if (
          request.method() === "PATCH" &&
          request.url().includes("/api/v1/meals/42/bills")
        ) {
          saves.push(request.postDataJSON());
        }
      });
      const refused = page.waitForResponse(
        (r) =>
          r.request().method() === "PATCH" &&
          r.url().includes("/api/v1/meals/42/bills"),
      );
      const loadedAgain = page.waitForResponse(
        (r) =>
          r.request().method() === "GET" &&
          r.url().includes("/api/v1/meals/42/cooks"),
      );
      await cost.fill("35.00");

      const answer = await refused;
      expect(answer.status()).toBe(409);
      expect((await answer.json()).type).toBe("stale");
      await expect(page.locator(".toast--error .toast__message")).toHaveText(
        "Nothing was saved, because this meal changed after you loaded it: Jane Smith's cost changed. Check the cooks and costs, then enter your change again.",
      );
      await loadedAgain;
      await expect(cost).toHaveValue("30.00");
      expect(saves).toHaveLength(1);
    });

    test("network error (no response) shows generic alert", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context);

      // Override resident endpoint to abort (simulates network failure)
      await page.route("**/api/v1/meals/*/residents/2*", (route) => {
        route.abort("connectionfailed");
      });

      await page.goto("/meals/42/edit/");
      await page.waitForLoadState("networkidle");

      const bobCell = page.getByRole("cell", {
        name: "B - Bob Johnson",
        exact: true,
      });
      await expect(bobCell).toBeVisible({ timeout: 10000 });

      // Click to toggle (network will fail)
      await bobCell.click();

      // Should show a generic error toast about no response
      await expect(page.locator(".toast--error")).toBeVisible({
        timeout: 5000,
      });
    });
  });

  test.describe("Loading States", () => {
    test("login button shows loader class during API call", async ({
      page,
    }) => {
      await stubPusher(page);
      await disableIdleTimer(page);
      await mockApi(page);

      // Slow down the login response so we can observe the loading state.
      // Registered after mockApi so it wins: Playwright matches routes
      // last-registered-first, so a route registered before mockApi would
      // be shadowed by its instant stub.
      await page.route("**/api/v1/residents/token", (route) => {
        setTimeout(() => {
          route.fulfill({
            status: 200,
            contentType: "application/json",
            body: JSON.stringify({
              token: "test",
              community_id: 1,
              resident_id: 1,
              username: "Jane",
            }),
          });
        }, 1000);
      });

      await page.goto("/");
      await page.locator('input[aria-label="email"]').fill("jane@example.com");
      await page.locator('input[aria-label="password"]').fill("pass");

      const submitButton = page.getByRole("button", { name: "Submit" });

      // Click submit -- button should get loader class while waiting
      await submitButton.click();

      // During the API call, button should have button-loader class
      await expect(submitButton).toHaveClass(/button-loader/, {
        timeout: 1000,
      });
    });
  });

  // At either end of the meal list the server sends the meal's own id
  // for the missing neighbour (MealFormSerializer#next_id and #prev_id,
  // pinned by spec/serializers/meal_form_serializer_spec.rb), never
  // null. So the arrow that points past the end is disabled, a tap on
  // it must not take the page anywhere else, and the other arrow must
  // still work (#113).
  test.describe("Navigation Edge Cases", () => {
    // The ids of the meals the page asked the server for, in order.
    function mealRequests(page) {
      const ids = [];
      page.on("request", (request) => {
        const match = request.url().match(/\/api\/v1\/meals\/(\d+)\/cooks/);
        if (match && request.method() === "GET") ids.push(Number(match[1]));
      });
      return ids;
    }

    // The neighbour's own answer, so its page shows its own menu.
    async function serveMeal(page, meal) {
      await page.route(`**/api/v1/meals/${meal.id}/cooks*`, (route) =>
        route.request().method() === "GET"
          ? route.fulfill({
              status: 200,
              contentType: "application/json",
              body: JSON.stringify(meal),
            })
          : route.fallback(),
      );
    }

    async function openMeal42(page) {
      await page.goto("/meals/42/edit/");
      await expect(page.getByLabel("Enter meal description")).toHaveValue(
        mealFixture.description,
        { timeout: 10000 },
      );
    }

    test("the last meal: the forward arrow stays on the meal, and the back arrow goes back", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context, {
        mealData: { ...mealFixture, prev_id: 41, next_id: mealFixture.id },
      });
      await serveMeal(page, {
        ...mealFixture,
        id: 41,
        date: "2026-01-13",
        description: "Soup night",
        prev_id: 41,
        next_id: mealFixture.id,
      });
      const requested = mealRequests(page);
      await openMeal42(page);

      const next = page.getByRole("button", { name: "Next meal" });
      await expect(next).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "Previous meal" }),
      ).toBeEnabled();
      // force: a plain click would wait for the arrow to be enabled,
      // and it never is. A tap on it must still do nothing: before the
      // fix it opened the same meal again, which added a history entry,
      // so Back needed an extra press.
      const historyBefore = await page.evaluate(() => window.history.length);
      await next.click({ force: true });
      await expect(page).toHaveURL(/\/meals\/42\/edit\/?$/);
      expect(await page.evaluate(() => window.history.length)).toBe(
        historyBefore,
      );

      await page.getByRole("button", { name: "Previous meal" }).click();
      await expect(page).toHaveURL(/\/meals\/41\/edit\/?$/, { timeout: 5000 });
      await expect(page.getByLabel("Enter meal description")).toHaveValue(
        "Soup night",
      );
      // The forward tap asked for no meal: the only other request is the
      // back arrow's.
      expect(requested).toEqual([42, 41]);
    });

    test("the first meal: the back arrow stays on the meal, and the forward arrow goes forward", async ({
      page,
      context,
    }) => {
      await setupAuthenticatedPage(page, context, {
        mealData: { ...mealFixture, prev_id: mealFixture.id, next_id: 43 },
      });
      await serveMeal(page, {
        ...mealFixture,
        id: 43,
        date: "2026-01-17",
        description: "Tacos",
        prev_id: mealFixture.id,
        next_id: 43,
      });
      const requested = mealRequests(page);
      await openMeal42(page);

      const previous = page.getByRole("button", { name: "Previous meal" });
      await expect(previous).toBeDisabled();
      await expect(
        page.getByRole("button", { name: "Next meal" }),
      ).toBeEnabled();
      // force: a plain click would wait for the arrow to be enabled,
      // and it never is. A tap on it must still do nothing: before the
      // fix it opened the same meal again, which added a history entry,
      // so Back needed an extra press.
      const historyBefore = await page.evaluate(() => window.history.length);
      await previous.click({ force: true });
      await expect(page).toHaveURL(/\/meals\/42\/edit\/?$/);
      expect(await page.evaluate(() => window.history.length)).toBe(
        historyBefore,
      );

      await page.getByRole("button", { name: "Next meal" }).click();
      await expect(page).toHaveURL(/\/meals\/43\/edit\/?$/, { timeout: 5000 });
      await expect(page.getByLabel("Enter meal description")).toHaveValue(
        "Tacos",
      );
      expect(requested).toEqual([42, 43]);
    });
  });
});
