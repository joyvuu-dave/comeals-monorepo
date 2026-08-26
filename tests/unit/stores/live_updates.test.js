import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { stage } from "../helpers/create_data_store.js";

// The client half of the live-update contract (the server half is
// spec/requests/api/v1/live_update_contract_spec.rb): what the store
// does when a push says something is stale, and the two moments when
// nothing pushes — a response that started before the change, and
// midnight.

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));

// A disk-backed IndexedDB, so a test can prove the copies really go.
vi.mock("idb-keyval", () => {
  const disk = new Map();
  return {
    _disk: disk,
    get: vi.fn((key) =>
      Promise.resolve(disk.has(key) ? disk.get(key) : undefined),
    ),
    set: vi.fn((key, value) => {
      disk.set(key, value);
      return Promise.resolve();
    }),
    del: vi.fn((key) => {
      disk.delete(key);
      return Promise.resolve();
    }),
    clear: vi.fn(() => {
      disk.clear();
      return Promise.resolve();
    }),
  };
});

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import { DataStore } from "../../../app/frontend/src/stores/data_store.js";
import * as monthCache from "../../../app/frontend/src/stores/month_cache.js";
import { prefetchMonth } from "../../../app/frontend/src/stores/month_fetch.js";

const COMMUNITY = "test-community-id";

function calendarData(year, month, title) {
  return {
    id: COMMUNITY,
    year,
    month,
    meals: [],
    bills: [],
    rotations: [],
    birthdays: [],
    common_house_reservations: [],
    guest_room_reservations: [],
    events: [{ id: year * 100 + month, title }],
  };
}

function mealPayload(id, description) {
  return {
    id,
    date: "2024-07-15",
    description,
    closed: false,
    closed_at: null,
    reconciled: false,
    max: null,
    next_id: null,
    prev_id: null,
    residents: [],
    guests: [],
    bills: [],
  };
}

// Pusher channels by name, so a test can fire the handler a channel
// bound — the same thing a real push does.
const channels = new Map();

function fireUpdate(name) {
  const channel = channels.get(name);
  expect(channel, `no subscription to ${name}`).toBeDefined();
  const call = channel.bind.mock.calls.find(([event]) => event === "update");
  call[1]();
}

const RESIDENTS_CHANNEL = `community-${COMMUNITY}-residents`;

function calendarRequests(year, month) {
  const suffix = `/calendar/${year}-${String(month).padStart(2, "0")}-15`;
  return axios.get.mock.calls.filter(([url]) => url.endsWith(suffix)).length;
}

// Serves calendar months from `payloads` (a key per "year-month"), and
// the meal page from `meals` (a key per id).
function serveFrom(payloads, meals) {
  axios.get.mockImplementation((url) => {
    const month = url.match(/\/calendar\/(\d{4})-(\d{2})-\d{2}$/);
    if (month) {
      const key = `${Number(month[1])}-${Number(month[2])}`;
      return Promise.resolve({ status: 200, data: payloads.get(key) });
    }
    const meal = url.match(/\/meals\/(\d+)\/cooks$/);
    if (meal) {
      return Promise.resolve({ status: 200, data: meals.get(meal[1]) });
    }
    return Promise.resolve({ status: 200, data: {} });
  });
}

function createStore() {
  const store = DataStore.create({ meals: [{ id: 1 }], meal: 1 });
  window.Comeals.pusher.subscribe = vi.fn((name) => {
    const channel = { name, bind: vi.fn() };
    channels.set(name, channel);
    return channel;
  });
  window.Comeals.pusher.unsubscribe = vi.fn();
  return store;
}

async function flush() {
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 0));
  }
}

describe("live updates in the store", () => {
  let payloads;
  let meals;

  beforeEach(() => {
    vi.clearAllMocks();
    channels.clear();
    idbKeyval._disk.clear();
    monthCache.clear();
    payloads = new Map([
      ["2024-6", calendarData(2024, 6, "June")],
      ["2024-7", calendarData(2024, 7, "July")],
      ["2024-8", calendarData(2024, 8, "August")],
    ]);
    meals = new Map([["1", mealPayload(1, "Menu v1")]]);
    serveFrom(payloads, meals);
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    window.alert = vi.fn();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("the residents channel", () => {
    it("is subscribed by the calendar, and an update drops every cached month and refetches the one on screen", async () => {
      const store = createStore();
      stage(store, () => {
        store.meal = null;
      });

      store.switchMonths("2024-07-15");
      await vi.waitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      await flush();
      // July on screen, June and August prefetched: three copies in RAM
      // and on disk, all holding residents' names.
      expect(monthCache.size()).toBe(3);
      expect(idbKeyval._disk.size).toBe(3);

      // A resident is renamed. The server pushes the residents channel
      // and the new name is in every month from now on.
      payloads.set("2024-7", calendarData(2024, 7, "July, renamed"));
      payloads.set("2024-8", calendarData(2024, 8, "August, renamed"));
      const julyFetchesBefore = calendarRequests(2024, 7);
      fireUpdate(RESIDENTS_CHANNEL);

      expect(monthCache.size()).toBe(0);
      expect(idbKeyval.clear).toHaveBeenCalled();
      await vi.waitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July, renamed");
      });
      expect(calendarRequests(2024, 7)).toBe(julyFetchesBefore + 1);

      // A neighbour that was prefetched before the change is fetched
      // fresh on the next navigation, not served from a copy.
      store.switchMonths("2024-08-15");
      await vi.waitFor(() => {
        expect(store.calendarEvents[0].title).toBe("August, renamed");
      });
    });

    it("is subscribed by the meal page, and an update refetches the meal", async () => {
      const store = createStore();
      store.loadData(mealPayload(1, "Menu v1"));
      expect(channels.has(RESIDENTS_CHANNEL)).toBe(true);

      meals.set("1", mealPayload(1, "Menu v2"));
      fireUpdate(RESIDENTS_CHANNEL);

      await vi.waitFor(() => {
        expect(store.meal.description).toBe("Menu v2");
      });
    });

    it("is one subscription, however many pages load", async () => {
      const store = createStore();
      store.loadData(mealPayload(1, "Menu v1"));
      store.loadData(mealPayload(1, "Menu v1"));
      store.switchMonths("2024-07-15");
      await vi.waitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });

      const subscriptions = window.Comeals.pusher.subscribe.mock.calls.filter(
        ([name]) => name === RESIDENTS_CHANNEL,
      );
      expect(subscriptions).toHaveLength(1);
    });
  });

  describe("an update for the month on screen", () => {
    it("drops a response that was already on the wire before the change", async () => {
      // The boot-time prefetch of July is slow. While it is on the wire
      // someone changes July on the server, and the push arrives. The
      // prefetch's answer was read before the change: rendering it
      // would show the old month with nothing left to correct it.
      const requests = [];
      axios.get.mockImplementation((url) => {
        if (!/\/calendar\/2024-07-15$/.test(url)) {
          return Promise.resolve({ status: 200, data: {} });
        }
        return new Promise((resolve) => {
          requests.push(resolve);
        });
      });

      prefetchMonth("2024-07-15");
      await flush();
      expect(requests).toHaveLength(1);

      const store = createStore();
      stage(store, () => {
        store.meal = null;
      });
      store.switchMonths("2024-07-15");
      await flush();
      // The navigation adopted the in-flight prefetch instead of
      // starting a second request.
      expect(requests).toHaveLength(1);

      // The push. What the store does here is what a real "update" on
      // the July channel does (data_store_calendar.js).
      store.loadMonthAsync();
      await flush();

      // Now the old answer lands.
      requests[0]({ status: 200, data: calendarData(2024, 7, "July, old") });
      await flush();
      expect(store.calendarEvents.map((e) => e.title)).not.toContain(
        "July, old",
      );

      // And the fresh fetch the push caused lands.
      expect(requests).toHaveLength(2);
      requests[1]({ status: 200, data: calendarData(2024, 7, "July, new") });
      await vi.waitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July, new");
      });
    });
  });

  describe("midnight", () => {
    it("refetches the month on screen when the community's day changes", async () => {
      // 23:59:58 in the fixture community (Pacific). Nothing writes at
      // midnight, so no push comes; the store has to fetch on its own,
      // because the chips' words ("signed up", "attending") come from
      // the server and depend on the day.
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2024-07-15T23:59:58-07:00"));

      const store = createStore();
      stage(store, () => {
        store.meal = null;
      });
      store.switchMonths("2024-07-15");
      await vi.advanceTimersByTimeAsync(0);
      await vi.waitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      const fetchesBefore = calendarRequests(2024, 7);
      expect(store.communityToday).toBe("2024-07-15");

      await vi.advanceTimersByTimeAsync(4000);

      expect(store.communityToday).toBe("2024-07-16");
      expect(calendarRequests(2024, 7)).toBe(fetchesBefore + 1);
    });
  });

  describe("two meal fetches on the wire", () => {
    it("the older response cannot overwrite the newer one", async () => {
      // A reconnect refetch and a Pusher refetch can overlap, and HTTP
      // gives no order: the first request's answer may come last.
      const store = createStore();
      store.loadData(mealPayload(1, "Menu v1"));

      const requests = [];
      axios.get.mockImplementation(
        () =>
          new Promise((resolve) => {
            requests.push(resolve);
          }),
      );

      store.loadDataAsync();
      store.loadDataAsync();
      expect(requests).toHaveLength(2);

      requests[1]({ status: 200, data: mealPayload(1, "Menu v3, newest") });
      await vi.waitFor(() => {
        expect(store.meal.description).toBe("Menu v3, newest");
      });

      requests[0]({ status: 200, data: mealPayload(1, "Menu v2, older") });
      await flush();
      expect(store.meal.description).toBe("Menu v3, newest");
      // Nor does the older answer reach the cache for the next visit.
      expect(idbKeyval._disk.get("1").description).toBe("Menu v3, newest");
    });
  });
});
