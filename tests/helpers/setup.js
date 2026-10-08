/**
 * Shared test setup helpers for Comeals E2E tests.
 *
 * Handles: auth cookies, API mocking, and Pusher stubbing. The idle
 * timer switch and the cache clearing come from browser_setup.js,
 * shared with the integration suite.
 */

// All fixtures are generated from the real Rails API by
// `rake test:generate_fixtures` (bin/check fails when they are stale).
// Do not edit them by hand — change the seed story in
// lib/tasks/test/generate_fixtures.rake and regenerate.
const mealFixture = require("../fixtures/meal.json");
const calendarFixture = require("../fixtures/calendar.json");
const historyFixture = require("../fixtures/history.json");
const hostsFixture = require("../fixtures/hosts.json");
const rotationFixture = require("../fixtures/rotation.json");
const eventFixture = require("../fixtures/event.json");
const commonHouseReservationFixture = require("../fixtures/common_house_reservation.json");
const guestRoomReservationFixture = require("../fixtures/guest_room_reservation.json");
const fs = require("fs");
const path = require("path");
const { disableIdleTimer, clearStorage } = require("./browser_setup");

// The mocked suite's frozen "now": noon on 2026-01-15 in the community's
// zone. The offset is written out because this runs in Node, and a time
// with no offset is read in the zone of the machine running the tests.
// playwright.config.js pins only the browser's zone. Without the offset,
// a Mac in Chicago froze at 10:00 in Los Angeles, the Linux container at
// 04:00, and a machine in Tokyo at 19:00 the day before, where the
// fixture meal reads "Tomorrow".
const FROZEN_NOW = new Date("2026-01-15T12:00:00-08:00");

// What production sends for an exception ApiController does not rescue:
// Rails' own page (production.rb has consider_all_requests_local false),
// as HTML, with no message in it. A mocked 500 with a JSON message is an
// answer the server never gives.
const RAILS_500_PAGE = fs.readFileSync(
  path.join(__dirname, "../../public/500.html"),
  "utf8",
);

function rails500(route) {
  return route.fulfill({
    status: 500,
    contentType: "text/html; charset=utf-8",
    body: RAILS_500_PAGE,
  });
}

// A bills save answered with a status that is not 200.
function answerBillsSave(route, status, body) {
  return route.fulfill({
    status,
    contentType: "application/json",
    body: JSON.stringify(body),
  });
}

// An amount's text in one form, so the bills stub compares amounts by
// value, as the server does, without turning them into numbers: "" and
// "0.0" are both "0.00", and "25.5" and "25.50" are both "25.50".
function amountInCents(text) {
  const [dollars, cents = ""] = (text === "" ? "0" : text).split(".");
  return `${dollars.replace(/^0+(?=\d)/, "")}.${cents.replace(/0+$/, "").padEnd(2, "0")}`;
}

// One side of a bills edit (`from` or `to`) is the stored bill: both
// missing, or the same amount by value and the same no_cost
// (BillsPayload::Edit#matches?).
function sameBill(side, bill) {
  if (side === undefined) return bill === undefined;
  return (
    bill !== undefined &&
    amountInCents(side.amount) === amountInCents(bill.amount) &&
    side.no_cost === bill.no_cost
  );
}

// What changed since the page read the meal, in the server's words
// (BillsPayload::Edit#change_seen), for an edit whose cook's bill is
// neither its `from` nor its `to`.
function changeSeen(edit, bill, meal) {
  const cook = meal.residents.find((r) => r.id === edit.resident_id);
  const name = cook ? cook.short_name : `Resident #${edit.resident_id}`;
  if (bill === undefined) return `${name} is no longer a cook`;
  if (edit.op === "add") return `${name} is already a cook`;
  return `${name}'s cost changed`;
}

// Rails' Array#to_sentence: "a", "a and b", "a, b, and c".
function toSentence(parts) {
  if (parts.length <= 2) return parts.join(" and ");
  return `${parts.slice(0, -1).join(", ")}, and ${parts[parts.length - 1]}`;
}

// ApiController#not_found_api: the 404 for a record that is not there.
// A silent caller logs it as it is, so a test that expects it lets
// NOT_FOUND_LOG through its allowedConsoleErrors.
const NOT_FOUND_MESSAGE =
  "The page you were looking for doesn't exist. You may have mistyped the address or the page may have moved.";
const NOT_FOUND_LOG = new RegExp(
  `^${NOT_FOUND_MESSAGE.replace(/[.]/g, "\\.")}$`,
);

const AUTH_COOKIES = [
  { name: "token", value: "test-token-abc123", domain: "localhost", path: "/" },
  {
    name: "community_id",
    value: "1",
    domain: "localhost",
    path: "/",
  },
  {
    name: "resident_id",
    value: "1",
    domain: "localhost",
    path: "/",
  },
  {
    name: "username",
    value: "Jane Smith",
    domain: "localhost",
    path: "/",
  },
  // A real login stores the community's zone from the token answer
  // (login.jsx), and the app reads "today" in it. Without the cookie the
  // app falls back to the browser's own zone.
  {
    name: "timezone",
    value: "America/Los_Angeles",
    domain: "localhost",
    path: "/",
  },
];

/**
 * Set auth cookies so the app treats the user as logged in.
 */
async function authenticateContext(context) {
  await context.addCookies(AUTH_COOKIES);
}

/**
 * Stub Pusher globally so the app never makes real WebSocket connections.
 * Must be called before navigating to the app.
 */
async function stubPusher(page) {
  await page.addInitScript(() => {
    window.Pusher = function () {
      this.connection = {
        socket_id: "test-socket-id",
        bind: function () {},
      };
      this.subscribe = function () {
        return {
          bind: function () {},
          unbind_all: function () {},
        };
      };
      this.unsubscribe = function () {};
    };
  });
}

/**
 * Slow the page's renderer via DevTools CPU throttling when
 * E2E_CPU_THROTTLE is set (e.g. E2E_CPU_THROTTLE=4 npm run test:e2e).
 * Used to hunt timing races (#21): OS-level CPU contention cannot slow
 * Chromium reliably — macOS hands it the performance cores — but DevTools
 * throttling slows the renderer itself. Off by default; no effect on
 * normal runs.
 */
async function throttleCpu(page) {
  const rate = Number(process.env.E2E_CPU_THROTTLE);
  if (!rate || rate <= 1) {
    return;
  }
  // CDP is Chromium-only; WebKit has no equivalent, so the throttle
  // hunts its races in Chromium alone.
  if (page.context().browser()?.browserType().name() !== "chromium") {
    return;
  }
  const session = await page.context().newCDPSession(page);
  await session.send("Emulation.setCPUThrottlingRate", { rate });
}

/**
 * Mock all API routes with fixture data. Call after page is created but
 * before navigating to the app.
 *
 * Ordering convention: Playwright matches routes last-registered-first,
 * so a test that wants to specialize an endpoint (error response, delay)
 * must register its route AFTER calling this helper (or
 * setupAuthenticatedPage). A route registered before is silently
 * shadowed by the stubs here.
 *
 * Options:
 *   mealData    - override meal fixture
 *   calendarData - override calendar fixture
 *   historyData - override history fixture
 *   hosts       - hosts list for reservation forms
 *   billsWarning - the advice ThirdCookWarning gives about the rotation.
 *                 The stub cannot read the rotation, so a test that wants
 *                 the warning passes its words here, and every bills save
 *                 that writes is answered with them, as a 400 of type
 *                 "warning", the way the server answers it.
 *
 * Returns { mealState }: the meal as the stub stores it. A test changes
 * it to stand for a save made on another page. The next fetch of the
 * meal and the next bills save see the change.
 */
async function mockApi(page, options = {}) {
  await throttleCpu(page);
  const meal = options.mealData || mealFixture;
  const calendar = options.calendarData || calendarFixture;
  const history = options.historyData || historyFixture;
  const hosts = options.hosts || hostsFixture;

  // The app refetches /cooks after a close, extras or bills save
  // settles, so the mock must serve the state those PATCHes wrote — a
  // static fixture would revert the UI on refetch. Tests that override
  // the closed/max/bills routes to capture payloads should call
  // route.fallback() so these handlers still record the state and
  // fulfill.
  const mealState = {
    closed: meal.closed,
    closed_at: meal.closed_at,
    max: meal.max,
    bills: meal.bills,
  };

  // Ids for the rows the write stubs below create, one per row, like
  // the database's.
  let nextRowId = 9000;

  // The meal and resident ids in /api/v1/meals/:meal/residents/:resident...
  function mealAndResident(route) {
    const match = new URL(route.request().url()).pathname.match(
      /\/meals\/(\d+)\/residents\/(\d+)/,
    );
    return { mealId: Number(match[1]), residentId: Number(match[2]) };
  }

  function json(route, body) {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  }

  // Meal data (GET /api/v1/meals/*/cooks*)
  await page.route("**/api/v1/meals/*/cooks*", (route) => {
    if (route.request().method() === "GET") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ ...meal, ...mealState }),
      });
    } else {
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  // Next meal (GET /api/v1/meals/next*)
  await page.route("**/api/v1/meals/next*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ meal_id: meal.id }),
    });
  });

  // Calendar data (GET /api/v1/communities/*/calendar/*)
  await page.route("**/api/v1/communities/*/calendar/*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(calendar),
    });
  });

  // Meal history (GET /api/v1/meals/*/history*)
  await page.route("**/api/v1/meals/*/history*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(history),
    });
  });

  // Attendance (POST, PATCH, DELETE /api/v1/meals/:m/residents/:r).
  // The answers are MealsController's: a sign-up gets the saved row
  // (MealResidentSerializer), and the store keeps its created_at as the
  // sign-up time, which decides whether a late sign-up on a closed meal
  // can be undone.
  await page.route("**/api/v1/meals/*/residents/*", (route) => {
    const method = route.request().method();
    if (method === "POST") {
      const { mealId, residentId } = mealAndResident(route);
      const body = route.request().postDataJSON();
      json(route, {
        id: nextRowId++,
        meal_id: mealId,
        resident_id: residentId,
        late: body.late,
        vegetarian: body.vegetarian,
        created_at: new Date().toISOString(),
      });
    } else if (method === "PATCH") {
      json(route, { message: "MealResident updated." });
    } else {
      json(route, { message: "MealResident destroyed." });
    }
  });

  // Guests (POST .../residents/:r/guests, DELETE .../guests/:id). The
  // "**" matters: a "*" stops at a slash, so "guests*" never matched a
  // delete. A new guest belongs to the resident in the URL, with the
  // vegetarian flag that was sent (GuestSerializer), and a new id each
  // time, as the store keys guests by id.
  await page.route("**/api/v1/meals/*/residents/*/guests**", (route) => {
    if (route.request().method() === "POST") {
      const { mealId, residentId } = mealAndResident(route);
      json(route, {
        id: nextRowId++,
        meal_id: mealId,
        resident_id: residentId,
        vegetarian: route.request().postDataJSON().vegetarian,
        created_at: new Date().toISOString(),
      });
    } else {
      json(route, { message: "Guest was destroyed." });
    }
  });

  // Meal closed toggle (PATCH /api/v1/meals/*/closed*)
  await page.route("**/api/v1/meals/*/closed*", (route) => {
    const payload = route.request().postDataJSON();
    mealState.closed = payload.closed;
    mealState.closed_at = payload.closed ? new Date().toISOString() : null;
    if (!payload.closed) {
      mealState.max = null;
    }
    route.fulfill({ status: 200, body: "{}" });
  });

  // Meal description (PATCH /api/v1/meals/*/description*)
  await page.route("**/api/v1/meals/*/description*", (route) => {
    route.fulfill({ status: 200, body: "{}" });
  });

  // Meal bills (PATCH /api/v1/meals/*/bills*). Like
  // MealsController#update_bills (docs/adr/0009-bills-saves-send-edits.md).
  // A body in the old format, which listed every cook under `bills`, is
  // refused as out of date. A save needs an Idempotency-Key. A key the
  // stub has seen answers as "replayed" when the edits are the same, and
  // 422 when they are not. Each edit is checked against its cook's stored
  // bill: an edit whose `to` is stored already is done, an edit whose
  // `from` is stored is written, and any other edit refuses the whole
  // save with a 409 of type "stale". A cook no edit names keeps their
  // bill. A blank amount is stored as zero. The answer lists every stored
  // bill, with the billsWarning option's words when it has them.
  const billsSaveKeys = new Map();
  await page.route("**/api/v1/meals/*/bills*", (route) => {
    const request = route.request();
    const key = request.headers()["idempotency-key"];
    const body = request.postDataJSON();
    if (body.bills !== undefined) {
      return answerBillsSave(route, 400, {
        message:
          "Nothing was saved, because this page is out of date. Please reload the page and enter the costs again.",
        type: "outdated",
      });
    }
    const { edits } = body;
    const sent = JSON.stringify(edits);
    if (key === undefined) {
      return answerBillsSave(route, 400, {
        message:
          "A bills save needs an Idempotency-Key header, with a new key for each save. Nothing was saved.",
      });
    }
    if (billsSaveKeys.has(key)) {
      return billsSaveKeys.get(key) === sent
        ? json(route, {
            message: "This save was already made, so nothing more was written.",
            type: "replayed",
            bills: mealState.bills,
          })
        : answerBillsSave(route, 422, {
            message:
              "This Idempotency-Key was already used for a different save. Nothing was saved. Send a new key with each save.",
          });
    }
    const stored = new Map(mealState.bills.map((b) => [b.resident_id, b]));
    const changesSeen = edits
      .filter(
        (edit) =>
          !sameBill(edit.to, stored.get(edit.resident_id)) &&
          !sameBill(edit.from, stored.get(edit.resident_id)),
      )
      .map((edit) => changeSeen(edit, stored.get(edit.resident_id), meal));
    if (changesSeen.length > 0) {
      return answerBillsSave(route, 409, {
        message: `Nothing was saved, because this meal changed after you loaded it: ${toSentence(changesSeen)}. Check the cooks and costs, then enter your change again.`,
        type: "stale",
        bills: mealState.bills,
      });
    }
    for (const edit of edits) {
      if (sameBill(edit.to, stored.get(edit.resident_id))) continue;
      if (edit.to === undefined) {
        stored.delete(edit.resident_id);
      } else {
        stored.set(edit.resident_id, {
          resident_id: edit.resident_id,
          amount: edit.to.amount === "" ? "0.0" : edit.to.amount,
          no_cost: edit.to.no_cost,
        });
      }
    }
    mealState.bills = [...stored.values()];
    billsSaveKeys.set(key, sent);
    if (options.billsWarning) {
      return answerBillsSave(route, 400, {
        message: options.billsWarning,
        type: "warning",
        bills: mealState.bills,
      });
    }
    json(route, { message: "Form submitted.", bills: mealState.bills });
  });

  // Meal max/extras (PATCH /api/v1/meals/*/max*)
  await page.route("**/api/v1/meals/*/max*", (route) => {
    mealState.max = route.request().postDataJSON().max;
    route.fulfill({ status: 200, body: "{}" });
  });

  // Login (POST /api/v1/residents/token)
  await page.route("**/api/v1/residents/token", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          token: "test-token-abc123",
          community_id: 1,
          resident_id: 1,
          username: "Jane Smith",
          timezone: "America/Los_Angeles",
        }),
      });
    } else {
      route.continue();
    }
  });

  // Logout (DELETE /api/v1/sessions/current). Without this stub the logout
  // request falls through to the /api proxy and logs ECONNREFUSED, because
  // no Rails server runs during E2E.
  await page.route("**/api/v1/sessions/current", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ message: "Signed out." }),
    });
  });

  // Password reset request (POST /api/v1/residents/password-reset)
  await page.route("**/api/v1/residents/password-reset", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Check your email." }),
      });
    } else {
      route.continue();
    }
  });

  // Password reset with token (GET name, POST new password)
  await page.route("**/api/v1/residents/name/*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ name: "Jane Smith" }),
    });
  });

  await page.route("**/api/v1/residents/password-reset/*", (route) => {
    if (route.request().method() === "POST") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({ message: "Password updated!" }),
      });
    } else {
      route.continue();
    }
  });

  // Events CRUD -- individual event (must come before collection route)
  await page.route("**/api/v1/events/**", (route) => {
    const method = route.request().method();
    if (method === "GET") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(eventFixture),
      });
    } else {
      // PATCH (update) or DELETE
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  // Events collection (POST to create). The pattern names the path
  // exactly: in a Playwright glob "?" is one character, so the old
  // "events?*" never matched a POST to /api/v1/events.
  await page.route("**/api/v1/events", (route) => {
    route.fulfill({ status: 200, body: "{}" });
  });

  // Common house reservations -- individual
  await page.route("**/api/v1/common-house-reservations/**", (route) => {
    const method = route.request().method();
    if (method === "GET") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(commonHouseReservationFixture),
      });
    } else {
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  // Common house reservations -- collection (POST to create)
  await page.route("**/api/v1/common-house-reservations", (route) => {
    route.fulfill({ status: 200, body: "{}" });
  });

  // Guest room reservations -- individual
  await page.route("**/api/v1/guest-room-reservations/**", (route) => {
    const method = route.request().method();
    if (method === "GET") {
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(guestRoomReservationFixture),
      });
    } else {
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  // Guest room reservations -- collection (POST to create)
  await page.route("**/api/v1/guest-room-reservations", (route) => {
    route.fulfill({ status: 200, body: "{}" });
  });

  // Community hosts
  await page.route("**/api/v1/communities/*/hosts*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(hosts),
    });
  });

  // Rotations
  await page.route("**/api/v1/rotations/*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(rotationFixture),
    });
  });

  // Resident ID lookup
  await page.route("**/api/v1/residents/id*", (route) => {
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(1),
    });
  });

  // Slow-backend mode: E2E_API_DELAY=300 npm run test:e2e holds every
  // mocked API response for that many milliseconds. The companion to
  // E2E_CPU_THROTTLE (#21): latency opens the load windows where
  // stale-state bugs live (rows editable against a meal that has not
  // arrived, debounced saves outliving a navigation). Registered last,
  // so it runs first (routes match newest-first) and falls through to
  // the stubs above. Test-specific routes registered after this helper
  // bypass the delay — they control their own timing.
  const apiDelay = Number(process.env.E2E_API_DELAY);
  if (apiDelay > 0) {
    await page.route("**/api/**", async (route) => {
      await new Promise((resolve) => setTimeout(resolve, apiDelay));
      await route.fallback();
    });
  }

  return { mealState };
}

/**
 * Full page setup: auth + pusher stub + idle timer disable + API mocks.
 * Returns what mockApi returns.
 */
async function setupAuthenticatedPage(page, context, options = {}) {
  await authenticateContext(context);
  await stubPusher(page);
  await disableIdleTimer(page);
  return mockApi(page, options);
}

module.exports = {
  FROZEN_NOW,
  NOT_FOUND_MESSAGE,
  NOT_FOUND_LOG,
  rails500,
  stubPusher,
  disableIdleTimer,
  clearStorage,
  mockApi,
  setupAuthenticatedPage,
};
