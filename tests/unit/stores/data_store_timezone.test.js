import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import Cookie from "js-cookie";
import { createDataStore } from "../helpers/create_data_store.js";

// The community's time zone reaches the SPA once, as a cookie written at
// login, and every time on screen and "today" are computed from it. When
// the admin changes the zone, every open tab keeps the old one until the
// person logs out and in (frontend-seam hunt, 2026-08-25). The month
// payload carries the zone, and the store adopts it whenever a month
// loads, so a refetch (which a zone change pushes) is enough.
describe("DataStore: the community time zone", () => {
  beforeEach(() => {
    vi.clearAllMocks();
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
  });

  function monthPayload(overrides = {}) {
    return {
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

  // The fixture cookie says Los Angeles. The cookie mock keeps what the
  // store writes, so what the store reads next is the new zone.
  it("adopts the zone the month payload carries", () => {
    const store = createDataStore();

    store.loadMonth(monthPayload({ timezone: "America/New_York" }));

    // Twenty years, like the login cookie: without `expires` the zone
    // would be gone when the browser closes.
    expect(Cookie.set).toHaveBeenCalledWith("timezone", "America/New_York", {
      expires: 7300,
    });
    expect(Cookie.get("timezone")).toBe("America/New_York");
  });

  it("moves today to the new zone at once", () => {
    vi.useFakeTimers();
    // 23:30 in Los Angeles on July 8 is 02:30 on July 9 in New York.
    vi.setSystemTime(new Date("2026-07-08T23:30:00-07:00"));
    const store = createDataStore();
    expect(store.communityToday).toBe("2026-07-08");

    store.loadMonth(monthPayload({ timezone: "America/New_York" }));

    expect(store.communityToday).toBe("2026-07-09");
  });

  it("reads the same payload's event times in the new zone", () => {
    const store = createDataStore();

    // 01:00 UTC is 21:00 the day before in New York (18:00 in Los
    // Angeles). The zone is adopted before the events are read.
    store.loadMonth(
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

    const [meal] = store.calendarEvents;
    expect(meal.start.getDate()).toBe(8);
    expect(meal.start.getHours()).toBe(21);
    expect(meal.end.getHours()).toBe(22);
    expect(meal.end.getMinutes()).toBe(30);
  });

  it("moves the midnight timer to the new zone's midnight", () => {
    vi.useFakeTimers();
    // 20:00 in Los Angeles is 23:00 in New York, both on July 8. New
    // York's midnight comes three hours before the Los Angeles one the
    // timer was waiting for, so a timer left on the old zone would keep
    // July 8 on screen for three hours of July 9.
    vi.setSystemTime(new Date("2026-07-08T20:00:00-07:00"));
    const store = createDataStore();

    store.loadMonth(monthPayload({ timezone: "America/New_York" }));
    expect(store.communityToday).toBe("2026-07-08");

    // The timer fires one second past New York midnight.
    const toNewYorkMidnight = 60 * 60 * 1000 + 1000;
    vi.advanceTimersByTime(toNewYorkMidnight - 1);
    expect(store.communityToday).toBe("2026-07-08");
    vi.advanceTimersByTime(1);
    expect(store.communityToday).toBe("2026-07-09");
  });

  it("leaves the cookie alone when the payload's zone is the one it has", () => {
    const store = createDataStore();

    store.loadMonth(monthPayload({ timezone: "America/Los_Angeles" }));

    expect(Cookie.set).not.toHaveBeenCalled();
  });

  // A month cached in IndexedDB before the payload carried a zone.
  it("keeps the zone it has when the payload carries none", () => {
    const store = createDataStore();

    store.loadMonth(monthPayload());

    expect(Cookie.set).not.toHaveBeenCalled();
    expect(Cookie.get("timezone")).toBe("America/Los_Angeles");
  });
});
