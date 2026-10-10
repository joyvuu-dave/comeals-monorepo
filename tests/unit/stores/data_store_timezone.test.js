import {
  describe,
  it,
  expect,
  beforeEach,
  afterEach,
  onTestFinished,
  vi,
} from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import Cookie, { cookies } from "../mocks/js_cookie.js";
import * as monthCache from "../../../app/frontend/src/stores/month_cache.js";
import {
  invalidateMonth,
  prefetchMonth,
} from "../../../app/frontend/src/stores/month_fetch.js";
import { pusherClient } from "../../../app/frontend/src/helpers/pusher_client.js";
import { createDataStore } from "../helpers/create_data_store.js";

// The community's time zone reaches the SPA once, as a cookie written at
// login, and every time on screen and "today" are computed from it. When
// the admin changes the zone, every open tab keeps the old one until the
// person logs out and in (frontend-seam hunt, 2026-08-25). So each month
// the server sends carries the zone, and the store takes it from there.
//
// Only an answer from the server sets the zone, never a copy of a month
// kept in memory or on disk (IndexedDB). A copy saved before the admin
// changed the zone still holds the old one. A tab that was closed or
// offline at the change keeps its copies, and showing one of them first
// would move "today" and every time back to the old zone until the
// server's answer came, or for good if that fetch failed.
describe("DataStore: the community time zone", () => {
  const COMMUNITY = "test-community-id";
  const JULY = monthCache.keyFor(COMMUNITY, "2026", "7");
  // A meal on July 8: 18:00 in Los Angeles, 21:00 in New York.
  const JULY_MEAL = {
    title: "Dinner",
    start: "2026-07-09T01:00:00Z",
    end: "2026-07-09T02:30:00Z",
  };

  beforeEach(() => {
    vi.clearAllMocks();
    monthCache.clear();
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    vi.stubEnv("VITE_PUSHER_CLUSTER", "us2");
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    idbKeyval.get.mockImplementation(() => Promise.resolve(undefined));
    axios.get.mockImplementation(() =>
      Promise.resolve({ status: 200, data: {} }),
    );
  });

  // July 2026, as the server sends it and as the copies keep it.
  function monthPayload(overrides = {}) {
    return {
      id: COMMUNITY,
      year: 2026,
      month: 7,
      meals: [],
      bills: [],
      rotations: [],
      birthdays: [],
      common_house_reservations: [],
      guest_room_reservations: [],
      events: [],
      ...overrides,
    };
  }

  // The server answers every month request with this answer.
  function serverAnswers(answer) {
    axios.get.mockImplementation(() =>
      Promise.resolve({ status: 200, data: answer }),
    );
  }

  // The server has not answered yet. Hands back the function that
  // answers.
  function serverWaits() {
    let answer;
    axios.get.mockImplementation(
      () =>
        new Promise((resolve) => {
          answer = (data) => resolve({ status: 200, data });
        }),
    );
    return (data) => answer(data);
  }

  // Lets every promise that is ready run. Promises only, no timers, so
  // it works with fake timers too.
  async function settle() {
    for (let i = 0; i < 50; i++) await Promise.resolve();
  }

  // The person goes to July. With no copy, the month comes from the
  // server.
  async function showJuly(store) {
    store.switchMonths("2026-07-15");
    await settle();
  }

  describe("a month the server sends", () => {
    // The fixture cookie says Los Angeles. The cookie mock keeps what
    // the store writes, so what the store reads next is the new zone.
    it("sets the zone it carries", async () => {
      serverAnswers(monthPayload({ timezone: "America/New_York" }));
      const store = createDataStore();

      await showJuly(store);

      // Twenty years, like the login cookie: without `expires` the zone
      // would be gone when the browser closes.
      expect(Cookie.set).toHaveBeenCalledWith("timezone", "America/New_York", {
        expires: 7300,
      });
      expect(Cookie.get("timezone")).toBe("America/New_York");
    });

    it("moves today to the new zone at once", async () => {
      vi.useFakeTimers();
      // 23:30 in Los Angeles on July 8 is 02:30 on July 9 in New York.
      vi.setSystemTime(new Date("2026-07-08T23:30:00-07:00"));
      serverAnswers(monthPayload({ timezone: "America/New_York" }));
      const store = createDataStore();
      expect(store.communityToday).toBe("2026-07-08");

      await showJuly(store);

      expect(store.communityToday).toBe("2026-07-09");
    });

    it("reads its own event times in the new zone", async () => {
      // 01:00 UTC is 21:00 the day before in New York (18:00 in Los
      // Angeles). The zone is set before the events are read.
      serverAnswers(
        monthPayload({
          timezone: "America/New_York",
          meals: [
            {
              title: "Dinner",
              start: "2026-07-09T01:00:00Z",
              end: "2026-07-09T02:30:00Z",
            },
          ],
        }),
      );
      const store = createDataStore();

      await showJuly(store);

      const [meal] = store.calendarEvents;
      expect(meal.start.getDate()).toBe(8);
      expect(meal.start.getHours()).toBe(21);
      expect(meal.end.getHours()).toBe(22);
      expect(meal.end.getMinutes()).toBe(30);
    });

    it("moves the midnight timer to the new zone's midnight", async () => {
      vi.useFakeTimers();
      // 20:00 in Los Angeles is 23:00 in New York, both on July 8. New
      // York's midnight comes three hours before the Los Angeles one the
      // timer was waiting for, so a timer left on the old zone would
      // keep July 8 on screen for three hours of July 9.
      vi.setSystemTime(new Date("2026-07-08T20:00:00-07:00"));
      serverAnswers(monthPayload({ timezone: "America/New_York" }));
      const store = createDataStore();

      await showJuly(store);
      expect(store.communityToday).toBe("2026-07-08");

      // The timer fires one second past New York midnight.
      const toNewYorkMidnight = 60 * 60 * 1000 + 1000;
      vi.advanceTimersByTime(toNewYorkMidnight - 1);
      expect(store.communityToday).toBe("2026-07-08");
      vi.advanceTimersByTime(1);
      expect(store.communityToday).toBe("2026-07-09");
    });

    it("leaves the cookie alone when it carries the zone the cookie has", async () => {
      serverAnswers(monthPayload({ timezone: "America/Los_Angeles" }));
      const store = createDataStore();

      await showJuly(store);

      expect(Cookie.set).not.toHaveBeenCalled();
    });

    it("keeps the zone the cookie has when it carries none", async () => {
      serverAnswers(monthPayload());
      const store = createDataStore();

      await showJuly(store);

      expect(Cookie.set).not.toHaveBeenCalled();
      expect(Cookie.get("timezone")).toBe("America/Los_Angeles");
    });

    // The boot-time prefetch, or a month next to the one on screen.
    it("sets the zone when a prefetch brings it", async () => {
      serverAnswers(monthPayload({ timezone: "America/New_York" }));
      createDataStore();

      prefetchMonth("2026-07-15");
      await settle();

      expect(Cookie.get("timezone")).toBe("America/New_York");
    });

    // A month next to the one on screen can bring the new zone first.
    // Here July is drawn from its copy on disk, in Los Angeles time, and
    // July's own fetch fails, so only the prefetches of June and August
    // answer. The month on screen is drawn again in the new zone, from
    // the copy in memory: a copy holds exact instants, so only how it is
    // drawn was out of date.
    it("draws the month on screen again when a prefetch brings a new zone", async () => {
      idbKeyval.get.mockImplementation((key) =>
        Promise.resolve(
          key === JULY
            ? monthPayload({
                timezone: "America/Los_Angeles",
                meals: [JULY_MEAL],
              })
            : undefined,
        ),
      );
      axios.get.mockImplementation((url) => {
        if (url.endsWith("/calendar/2026-07-15")) {
          return Promise.reject({
            response: { status: 409, data: { message: "Try again." } },
          });
        }
        const month = url.endsWith("/calendar/2026-06-15") ? 6 : 8;
        return Promise.resolve({
          status: 200,
          data: monthPayload({ month, timezone: "America/New_York" }),
        });
      });
      vi.spyOn(console, "error").mockImplementation(() => {});
      const store = createDataStore();

      await showJuly(store);

      expect(Cookie.get("timezone")).toBe("America/New_York");
      const [meal] = store.calendarEvents;
      expect(meal.start.getDate()).toBe(8);
      expect(meal.start.getHours()).toBe(21);
      expect(meal.end.getHours()).toBe(22);
    });

    // The answer that brings the new zone can come after the person
    // left the calendar for a meal page. Then only the events are drawn
    // again. The meal page closed the calendar's channels (#38), so they
    // stay closed, and nothing is fetched again.
    it("draws only the events again when the new zone comes on a meal page", async () => {
      monthCache.set(
        JULY,
        monthPayload({ timezone: "America/Los_Angeles", meals: [JULY_MEAL] }),
      );
      // Each month request waits until the test answers it.
      const answers = {};
      axios.get.mockImplementation(
        (url) =>
          new Promise((resolve) => {
            answers[url.slice(-"2026-08-15".length)] = (data) =>
              resolve({ status: 200, data });
          }),
      );
      const store = createDataStore();
      await showJuly(store);
      store.teardownCalendarPage();
      const subscribe = vi.spyOn(pusherClient, "subscribe");
      onTestFinished(() => subscribe.mockRestore());
      const requests = axios.get.mock.calls.length;

      answers["2026-08-15"](
        monthPayload({ month: 8, timezone: "America/New_York" }),
      );
      await settle();

      expect(Cookie.get("timezone")).toBe("America/New_York");
      expect(store.calendarEvents[0].start.getHours()).toBe(21);
      expect(subscribe).not.toHaveBeenCalled();
      expect(axios.get).toHaveBeenCalledTimes(requests);
    });

    // The version check drops a prefetch's answer when a push said the
    // month changed while it was on the wire. The answer was read before
    // the change, so its zone may be old too.
    it("does not set the zone when a push dropped the prefetch's answer", async () => {
      const answer = serverWaits();
      createDataStore();
      prefetchMonth("2026-07-15");
      await settle();

      invalidateMonth(COMMUNITY, "2026", "7");
      answer(monthPayload({ timezone: "America/New_York" }));
      await settle();

      expect(Cookie.get("timezone")).toBe("America/Los_Angeles");
    });
  });

  // The admin changed the zone from Los Angeles to New York while this
  // tab was closed. The tab has since had a fresh answer, so the cookie
  // says New York, but its copies of July still say Los Angeles.
  describe("a copy of a month", () => {
    beforeEach(() => {
      cookies.current.timezone = "America/New_York";
    });

    it("from disk does not change the zone", async () => {
      idbKeyval.get.mockResolvedValue(
        monthPayload({ timezone: "America/Los_Angeles" }),
      );
      const answer = serverWaits();
      const store = createDataStore();

      await showJuly(store);

      expect(store.monthLoading).toBe(false);
      expect(Cookie.get("timezone")).toBe("America/New_York");
      expect(Cookie.set).not.toHaveBeenCalled();

      answer(monthPayload({ timezone: "America/New_York" }));
      await settle();
      expect(Cookie.get("timezone")).toBe("America/New_York");
    });

    it("from disk does not change the zone when the server never answers", async () => {
      idbKeyval.get.mockResolvedValue(
        monthPayload({ timezone: "America/Los_Angeles" }),
      );
      serverWaits();
      vi.useFakeTimers();
      // 00:30 on July 9 in New York is 21:30 on July 8 in Los Angeles.
      // A copy that set the zone back to Los Angeles would move today
      // back to July 8, and with no answer it would stay there.
      vi.setSystemTime(new Date("2026-07-09T00:30:00-04:00"));
      const store = createDataStore();
      expect(store.communityToday).toBe("2026-07-09");

      await showJuly(store);

      expect(store.communityToday).toBe("2026-07-09");
    });

    it("from memory does not change the zone", async () => {
      monthCache.set(JULY, monthPayload({ timezone: "America/Los_Angeles" }));
      serverWaits();
      const store = createDataStore();

      await showJuly(store);

      expect(store.monthLoading).toBe(false);
      expect(Cookie.get("timezone")).toBe("America/New_York");
      expect(Cookie.set).not.toHaveBeenCalled();
    });
  });
});
