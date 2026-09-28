import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import { useDeviceZone } from "../helpers/device_zone.js";

// The community is in Los Angeles (the cookie fixture) and the device
// is somewhere else: a resident on a trip, or a tablet whose zone was
// never set. The timer must roll "today" over one second after each
// community midnight, and at no other time, whatever the device's zone
// (#122). With dayjs, a device in Hawaii set the fall-back night's
// timer an hour late, and in the last hour before the spring-forward
// day the wait came out negative, so the timer fired, set itself again
// and fired again with no pause: 1001 month fetches in one second.
//
// Los Angeles changes its clocks at 2am on Mar 8 and Nov 1, 2026.
// Europe and Greenland change theirs at 01:00 UTC on Mar 29 and Oct 25.
describe.each([
  // Behind the community, without and with DST.
  "Pacific/Honolulu",
  "America/Anchorage",
  // The community's own zone.
  "America/Los_Angeles",
  // Ahead, with the same DST dates.
  "America/Chicago",
  "America/New_York",
  "UTC",
  // Ahead, with other DST dates. Greenland's clocks skip from 23:00 to
  // midnight on Saturday, Mar 28.
  "Europe/London",
  "America/Nuuk",
  // Far ahead, no DST.
  "Asia/Tokyo",
])("the midnight timer on a device in %s", (deviceZone) => {
  useDeviceZone(deviceZone);

  let store;
  let loadMonthAsync;

  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    vi.stubEnv("VITE_PUSHER_CLUSTER", "us2");
    vi.useFakeTimers();
  });

  afterEach(() => {
    store.beforeDestroy();
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  // A store made at `start` with the calendar on screen, so each
  // rollover also fetches the month.
  function startAt(start) {
    vi.setSystemTime(new Date(start));
    store = createDataStore();
    loadMonthAsync = stubAction(store, "loadMonthAsync");
    window.Comeals.calendarChannel = { name: "calendar on screen" };
  }

  // Run the fake clock, and every timer due, up to `instant`.
  function runUntil(instant) {
    vi.advanceTimersByTime(Date.parse(instant) - Date.now());
  }

  // One millisecond before one second past midnight nothing has fired;
  // at one second past, the day has rolled over with one fetch.
  function expectRolloverAt(midnight, before, after, fetches) {
    const oneSecondPast = Date.parse(midnight) + 1000;
    runUntil(new Date(oneSecondPast - 1).toISOString());
    expect(store.communityToday).toBe(before);
    expect(loadMonthAsync).toHaveBeenCalledTimes(fetches - 1);
    runUntil(new Date(oneSecondPast).toISOString());
    expect(store.communityToday).toBe(after);
    expect(loadMonthAsync).toHaveBeenCalledTimes(fetches);
  }

  it("rolls over at midnight on the fall-back night, and after the 25-hour day", () => {
    startAt("2026-10-31T23:59:00-07:00");
    expect(store.communityToday).toBe("2026-10-31");

    expectRolloverAt(
      "2026-11-01T00:00:00-07:00",
      "2026-10-31",
      "2026-11-01",
      1,
    );
    expectRolloverAt(
      "2026-11-02T00:00:00-08:00",
      "2026-11-01",
      "2026-11-02",
      2,
    );
  });

  it("rolls over once in the last hour before the spring-forward day, and after the 23-hour day", () => {
    startAt("2026-03-07T23:30:00-08:00");
    expect(store.communityToday).toBe("2026-03-07");

    expectRolloverAt(
      "2026-03-08T00:00:00-08:00",
      "2026-03-07",
      "2026-03-08",
      1,
    );
    expectRolloverAt(
      "2026-03-09T00:00:00-07:00",
      "2026-03-08",
      "2026-03-09",
      2,
    );
  });

  // In Greenland this is the hour the device's own clock skips.
  it("knows today at 23:30 on Mar 28, and rolls over at midnight", () => {
    startAt("2026-03-28T23:30:00-07:00");
    expect(store.communityToday).toBe("2026-03-28");

    expectRolloverAt(
      "2026-03-29T00:00:00-07:00",
      "2026-03-28",
      "2026-03-29",
      1,
    );
  });

  it("rolls over at the community's midnight on the nights Europe and Greenland change their clocks", () => {
    // 17:00 in Los Angeles is midnight UTC, an hour before those changes.
    startAt("2026-03-28T17:00:00-07:00");
    expectRolloverAt(
      "2026-03-29T00:00:00-07:00",
      "2026-03-28",
      "2026-03-29",
      1,
    );

    vi.setSystemTime(new Date("2026-10-24T17:00:00-07:00"));
    store.recomputeCommunityToday();
    store.scheduleMidnightRecompute();
    expectRolloverAt(
      "2026-10-25T00:00:00-07:00",
      "2026-10-24",
      "2026-10-25",
      2,
    );
  });
});
