import { describe, it, expect, beforeEach, vi } from "vitest";

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

  it("adopts the zone the month payload carries", () => {
    const store = createDataStore();

    store.loadMonth(monthPayload({ timezone: "America/New_York" }));

    expect(Cookie.set).toHaveBeenCalledWith(
      "timezone",
      "America/New_York",
      expect.anything(),
    );
  });

  it("leaves the cookie alone when the payload's zone is the one it has", () => {
    const store = createDataStore();

    store.loadMonth(monthPayload({ timezone: "America/Los_Angeles" }));

    expect(Cookie.set).not.toHaveBeenCalledWith(
      "timezone",
      expect.anything(),
      expect.anything(),
    );
  });
});
