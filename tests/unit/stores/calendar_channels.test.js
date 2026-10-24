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

// The meal page's answer for meal `id`, with nobody signed up.
function mealData(id) {
  return {
    id: Number(id),
    date: "2024-07-15",
    description: "Soup",
    closed: false,
    closed_at: null,
    reconciled: false,
    max: null,
    next_id: Number(id),
    prev_id: Number(id),
    residents: [],
    guests: [],
    bills: [],
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
  // The server's hosts list.
  let hostRows;

  function hostsFetches() {
    return axios.get.mock.calls.filter(([url]) => url.endsWith("/hosts"))
      .length;
  }

  // Pusher confirms every channel this page has open, as it does at page
  // load and again after each reconnect.
  function confirmEveryChannel() {
    [...FakePusher.instance.open.keys()].forEach((name) => {
      fire(name, "pusher:subscription_succeeded");
    });
  }

  // The handler the store bound for the connection's state changes.
  function stateChange() {
    const calls = FakePusher.instance.connection.bind.mock.calls.filter(
      ([event]) => event === "state_change",
    );
    expect(calls).toHaveLength(1);
    return calls[0][1];
  }

  function fetchesOf(year, month) {
    const suffix = `/calendar/${year}-${String(month).padStart(2, "0")}-15`;
    return axios.get.mock.calls.filter(([url]) => url.endsWith(suffix)).length;
  }

  // July 2024 on screen, June and August open and prefetched. Pusher
  // has confirmed every channel, as it does a moment after page load;
  // the neighbours are prefetched only after the residents channel's
  // confirmation ("the first confirmations" below).
  async function julyOnScreen() {
    const store = DataStore.create({ meals: [] });
    store.switchMonths("2024-07-15");
    await flush();
    confirmEveryChannel();
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
    hostRows = [[1, "Bob", "A"]];
    axios.get.mockImplementation((url) => {
      if (url.endsWith("/hosts")) {
        return Promise.resolve({ status: 200, data: hostRows });
      }
      const meal = url.match(/\/meals\/(\d+)\/cooks$/);
      if (meal) {
        return Promise.resolve({ status: 200, data: mealData(meal[1]) });
      }
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

  // The real library loads after the page's load event, when the main
  // thread is idle (pusher_client.js). The month is drawn before then.
  // The subscriptions wait in the queue, and when Pusher confirms them,
  // the month on screen is fetched once more, so a change made while
  // the page was connecting is not lost (#112).
  it("a Pusher that connects after the month is drawn still fetches the month on screen when it confirms", async () => {
    delete window.Pusher;
    vi.doMock("pusher-js", () => ({ default: FakePusher }));
    const idle = [];
    window.requestIdleCallback = (callback) => idle.push(callback);
    FakePusher.instance = undefined;
    try {
      const store = DataStore.create({ meals: [] });
      store.switchMonths("2024-07-15");
      await flush();
      expect(FakePusher.instance).toBeUndefined();
      const julyFetches = fetchesOf(2024, 7);
      titles.set("2024-7", "July, changed while connecting");

      idle.forEach((callback) => callback());
      // The idle callback starts the import of pusher-js. Under load it
      // can take longer than flush(), so wait for the Pusher it makes.
      await vi.waitFor(() => expect(FakePusher.instance).toBeDefined());
      expect(openNames()).toContain(monthChannel(2024, 7));
      confirmEveryChannel();
      await flush();

      expect(fetchesOf(2024, 7)).toBe(julyFetches + 1);
      expect(store.calendarEvents[0].title).toBe(
        "July, changed while connecting",
      );
    } finally {
      delete window.requestIdleCallback;
      vi.doUnmock("pusher-js");
    }
  });

  // At page load the month on screen, its two neighbours and the
  // residents channel are subscribed together, and Pusher confirms each
  // one. Each confirmation needs a fetch that starts after it (#112).
  // The residents channel's confirmation fetches the month on screen and
  // the hosts list, and drops every copy of a month. So while it is on
  // its way, the month's own confirmation leaves the fetch to it, and the
  // neighbours wait for it before they are fetched, instead of being
  // fetched, dropped and fetched again.
  describe("the first confirmations", () => {
    async function julyMounted() {
      const store = DataStore.create({ meals: [] });
      store.switchMonths("2024-07-15");
      await store.ensureHosts();
      await flush();
      return store;
    }

    it("fetch the month on screen once and the hosts list once beyond the mount's fetches", async () => {
      await julyMounted();
      expect(fetchesOf(2024, 7)).toBe(1);
      expect(hostsFetches()).toBe(1);

      // The month channels first, the residents channel last.
      confirmEveryChannel();
      await flush();

      expect(fetchesOf(2024, 7)).toBe(2);
      expect(hostsFetches()).toBe(2);
      expect(fetchesOf(2024, 6)).toBe(1);
      expect(fetchesOf(2024, 8)).toBe(1);
    });

    it("still fetch the month after the later of the two confirmations", async () => {
      const store = await julyMounted();
      titles.set("2024-7", "July, changed while connecting");

      fire(monthChannel(2024, 7), "pusher:subscription_succeeded");
      await flush();
      expect(fetchesOf(2024, 7)).toBe(1);

      fire(RESIDENTS, "pusher:subscription_succeeded");
      await flush();
      expect(fetchesOf(2024, 7)).toBe(2);
      expect(store.calendarEvents[0].title).toBe(
        "July, changed while connecting",
      );
    });

    // The two confirmations come in either order.
    it("fetch the month once, after the month's own confirmation, when the residents channel confirms first", async () => {
      const store = await julyMounted();

      fire(RESIDENTS, "pusher:subscription_succeeded");
      await flush();
      expect(fetchesOf(2024, 7)).toBe(1);
      expect(hostsFetches()).toBe(2);
      titles.set("2024-7", "July, changed while connecting");

      fire(monthChannel(2024, 7), "pusher:subscription_succeeded");
      await flush();
      expect(fetchesOf(2024, 7)).toBe(2);
      expect(store.calendarEvents[0].title).toBe(
        "July, changed while connecting",
      );
      expect(fetchesOf(2024, 6)).toBe(1);
      expect(fetchesOf(2024, 8)).toBe(1);
    });

    it("leave a later residents update to fetch the month and the hosts list again", async () => {
      const store = await julyMounted();
      confirmEveryChannel();
      await flush();
      titles.set("2024-7", "July, renamed");
      hostRows = [[1, "Robert", "A"]];

      fire(RESIDENTS, "update");
      await flush();

      expect(fetchesOf(2024, 7)).toBe(3);
      expect(hostsFetches()).toBe(3);
      expect(store.calendarEvents[0].title).toBe("July, renamed");
      expect(store.hosts[0].name).toBe("Robert");
    });

    // A channel that Pusher refuses never confirms. The other must not
    // wait for it.
    it("fetch the month and the neighbours when the residents channel is refused", async () => {
      vi.spyOn(console, "warn").mockImplementation(() => {});
      await julyMounted();
      fire(monthChannel(2024, 7), "pusher:subscription_succeeded");
      await flush();
      expect(fetchesOf(2024, 7)).toBe(1);

      fire(RESIDENTS, "pusher:subscription_error");
      await flush();

      expect(fetchesOf(2024, 7)).toBe(2);
      expect(fetchesOf(2024, 6)).toBe(1);
      expect(fetchesOf(2024, 8)).toBe(1);
    });

    it("fetch the month when the month's own channel is refused", async () => {
      vi.spyOn(console, "warn").mockImplementation(() => {});
      await julyMounted();
      fire(RESIDENTS, "pusher:subscription_succeeded");
      await flush();
      expect(fetchesOf(2024, 7)).toBe(1);

      fire(monthChannel(2024, 7), "pusher:subscription_error");
      await flush();

      expect(fetchesOf(2024, 7)).toBe(2);
      expect(fetchesOf(2024, 6)).toBe(1);
    });

    // Without a Pusher key nothing ever confirms (the staging app).
    it("do not hold back the neighbours when Pusher has no key", async () => {
      vi.stubEnv("VITE_PUSHER_KEY", "");
      await julyMounted();

      expect(fetchesOf(2024, 6)).toBe(1);
      expect(fetchesOf(2024, 8)).toBe(1);
    });
  });

  // pusher-js marks every channel unconfirmed when the connection drops,
  // subscribes them all again when it is back, and Pusher confirms each
  // one again. A rename pushed in between reaches no one. The residents
  // channel's confirmation fetches the month on screen and the hosts
  // list. So the reconnect itself does not: its fetch would read
  // before pushes reach the page again, and the later one replaces it.
  it("after a reconnect, the confirmations fetch the month on screen and the hosts list, and the reconnect itself does not", async () => {
    const store = await julyOnScreen();
    await store.ensureHosts();
    stateChange()({ previous: "connecting", current: "connected" });
    confirmEveryChannel();
    await flush();
    const julyFetches = fetchesOf(2024, 7);
    const hostsFetchesBefore = hostsFetches();

    stateChange()({ previous: "connected", current: "connecting" });
    stateChange()({ previous: "connecting", current: "connected" });
    await flush();

    expect(fetchesOf(2024, 7)).toBe(julyFetches);
    expect(hostsFetches()).toBe(hostsFetchesBefore);

    // An admin renames Bob before Pusher confirms the channels again.
    titles.set("2024-7", "July, renamed");
    hostRows = [[1, "Robert", "A"]];
    confirmEveryChannel();
    await flush();

    expect(store.calendarEvents[0].title).toBe("July, renamed");
    expect(store.hosts[0].name).toBe("Robert");
    // The month needs a read after both July's own confirmation (#112)
    // and the residents channel's. The order of the two is not known,
    // so the later one fetches it, once ("the first confirmations").
    expect(fetchesOf(2024, 7)).toBe(julyFetches + 1);
    expect(hostsFetches()).toBe(hostsFetchesBefore + 1);
  });

  // The meal page closes the calendar's channels when it mounts (#38).
  // A reconnect there fetches the meal, and no month: a month drawn on
  // the meal page would open the calendar's three channels again.
  describe("a reconnect on the meal page", () => {
    // July was on screen, and then a meal was tapped.
    async function mealPageAfterJuly() {
      const store = await julyOnScreen();
      store.teardownCalendarPage();
      store.goToMeal("1");
      await flush();
      expect(store.meal.description).toBe("Soup");
      expect(openNames()).toEqual([RESIDENTS, "meal-1"]);
      return store;
    }

    function mealFetches() {
      return axios.get.mock.calls.filter(([url]) =>
        /\/meals\/1\/cooks$/.test(url),
      ).length;
    }

    it("from Pusher leaves the calendar's channels closed", async () => {
      const store = await mealPageAfterJuly();
      const mealFetchesBefore = mealFetches();
      const julyFetches = fetchesOf(2024, 7);
      stateChange()({ previous: "connecting", current: "connected" });
      stateChange()({ previous: "connected", current: "connecting" });
      stateChange()({ previous: "connecting", current: "connected" });
      confirmEveryChannel();
      await flush();

      expect(openNames()).toEqual([RESIDENTS, "meal-1"]);
      expect(fetchesOf(2024, 7)).toBe(julyFetches);
      // The meal is fetched again, by its own confirmation and the
      // residents channel's.
      expect(mealFetches()).toBeGreaterThan(mealFetchesBefore);
      expect(store.meal.description).toBe("Soup");
    });

    it("from the browser's online event leaves the calendar's channels closed", async () => {
      const store = await mealPageAfterJuly();
      const before = axios.get.mock.calls.length;
      const julyFetches = fetchesOf(2024, 7);

      store.handleReconnect();
      await flush();

      expect(openNames()).toEqual([RESIDENTS, "meal-1"]);
      expect(fetchesOf(2024, 7)).toBe(julyFetches);
      expect(axios.get.mock.calls.slice(before).map(([url]) => url)).toEqual([
        expect.stringMatching(/\/meals\/1\/cooks$/),
      ]);
    });
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
