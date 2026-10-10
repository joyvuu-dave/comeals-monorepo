import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The calendar's Pusher subscriptions through the real pusherClient
// (helpers/pusher_client.js), which hands back one wrapper per channel
// name. The other store tests replace pusherClient.subscribe with a
// mock that makes a new object on every call, so they cannot see two
// callers sharing one channel. Only pusher-js itself is faked here, by
// a class that keeps channels by name the way pusher-js does.
//
// pusherClient keeps its connection at module level, so every test
// loads the store's modules fresh (the same way as
// month_cache_integration.test.js).

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

const COMMUNITY = "test-community-id";
const RESIDENTS = `community-${COMMUNITY}-residents`;

function monthChannel(year, month) {
  return `community-${COMMUNITY}-calendar-${year}-${month}`;
}

// What pusher-js does with channels: subscribe returns the channel
// already open under that name, and unsubscribe closes it, bindings
// and all. `opened` lists every channel opened, in order. (subscribe
// itself runs more often than that: pusherClient's bind looks the
// channel up with it.)
function FakePusher() {
  this.connection = { bind: vi.fn(), socket_id: "socket-1" };
  this.open = new Map();
  this.opened = [];
  this.subscribe = vi.fn((name) => {
    if (!this.open.has(name)) {
      this.open.set(name, { name, bind: vi.fn() });
      this.opened.push(name);
    }
    return this.open.get(name);
  });
  this.unsubscribe = vi.fn((name) => {
    this.open.delete(name);
  });
  FakePusher.instance = this;
}

// Runs every handler an open channel bound for `event`, the way Pusher
// delivers a push ("update") or confirms a subscription
// ("pusher:subscription_succeeded").
function fire(name, event) {
  const channel = FakePusher.instance.open.get(name);
  expect(channel, `${name} is not open`).toBeDefined();
  channel.bind.mock.calls
    .filter(([bound]) => bound === event)
    .forEach(([, handler]) => handler());
}

function handlersFor(name, event) {
  return FakePusher.instance.open
    .get(name)
    .bind.mock.calls.filter(([bound]) => bound === event);
}

function openNames() {
  return [...FakePusher.instance.open.keys()].sort();
}

function timesOpened(name) {
  return FakePusher.instance.opened.filter((opened) => opened === name).length;
}

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

async function flush() {
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 0));
  }
}

describe("calendar channels through the real Pusher client", () => {
  let DataStore;
  let axios;
  let monthCache;
  // The server's months, a title per "year-month".
  let titles;

  function fetchesOf(year, month) {
    const suffix = `/calendar/${year}-${String(month).padStart(2, "0")}-15`;
    return axios.get.mock.calls.filter(([url]) => url.endsWith(suffix)).length;
  }

  // July 2024 on screen, June and August open and prefetched.
  async function julyOnScreen() {
    const store = DataStore.create({ meals: [] });
    store.switchMonths("2024-07-15");
    await flush();
    return store;
  }

  beforeEach(async () => {
    vi.clearAllMocks();
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    window.Pusher = FakePusher;
    vi.resetModules();
    ({ DataStore } =
      await import("../../../app/frontend/src/stores/data_store.js"));
    monthCache =
      await import("../../../app/frontend/src/stores/month_cache.js");
    axios = (await import("axios")).default;
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    titles = new Map();
    axios.get.mockImplementation((url) => {
      const m = url.match(/\/calendar\/(\d{4})-(\d{2})-\d{2}$/);
      const year = Number(m[1]);
      const month = Number(m[2]);
      const title = titles.get(`${year}-${month}`) || `${year}-${month}`;
      return Promise.resolve({
        status: 200,
        data: calendarData(year, month, title),
      });
    });
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    delete window.Pusher;
  });

  // Moving to a neighbour within 5 seconds of its prefetch draws the
  // prefetched copy and runs loadMonth once. The neighbour clean-up used
  // to close every old neighbour, and that included the month that had
  // just come on screen (#112).
  it("keeps the month on screen subscribed after moving to a neighbouring month", async () => {
    const store = await julyOnScreen();

    store.switchMonths("2024-08-15");
    await flush();

    expect(openNames()).toEqual([
      monthChannel(2024, 7),
      monthChannel(2024, 8),
      monthChannel(2024, 9),
      RESIDENTS,
    ]);
    // Only the channel no longer needed was closed, and each channel
    // was opened once.
    expect(FakePusher.instance.unsubscribe.mock.calls).toEqual([
      [monthChannel(2024, 6)],
    ]);
    [7, 8, 9].forEach((month) => {
      expect(timesOpened(monthChannel(2024, month))).toBe(1);
    });
  });

  it("moving from December to January keeps both open, across the year", async () => {
    const store = DataStore.create({ meals: [] });
    store.switchMonths("2024-12-15");
    await flush();

    store.switchMonths("2025-01-15");
    await flush();

    expect(openNames()).toEqual([
      monthChannel(2024, 12),
      monthChannel(2025, 1),
      monthChannel(2025, 2),
      RESIDENTS,
    ]);
    expect(FakePusher.instance.unsubscribe.mock.calls).toEqual([
      [monthChannel(2024, 11)],
    ]);
  });

  it("moving far away closes the three old months and opens the three new ones", async () => {
    const store = await julyOnScreen();

    store.switchMonths("2024-10-15");
    await flush();

    expect(openNames()).toEqual([
      monthChannel(2024, 10),
      monthChannel(2024, 11),
      monthChannel(2024, 9),
      RESIDENTS,
    ]);
    expect(
      FakePusher.instance.unsubscribe.mock.calls.map(([name]) => name).sort(),
    ).toEqual([
      monthChannel(2024, 6),
      monthChannel(2024, 7),
      monthChannel(2024, 8),
    ]);
  });

  // A channel closed and opened again on every refetch would miss any
  // push sent in between, and its confirmation would fetch again, and
  // again.
  it("a refetch of the month on screen keeps its channel open", async () => {
    await julyOnScreen();
    titles.set("2024-7", "July, changed");

    fire(monthChannel(2024, 7), "update");
    await flush();

    expect(FakePusher.instance.unsubscribe).not.toHaveBeenCalled();
    expect(timesOpened(monthChannel(2024, 7))).toBe(1);
  });

  it("each channel has one handler per event, whatever roles its month moved through", async () => {
    const store = await julyOnScreen();
    store.switchMonths("2024-08-15");
    await flush();
    store.switchMonths("2024-07-15");
    await flush();

    [7, 8].forEach((month) => {
      const name = monthChannel(2024, month);
      expect(handlersFor(name, "update")).toHaveLength(1);
      expect(handlersFor(name, "pusher:subscription_succeeded")).toHaveLength(
        1,
      );
    });
  });

  // August's channel was opened as a neighbour. Its handler decides
  // what to do when it fires, so once August is on screen a push
  // fetches it.
  it("a push for a neighbour that came on screen fetches it", async () => {
    const store = await julyOnScreen();
    store.switchMonths("2024-08-15");
    await flush();
    titles.set("2024-8", "August, changed");

    fire(monthChannel(2024, 8), "update");
    await flush();

    expect(store.calendarEvents[0].title).toBe("August, changed");
  });

  it("a push for the month that went off screen drops its copy and fetches nothing", async () => {
    const store = await julyOnScreen();
    store.switchMonths("2024-08-15");
    await flush();
    const julyKey = monthCache.keyFor(COMMUNITY, "2024", "7");
    expect(monthCache.get(julyKey)).toBeDefined();
    const fetches = axios.get.mock.calls.length;

    fire(monthChannel(2024, 7), "update");
    await flush();

    expect(monthCache.get(julyKey)).toBeUndefined();
    expect(axios.get.mock.calls.length).toBe(fetches);
    expect(store.calendarEvents[0].title).toBe("2024-8");
  });

  // A push sent before Pusher confirmed the subscription reached no
  // one. The month on screen may have been read before that, so the
  // confirmation fetches it once more (#112). A neighbour's
  // confirmation does not: its prefetched copy stays.
  it("Pusher's confirmation fetches the month on screen once more, and leaves a neighbour's copy alone", async () => {
    const store = await julyOnScreen();
    const juneKey = monthCache.keyFor(COMMUNITY, "2024", "6");
    expect(monthCache.get(juneKey)).toBeDefined();
    const julyFetches = fetchesOf(2024, 7);
    const juneFetches = fetchesOf(2024, 6);
    titles.set("2024-7", "July, changed");

    fire(monthChannel(2024, 7), "pusher:subscription_succeeded");
    fire(monthChannel(2024, 6), "pusher:subscription_succeeded");
    await flush();

    expect(fetchesOf(2024, 7)).toBe(julyFetches + 1);
    expect(store.calendarEvents[0].title).toBe("July, changed");
    expect(fetchesOf(2024, 6)).toBe(juneFetches);
    expect(monthCache.get(juneKey)).toBeDefined();
  });

  // Logout removes the session cookies just before the page loads "/"
  // again. A copy of the month read from the device after that is still
  // drawn, but a channel opened then was named for the community
  // "undefined" (#153).
  it("opens no channel when a copy on disk is drawn after the session ended", async () => {
    const idbKeyval = await import("idb-keyval");
    const Cookie = (await import("js-cookie")).default;
    let readEnds;
    idbKeyval.get.mockImplementationOnce(
      () => new Promise((resolve) => (readEnds = resolve)),
    );
    const store = DataStore.create({ meals: [] });

    store.switchMonths("2024-07-15");
    Cookie.remove("token");
    Cookie.remove("community_id");
    readEnds(calendarData(2024, 7, "July"));
    await flush();

    expect(store.calendarEvents[0].title).toBe("July");
    expect(FakePusher.instance.opened).toEqual([]);
    expect(axios.get).not.toHaveBeenCalled();
  });
});
