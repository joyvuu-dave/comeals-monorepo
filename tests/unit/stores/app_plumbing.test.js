import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The app-wide plumbing in data_store_app.js and the calendar channel
// in data_store_calendar.js: the socket id, the 401 interceptor, the
// reconnect repairs, the timers the store clears when it goes, and
// what a push on the month channel does. The reconnect refetches
// themselves are in data_store.test.js ("Pusher reconnect recovery").

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import axios from "axios";
import { destroy } from "mobx-state-tree";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";

const COMMUNITY = "test-community-id";

function calendarData() {
  return {
    id: COMMUNITY,
    year: 2026,
    month: 4,
    meals: [],
    bills: [],
    rotations: [],
    birthdays: [],
    common_house_reservations: [],
    guest_room_reservations: [],
    events: [{ id: 1, title: "Work day" }],
  };
}

// The store binds its connection handlers on the pusherClient facade,
// which replays them onto the (mock) Pusher once its dynamic import
// lands. Flush until the handler for `event` is there, then return it.
async function connectionHandler(event) {
  const Pusher = (await import("pusher-js")).default;
  function calls() {
    const instance = Pusher.instances[Pusher.instances.length - 1];
    if (!instance) return [];
    return instance.connection.bind.mock.calls.filter(([e]) => e === event);
  }
  // Not a fixed number of microtask turns: the dynamic import takes more of
  // them on a slow runner, and CI was red for two days with "Cannot read
  // properties of undefined" here (2026-09-08 to 2026-09-10). waitFor polls
  // until the handler is bound, and advances fake timers when a test uses
  // them.
  await vi.waitFor(() => {
    if (calls().length === 0)
      throw new Error("connection handler not bound yet");
  });
  return calls()[calls().length - 1][1];
}

describe("app plumbing", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("keeps the socket id once the connection says connected", async () => {
    createDataStore();
    const handler = await connectionHandler("connected");
    expect(window.Comeals.socketId).toBeNull();

    handler();

    expect(window.Comeals.socketId).toBe("test-socket");
  });

  describe("the response interceptor", () => {
    function interceptor() {
      const calls = axios.interceptors.response.use.mock.calls;
      return calls[calls.length - 1];
    }

    it("passes a response through untouched", () => {
      createDataStore();
      const [onResponse] = interceptor();
      const response = { status: 200, data: {} };

      expect(onResponse(response)).toBe(response);
    });

    it("marks the session expired on a 401 and still rejects", async () => {
      const store = createDataStore();
      const [, onError] = interceptor();
      const error = { response: { status: 401 } };

      await expect(onError(error)).rejects.toBe(error);
      expect(store.authExpired).toBe(true);
    });

    it("leaves the session alone on any other failure", async () => {
      const store = createDataStore();
      const [, onError] = interceptor();

      await expect(
        onError({ response: { status: 500 } }),
      ).rejects.toBeDefined();
      await expect(onError(new Error("network"))).rejects.toBeDefined();
      expect(store.authExpired).toBe(false);
    });

    it("is installed once: a second store ejects the first one's", () => {
      axios.interceptors.response.use.mockReturnValueOnce(7);
      createDataStore();
      createDataStore();

      expect(axios.interceptors.response.eject).toHaveBeenCalledWith(7);
    });
  });

  describe("handleReconnect", () => {
    it("refreshes the hosts list when one was loaded", () => {
      const store = createDataStore();
      stage(store, () => {
        store.hostsLoadedAt = Date.now();
      });
      const refetch = stubAction(store, "refetchHostsSilently");
      stubAction(store, "loadMonthAsync");

      store.handleReconnect();

      expect(refetch).toHaveBeenCalledTimes(1);
    });

    it("does not refetch a meal when no meal is on screen", () => {
      const store = createDataStore();
      stage(store, () => {
        store.meal = null;
      });
      const loadDataAsync = stubAction(store, "loadDataAsync");
      stubAction(store, "loadMonthAsync");

      store.handleReconnect();

      expect(loadDataAsync).not.toHaveBeenCalled();
    });
  });

  it("clears its timers when destroyed", () => {
    vi.useFakeTimers();
    const store = createDataStore();
    store.scheduleMealRetry(1);
    const before = vi.getTimerCount();
    expect(before).toBeGreaterThanOrEqual(2);

    destroy(store);

    expect(vi.getTimerCount()).toBe(before - 2);
  });

  it("destroys cleanly when no timer is pending", () => {
    vi.useFakeTimers();
    const store = createDataStore();
    stage(store, () => {
      clearTimeout(store.midnightTimer);
      store.midnightTimer = null;
    });
    const before = vi.getTimerCount();

    destroy(store);

    expect(vi.getTimerCount()).toBe(before);
  });

  it("logs out locally even when the server-side revocation fails", async () => {
    const store = createDataStore();
    const Cookie = (await import("js-cookie")).default;
    axios.delete.mockRejectedValueOnce(new Error("offline"));

    store.logout();
    await new Promise((r) => setTimeout(r, 0));

    expect(axios.delete).toHaveBeenCalledWith("/api/v1/sessions/current", {
      headers: { Authorization: "Bearer test-token" },
    });
    expect(Cookie.remove).toHaveBeenCalledWith("token", { path: "/" });
    expect(Cookie.remove).toHaveBeenCalledWith("community_id", { path: "/" });
  });

  describe("the month channel", () => {
    function storeWithChannels() {
      const store = createDataStore();
      const channels = new Map();
      window.Comeals.pusher.subscribe = vi.fn((name) => {
        const channel = { name, bind: vi.fn() };
        channels.set(name, channel);
        return channel;
      });
      window.Comeals.pusher.unsubscribe = vi.fn();
      return { store, channels };
    }

    it("refetches the month on screen when the channel says update", () => {
      const { store, channels } = storeWithChannels();
      store.loadMonth(calendarData());
      const loadMonthAsync = stubAction(store, "loadMonthAsync");

      // The channel is named for the month on screen (store.currentDate,
      // today by default), not for the payload's month.
      const channel = [...channels.values()].find((c) =>
        c.name.startsWith(`community-${COMMUNITY}-calendar-`),
      );
      const update = channel.bind.mock.calls.find(([e]) => e === "update");
      update[1]();

      expect(loadMonthAsync).toHaveBeenCalledTimes(1);
    });

    it("clearCalendarEvents empties the events and bumps the version", () => {
      const { store } = storeWithChannels();
      store.loadMonth(calendarData());
      const version = store.calendarEventsVersion;
      expect(store.calendarEvents.length).toBe(1);

      store.clearCalendarEvents();

      expect(store.calendarEvents.length).toBe(0);
      expect(store.calendarEventsVersion).toBe(version + 1);
    });
  });
});
