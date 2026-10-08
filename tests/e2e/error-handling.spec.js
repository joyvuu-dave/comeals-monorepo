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

      // Should show validation error toast
      const toast = page.locator(".toast--error");
      await expect(toast).toBeVisible({ timeout: 5000 });
      await expect(toast.locator(".toast__message")).toHaveText(EVENT_REFUSED);
    });

    test("error toast clears when calendar modal is closed", async ({
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

      // Error toast should appear
      await expect(page.locator(".toast--error")).toBeVisible({
        timeout: 5000,
      });

      // Close the modal via X button
      await modal.locator(".close-button").click();

      // Toast should be cleared
      await expect(page.locator(".toast--error")).not.toBeVisible({
        timeout: 3000,
      });
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
