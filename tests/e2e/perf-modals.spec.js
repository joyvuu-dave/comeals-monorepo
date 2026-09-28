/**
 * Modal open performance benchmark.
 *
 * Measures click-to-populated latency for the 6 calendar modals that
 * users have flagged as slow:
 *
 *   Sidebar buttons (New):
 *     - Guest Room   (today: fetches hosts list)
 *     - Common House (today: fetches hosts list)
 *     - Event        (today: no fetch, baseline reference)
 *
 *   Existing calendar record click (Edit):
 *     - Guest Room Edit   (fetches event + hosts)
 *     - Common House Edit (fetches event + residents)
 *     - Event Edit        (fetches event only)
 *
 * All API calls are mocked with a configurable injected delay so the
 * numbers reflect realistic mobile / Cordova conditions rather than
 * localhost's ~5ms RTT. Run at multiple latencies to see the effect
 * profile:
 *
 *   LATENCY_MS=0   npx playwright test tests/e2e/perf-modals.spec.js
 *   LATENCY_MS=80  npx playwright test tests/e2e/perf-modals.spec.js
 *   LATENCY_MS=200 npx playwright test tests/e2e/perf-modals.spec.js
 *
 * Tunables (env vars):
 *   LATENCY_MS  simulated per-request network delay in ms (default 80)
 *   ITERATIONS  measurement iterations per scenario   (default 10)
 *   WARMUP      warmup iterations, discarded          (default 2)
 *
 * Output:
 *   tmp/perf-modals-<LATENCY_MS>ms.json — machine-readable results
 *   stdout                              — human-readable summary table
 *
 * Two metrics are captured per scenario:
 *   - clickToScaffold:  click → modal structure first painted (the
 *                       "skeleton" win from proposal #1 targets this)
 *   - clickToPopulated: click → real data visible in form fields
 *                       (the "cache hosts" win from proposal #2 targets
 *                       this for Guest Room / Common House New modals)
 *
 * Baseline workflow:
 *   1. git checkout main; run at 0/80/200ms; keep the JSON files
 *   2. git checkout feature-branch; re-run; diff the JSON files
 */

const { test, expect } = require("../helpers/test");
const fs = require("fs");
const path = require("path");
const { setupAuthenticatedPage } = require("../helpers/setup");

const LATENCY_MS = parseInt(process.env.LATENCY_MS || "80", 10);
const ITERATIONS = parseInt(process.env.ITERATIONS || "10", 10);
const WARMUP = parseInt(process.env.WARMUP || "2", 10);

// On the baseline (pre-feature) code path, the fieldset is rendered only
// once the modal's data has loaded — there's no data-populated attribute.
// When BASELINE_MODE=1 is set, the populated selector falls back to a
// bare `fieldset`, so clickToPopulated measures the same "data is here"
// moment on both code paths and stays apples-to-apples across branches.
const BASELINE_MODE = process.env.BASELINE_MODE === "1";

const CALENDAR_URL = "/calendar/all/2026-01-15/";

// Generated from the real API by `rake test:generate_fixtures`, so the
// mocks exercise the same store-boundary transforms as production
// traffic.
const HOSTS = require("../fixtures/hosts.json");
const guestRoomReservationFixture = require("../fixtures/guest_room_reservation.json");
const commonHouseReservationFixture = require("../fixtures/common_house_reservation.json");
const eventFixture = require("../fixtures/event.json");

/**
 * Override the modal-relevant endpoints with handlers that inject a
 * per-request delay. Playwright matches the most-recently-registered
 * handler, so these take precedence over the shared mocks in setup.js.
 */
async function injectLatency(page, latencyMs) {
  const delay = () =>
    latencyMs > 0 ? new Promise((r) => setTimeout(r, latencyMs)) : null;

  await page.route("**/api/v1/guest-room-reservations/**", async (route) => {
    if (route.request().method() === "GET") {
      await delay();
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(guestRoomReservationFixture),
      });
    } else {
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  await page.route("**/api/v1/common-house-reservations/**", async (route) => {
    if (route.request().method() === "GET") {
      await delay();
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(commonHouseReservationFixture),
      });
    } else {
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  await page.route("**/api/v1/events/**", async (route) => {
    if (route.request().method() === "GET") {
      await delay();
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(eventFixture),
      });
    } else {
      route.fulfill({ status: 200, body: "{}" });
    }
  });

  await page.route("**/api/v1/communities/*/hosts*", async (route) => {
    await delay();
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(HOSTS),
    });
  });
}

/** Percentile helpers. */
function percentile(sortedAsc, q) {
  if (sortedAsc.length === 0) return 0;
  const idx = Math.min(sortedAsc.length - 1, Math.floor(sortedAsc.length * q));
  return sortedAsc[idx];
}

function summarize(timings) {
  const sorted = [...timings].sort((a, b) => a - b);
  const mean = timings.reduce((a, b) => a + b, 0) / timings.length;
  return {
    n: timings.length,
    min: Math.round(sorted[0]),
    p50: Math.round(percentile(sorted, 0.5)),
    p95: Math.round(percentile(sorted, 0.95)),
    max: Math.round(sorted[sorted.length - 1]),
    mean: Math.round(mean),
  };
}

/**
 * Run a scenario N+WARMUP times, return timings (post-warmup only).
 *
 * setupIteration: async () => void
 *   Run before each iteration. Typically navigates and waits for
 *   calendar to be ready. Excluded from timing.
 *
 * action: async () => void
 *   The click(s) the user would make. Timing starts immediately
 *   before this runs.
 *
 * waitFor: async () => void
 *   Waits for the post-condition that marks "done." Timing ends
 *   immediately after this returns.
 *
 * opened: RegExp
 *   The URL the click must open. Checked after the timer stops, so it
 *   does not change the timings, but a click on the wrong element
 *   fails the run instead of saving another modal's timings under this
 *   scenario's name. (The New and Edit forms both set data-populated,
 *   so the wait selectors alone cannot tell them apart.)
 */
async function bench({ page, setupIteration, action, waitFor, opened }) {
  const timings = [];
  for (let i = 0; i < ITERATIONS + WARMUP; i++) {
    await setupIteration();
    const t0 = Date.now();
    await action();
    await waitFor();
    const t1 = Date.now();
    await expect(page).toHaveURL(opened);
    if (i >= WARMUP) timings.push(t1 - t0);
  }
  return timings;
}

// The URL of each modal (the routes in calendar/show.jsx).
const OPENED = {
  guestRoomEdit: /\/guest-room-reservations\/edit\/\d+\/?$/,
  commonHouseEdit: /\/common-house-reservations\/edit\/\d+\/?$/,
  eventEdit: /\/events\/edit\/\d+\/?$/,
  guestRoomNew: /\/guest-room-reservations\/new\/?$/,
  commonHouseNew: /\/common-house-reservations\/new\/?$/,
  eventNew: /\/events\/new\/?$/,
};

// The guest room reservation's tile on the calendar. `text=Guest Room`
// finds the sidebar's "Guest Room" button first, because the sidebar
// comes before the calendar grid, and that button opens the New form.
function guestRoomTile(page) {
  return page.locator(".rbc-event", { hasText: "Guest Room" }).first();
}

/**
 * Aggregate results across all tests in this describe. Written to
 * disk + pretty-printed in afterAll so all scenarios end up in one
 * report file.
 */
const results = {};

// Most cold scenarios run 3 bench loops (scaffold, form-visible, populated)
// of (ITERATIONS + WARMUP) iterations each, where one iteration is ~0.5–1.5s
// depending on LATENCY_MS. Give plenty of headroom so high iteration counts
// don't trip the default 30s per-test cap.
const PER_TEST_TIMEOUT_MS = Math.max(
  60_000,
  3 * (ITERATIONS + WARMUP) * (1500 + LATENCY_MS * 2),
);

test.describe(`Modal open perf @ ${LATENCY_MS}ms injected latency`, () => {
  // Serial: one scenario at a time, no cross-talk.
  test.describe.configure({ mode: "serial", timeout: PER_TEST_TIMEOUT_MS });

  test.beforeEach(async ({ page, context }) => {
    await setupAuthenticatedPage(page, context);
    await injectLatency(page, LATENCY_MS);
  });

  test.afterAll(async () => {
    const outDir = path.resolve(__dirname, "../../tmp");
    fs.mkdirSync(outDir, { recursive: true });
    const outPath = path.join(outDir, `perf-modals-${LATENCY_MS}ms.json`);

    const payload = {
      latencyMs: LATENCY_MS,
      iterations: ITERATIONS,
      warmup: WARMUP,
      timestamp: new Date().toISOString(),
      scenarios: results,
    };
    fs.writeFileSync(outPath, JSON.stringify(payload, null, 2));

    console.log(
      `\n=== Modal open perf @ ${LATENCY_MS}ms latency ` +
        `(${ITERATIONS} iter + ${WARMUP} warmup) ===`,
    );
    const rows = Object.entries(results).flatMap(([scenario, m]) => {
      const r = [];
      if (m.clickToScaffold) {
        r.push({ scenario, metric: "clickToScaffold", ...m.clickToScaffold });
      }
      if (m.clickToFormVisible) {
        r.push({
          scenario,
          metric: "clickToFormVisible",
          ...m.clickToFormVisible,
        });
      }
      if (m.clickToPopulated) {
        r.push({ scenario, metric: "clickToPopulated", ...m.clickToPopulated });
      }
      return r;
    });
    console.table(rows);
    console.log(`\nWrote ${outPath}\n`);
  });

  // --- Helpers shared by scenarios below ---

  async function gotoCalendarFresh(page) {
    await page.goto(CALENDAR_URL);
    await page.waitForSelector(".rbc-calendar");
  }

  /**
   * Close an open modal by clicking its ×. Waits until the modal's
   * content wrapper is gone so the next click isn't swallowed by a
   * half-teardown overlay.
   */
  async function closeModal(page) {
    await page
      .locator(".ReactModal__Content--after-open .close-button")
      .click();
    await page.waitForSelector(".ReactModal__Content--after-open", {
      state: "detached",
    });
  }

  /**
   * "Warm" scenarios measure what happens on the second+ open of a
   * modal in the same session — no page navigation between iterations,
   * so the in-memory hosts cache (populated on the first open) stays
   * hot. This is the case where the hosts-cache optimization pays off.
   *
   * gotoCalendarFresh happens once, then one prime-open/close runs to
   * seed the cache, then ITERATIONS+WARMUP measured open/close cycles
   * follow — all hitting a warm cache.
   */

  /**
   * Scaffold selector: the react-modal content wrapper with the
   * "after-open" class. This is the first frame where ANY modal
   * content is visible — either "Loading..." or the real form.
   * Click-to-scaffold measures how fast the modal itself paints.
   */
  const SCAFFOLD = ".ReactModal__Content--after-open";

  /**
   * Form-visible selector: any fieldset inside the open modal. The
   * feature branch renders the fieldset from the first frame (even
   * before data arrives); the baseline branch only renders it once
   * `ready: true`. The delta between this metric and clickToPopulated
   * is exactly the skeleton-UI win: how much sooner the user sees
   * form structure vs. how much later they see real data.
   */
  const FORM_VISIBLE = `.ReactModal__Content--after-open fieldset`;

  /**
   * Populated selector: the fieldset carries `data-populated="true"`
   * once the data the form depends on is available. For Event New
   * (no fetch gate), there's nothing to wait on, so its populated
   * moment coincides with form-visible — the benchmark uses the
   * bare `fieldset` selector for that one scenario.
   */
  const POPULATED_WITH_DATA = BASELINE_MODE
    ? FORM_VISIBLE
    : `.ReactModal__Content--after-open fieldset[data-populated="true"]`;
  const POPULATED_EVENT_NEW = FORM_VISIBLE;

  // --- Scenarios: Edit modals (click existing record) ---

  test("Guest Room — Edit", async ({ page }) => {
    await gotoCalendarFresh(page);

    const scaffoldTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => guestRoomTile(page).click(),
      waitFor: () => page.waitForSelector(SCAFFOLD),
      opened: OPENED.guestRoomEdit,
    });

    const formVisibleTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => guestRoomTile(page).click(),
      waitFor: () => page.waitForSelector(FORM_VISIBLE),
      opened: OPENED.guestRoomEdit,
    });

    const populatedTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => guestRoomTile(page).click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.guestRoomEdit,
    });

    results["Guest Room Edit"] = {
      clickToScaffold: summarize(scaffoldTimings),
      clickToFormVisible: summarize(formVisibleTimings),
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Common House — Edit", async ({ page }) => {
    await gotoCalendarFresh(page);

    const scaffoldTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => page.locator("text=Book Club").first().click(),
      waitFor: () => page.waitForSelector(SCAFFOLD),
      opened: OPENED.commonHouseEdit,
    });

    const formVisibleTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => page.locator("text=Book Club").first().click(),
      waitFor: () => page.waitForSelector(FORM_VISIBLE),
      opened: OPENED.commonHouseEdit,
    });

    const populatedTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => page.locator("text=Book Club").first().click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.commonHouseEdit,
    });

    results["Common House Edit"] = {
      clickToScaffold: summarize(scaffoldTimings),
      clickToFormVisible: summarize(formVisibleTimings),
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Event — Edit", async ({ page }) => {
    await gotoCalendarFresh(page);

    const scaffoldTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => page.locator("text=Community Meeting").first().click(),
      waitFor: () => page.waitForSelector(SCAFFOLD),
      opened: OPENED.eventEdit,
    });

    const formVisibleTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => page.locator("text=Community Meeting").first().click(),
      waitFor: () => page.waitForSelector(FORM_VISIBLE),
      opened: OPENED.eventEdit,
    });

    const populatedTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () => page.locator("text=Community Meeting").first().click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.eventEdit,
    });

    results["Event Edit"] = {
      clickToScaffold: summarize(scaffoldTimings),
      clickToFormVisible: summarize(formVisibleTimings),
      clickToPopulated: summarize(populatedTimings),
    };
  });

  // --- Scenarios: New modals (sidebar buttons) ---

  test("Guest Room — New (sidebar)", async ({ page }) => {
    await gotoCalendarFresh(page);

    const scaffoldTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Guest Room", exact: true }).click(),
      waitFor: () => page.waitForSelector(SCAFFOLD),
      opened: OPENED.guestRoomNew,
    });

    const formVisibleTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Guest Room", exact: true }).click(),
      waitFor: () => page.waitForSelector(FORM_VISIBLE),
      opened: OPENED.guestRoomNew,
    });

    const populatedTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Guest Room", exact: true }).click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.guestRoomNew,
    });

    results["Guest Room New"] = {
      clickToScaffold: summarize(scaffoldTimings),
      clickToFormVisible: summarize(formVisibleTimings),
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Common House — New (sidebar)", async ({ page }) => {
    await gotoCalendarFresh(page);

    const scaffoldTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Common House", exact: true }).click(),
      waitFor: () => page.waitForSelector(SCAFFOLD),
      opened: OPENED.commonHouseNew,
    });

    const formVisibleTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Common House", exact: true }).click(),
      waitFor: () => page.waitForSelector(FORM_VISIBLE),
      opened: OPENED.commonHouseNew,
    });

    const populatedTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Common House", exact: true }).click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.commonHouseNew,
    });

    results["Common House New"] = {
      clickToScaffold: summarize(scaffoldTimings),
      clickToFormVisible: summarize(formVisibleTimings),
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Event — New (sidebar)", async ({ page }) => {
    await gotoCalendarFresh(page);

    const scaffoldTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Event", exact: true }).click(),
      waitFor: () => page.waitForSelector(SCAFFOLD),
      opened: OPENED.eventNew,
    });

    // Event New has no data dependency, so populated = form-visible.
    const populatedTimings = await bench({
      page,
      setupIteration: () => gotoCalendarFresh(page),
      action: () =>
        page.getByRole("button", { name: "Event", exact: true }).click(),
      waitFor: () => page.waitForSelector(POPULATED_EVENT_NEW),
      opened: OPENED.eventNew,
    });

    results["Event New"] = {
      clickToScaffold: summarize(scaffoldTimings),
      clickToPopulated: summarize(populatedTimings),
    };
  });

  // --- Warm-cache scenarios (hosts already in store, second+ open) ---

  /**
   * Setup helper for warm scenarios: close the modal if one is open
   * (so the next iteration can open a fresh one). No-op if already
   * closed. Excluded from timing.
   */
  async function closeIfOpen(page) {
    if (await page.locator(".ReactModal__Content--after-open").count()) {
      await closeModal(page);
    }
  }

  test("Guest Room — Edit (warm cache)", async ({ page }) => {
    await gotoCalendarFresh(page);
    // Prime the hosts cache by opening + closing once.
    await guestRoomTile(page).click();
    await page.waitForSelector(POPULATED_WITH_DATA);
    await expect(page).toHaveURL(OPENED.guestRoomEdit);
    await closeModal(page);

    const populatedTimings = await bench({
      page,
      setupIteration: () => closeIfOpen(page),
      action: () => guestRoomTile(page).click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.guestRoomEdit,
    });

    results["Guest Room Edit (warm)"] = {
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Common House — Edit (warm cache)", async ({ page }) => {
    await gotoCalendarFresh(page);
    await page.locator("text=Book Club").first().click();
    await page.waitForSelector(POPULATED_WITH_DATA);
    await closeModal(page);

    const populatedTimings = await bench({
      page,
      setupIteration: () => closeIfOpen(page),
      action: () => page.locator("text=Book Club").first().click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.commonHouseEdit,
    });

    results["Common House Edit (warm)"] = {
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Guest Room — New (warm cache)", async ({ page }) => {
    await gotoCalendarFresh(page);
    await page.getByRole("button", { name: "Guest Room", exact: true }).click();
    await page.waitForSelector(POPULATED_WITH_DATA);
    await closeModal(page);

    const populatedTimings = await bench({
      page,
      setupIteration: () => closeIfOpen(page),
      action: () =>
        page.getByRole("button", { name: "Guest Room", exact: true }).click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.guestRoomNew,
    });

    results["Guest Room New (warm)"] = {
      clickToPopulated: summarize(populatedTimings),
    };
  });

  test("Common House — New (warm cache)", async ({ page }) => {
    await gotoCalendarFresh(page);
    await page
      .getByRole("button", { name: "Common House", exact: true })
      .click();
    await page.waitForSelector(POPULATED_WITH_DATA);
    await closeModal(page);

    const populatedTimings = await bench({
      page,
      setupIteration: () => closeIfOpen(page),
      action: () =>
        page.getByRole("button", { name: "Common House", exact: true }).click(),
      waitFor: () => page.waitForSelector(POPULATED_WITH_DATA),
      opened: OPENED.commonHouseNew,
    });

    results["Common House New (warm)"] = {
      clickToPopulated: summarize(populatedTimings),
    };
  });
});
