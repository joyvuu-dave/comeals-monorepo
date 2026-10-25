import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { vitestWaitFor } from "../helpers/wait_for.js";
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

// `residentName` puts one resident (id 1) on the sign-up list.
function mealPayload(id, description, residentName) {
  return {
    id,
    date: "2024-07-15",
    description,
    closed: false,
    closed_at: null,
    reconciled: false,
    max: null,
    // The server's answer at the ends: the meal's own id, never null.
    next_id: id,
    prev_id: id,
    residents:
      residentName === undefined
        ? []
        : [
            {
              id: 1,
              meal_id: id,
              name: residentName,
              attending: false,
              attending_at: null,
              late: false,
              vegetarian: false,
              can_cook: true,
              active: true,
            },
          ],
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

// What Pusher does, and nothing more: a push reaches a channel only
// once Pusher has confirmed this client's subscription to it, with
// "pusher:subscription_succeeded". A push to a channel nobody opened,
// or to one opened but not confirmed yet, is lost.
const confirmed = new Set();

function pushTo(name) {
  if (!confirmed.has(name)) return;
  runHandlers(name, "update");
}

function confirmSubscription(name) {
  confirmed.add(name);
  runHandlers(name, "pusher:subscription_succeeded");
}

function runHandlers(name, event) {
  const channel = channels.get(name);
  if (!channel) return;
  channel.bind.mock.calls
    .filter(([bound]) => bound === event)
    .forEach(([, handler]) => handler());
}

const RESIDENTS_CHANNEL = `community-${COMMUNITY}-residents`;

function calendarRequests(year, month) {
  const suffix = `/calendar/${year}-${String(month).padStart(2, "0")}-15`;
  return axios.get.mock.calls.filter(([url]) => url.endsWith(suffix)).length;
}

function hostsRequests() {
  return axios.get.mock.calls.filter(([url]) => url.endsWith("/hosts")).length;
}

// Holds the next hosts answer until the test sends it, the way a slow
// network does. The test sends it with the rows the server read when
// the request came in. Every later hosts request is answered at once.
function holdNextHostsAnswer() {
  let send = null;
  const serve = axios.get.getMockImplementation();
  axios.get.mockImplementation((url) => {
    if (send === null && url.endsWith("/hosts")) {
      return new Promise((resolve) => {
        send = resolve;
      });
    }
    return serve(url);
  });
  return function (rowsAsRead) {
    expect(send, "no hosts request was made").not.toBeNull();
    send({ status: 200, data: rowsAsRead });
  };
}

// Serves calendar months from `payloads` (a key per "year-month"), the
// meal page from `meals` (a key per id), and the hosts list from
// `hosts.rows`.
function serveFrom(payloads, meals, hosts) {
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
    if (url.endsWith("/hosts")) {
      return Promise.resolve({ status: 200, data: hosts.rows });
    }
    return Promise.resolve({ status: 200, data: {} });
  });
}

// Meal 1 on screen, unless the test hands in another snapshot: a page
// load on the calendar has no meal ({ meals: [] }).
function createStore(snapshot = { meals: [{ id: 1 }], meal: 1 }) {
  const store = DataStore.create(snapshot);
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
  let hosts;

  beforeEach(() => {
    vi.clearAllMocks();
    // The store waits for Pusher's confirmations only when there is a
    // key (confirmationPending in data_store_app.js), and four tests
    // here are about that wait. Without this they passed only where
    // .env sets the key.
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    channels.clear();
    confirmed.clear();
    idbKeyval._disk.clear();
    monthCache.clear();
    payloads = new Map([
      ["2024-6", calendarData(2024, 6, "June")],
      ["2024-7", calendarData(2024, 7, "July")],
      ["2024-8", calendarData(2024, 8, "August")],
    ]);
    meals = new Map([["1", mealPayload(1, "Menu v1")]]);
    hosts = { rows: [[1, "Bob", "A"]] };
    serveFrom(payloads, meals, hosts);
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    window.alert = vi.fn();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  describe("the residents channel", () => {
    it("is subscribed by the calendar, and an update drops every cached month and refetches the one on screen", async () => {
      const store = createStore();
      stage(store, () => {
        store.meal = null;
      });

      store.switchMonths("2024-07-15");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      await flush();
      // Pusher confirms July's channel and the residents channel. The
      // months next to July are prefetched only after the residents
      // channel's confirmation, which would drop them.
      confirmSubscription(`community-${COMMUNITY}-calendar-2024-7`);
      confirmSubscription(RESIDENTS_CHANNEL);
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
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July, renamed");
      });
      expect(calendarRequests(2024, 7)).toBe(julyFetchesBefore + 1);

      // A neighbour that was prefetched before the change is fetched
      // fresh on the next navigation, not served from a copy.
      store.switchMonths("2024-08-15");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("August, renamed");
      });
    });

    it("is subscribed by the meal page, and an update refetches the meal", async () => {
      const store = createStore();
      store.loadData(mealPayload(1, "Menu v1"), "server");
      expect(channels.has(RESIDENTS_CHANNEL)).toBe(true);

      meals.set("1", mealPayload(1, "Menu v2"));
      fireUpdate(RESIDENTS_CHANNEL);

      await vitestWaitFor(() => {
        expect(store.meal.description).toBe("Menu v2");
      });
    });

    // The calendar asks for the hosts list when it mounts (show.jsx).
    // The server read the list before the rename, so its answer, still
    // on the wire when the push comes, holds the old name.
    it("an update refetches a hosts list whose first answer is still on the wire", async () => {
      const store = createStore({ meals: [] });
      store.switchMonths("2024-07-15");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();
      const sendHostsAnswer = holdNextHostsAnswer();
      store.ensureHosts();
      const asRead = hosts.rows;

      hosts.rows = [[1, "Robert", "A"]];
      pushTo(RESIDENTS_CHANNEL);
      await flush();
      sendHostsAnswer(asRead);
      await flush();

      expect(store.hosts[0].name).toBe("Robert");
    });

    // A tap to October reads its copy from the disk. An update comes
    // before the read ends, and the person taps back to July before
    // October is drawn. The read's copy was saved before the update.
    it("an update drops a copy that a navigation was reading from disk", async () => {
      const store = createStore({ meals: [] });
      store.switchMonths("2024-07-15");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      await flush();
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();
      const octoberKey = monthCache.keyFor(COMMUNITY, "2024", "10");
      idbKeyval._disk.set(octoberKey, calendarData(2024, 10, "October"));
      payloads.set("2024-9", calendarData(2024, 9, "September"));
      payloads.set("2024-10", calendarData(2024, 10, "October, renamed"));
      payloads.set("2024-11", calendarData(2024, 11, "November"));

      store.switchMonths("2024-10-15");
      fireUpdate(RESIDENTS_CHANNEL);
      store.switchMonths("2024-07-15");
      await flush();
      expect(store.calendarEvents[0].title).toBe("July");

      store.switchMonths("2024-10-15");
      expect(store.calendarEvents[0].title).not.toBe("October");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("October, renamed");
      });
    });

    it("is one subscription, however many pages load", async () => {
      const store = createStore();
      store.loadData(mealPayload(1, "Menu v1"), "server");
      store.loadData(mealPayload(1, "Menu v1"), "server");
      store.switchMonths("2024-07-15");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });

      const subscriptions = window.Comeals.pusher.subscribe.mock.calls.filter(
        ([name]) => name === RESIDENTS_CHANNEL,
      );
      expect(subscriptions).toHaveLength(1);
    });
  });

  describe("a reconnect while the month's first fetch is on the wire", () => {
    it("drops the response that was already on the wire", async () => {
      // The boot-time prefetch of July is slow. While it is on the wire
      // the connection drops and comes back. Pusher does not replay a
      // push sent while it was down, so the reconnect fetches the month
      // again (data_store_app.js handleReconnect). The prefetch's answer
      // may have been read before a change: rendering it would show the
      // old month with nothing left to correct it. (No push can reach
      // July yet: its channel opens only when the first answer is
      // drawn.)
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

      store.handleReconnect();
      await flush();

      // Now the old answer lands.
      requests[0]({ status: 200, data: calendarData(2024, 7, "July, old") });
      await flush();
      expect(store.calendarEvents.map((e) => e.title)).not.toContain(
        "July, old",
      );

      // And the fresh fetch the reconnect caused lands.
      expect(requests).toHaveLength(2);
      requests[1]({ status: 200, data: calendarData(2024, 7, "July, new") });
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July, new");
      });
    });
  });

  // A channel opens only when the first answer is drawn, so a push sent
  // while that answer is on the wire reaches no one. Pusher's
  // confirmation of the new subscription fetches once more (#112).
  describe("a change made while the month's first fetch is on the wire", () => {
    it("is shown once Pusher confirms the month's channel", async () => {
      const JULY = `community-${COMMUNITY}-calendar-2024-7`;
      // Hold the first July answer; serve every later request as usual.
      let firstJuly = null;
      const serve = axios.get.getMockImplementation();
      axios.get.mockImplementation((url) => {
        if (firstJuly === null && /\/calendar\/2024-07-15$/.test(url)) {
          return new Promise((resolve) => {
            firstJuly = resolve;
          });
        }
        return serve(url);
      });

      const store = createStore();
      stage(store, () => {
        store.meal = null;
      });
      store.switchMonths("2024-07-15");
      await flush();
      expect(firstJuly).not.toBeNull();

      // The server has read July for that answer. Now someone changes
      // July, and the server pushes July's channel.
      const julyAsRead = payloads.get("2024-7");
      payloads.set("2024-7", calendarData(2024, 7, "July, changed"));
      pushTo(JULY);

      // The answer read before the change lands, and Pusher confirms
      // every subscription the page made.
      firstJuly({ status: 200, data: julyAsRead });
      await flush();
      expect(store.calendarEvents[0].title).toBe("July");
      // While the residents channel's confirmation is on its way, July's
      // own confirmation leaves the fetch to it, and that confirmation
      // fetches July after both.
      const julyBefore = calendarRequests(2024, 7);
      confirmSubscription(JULY);
      await flush();
      expect(calendarRequests(2024, 7)).toBe(julyBefore);
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();

      expect(store.calendarEvents[0].title).toBe("July, changed");
      expect(calendarRequests(2024, 7)).toBe(julyBefore + 1);
    });
  });

  describe("a change made while the meal's first fetch is on the wire", () => {
    it("is shown once Pusher confirms the meal's channel", async () => {
      // Hold the first answer for meal 1; serve every later request as
      // usual.
      let firstAnswer = null;
      const serve = axios.get.getMockImplementation();
      axios.get.mockImplementation((url) => {
        if (firstAnswer === null && /\/meals\/1\/cooks$/.test(url)) {
          return new Promise((resolve) => {
            firstAnswer = resolve;
          });
        }
        return serve(url);
      });

      const store = createStore();
      store.loadDataAsync();
      await flush();
      expect(firstAnswer).not.toBeNull();

      // The server has read the meal for that answer. Now someone
      // changes it, and the server pushes the meal's channel.
      const asRead = meals.get("1");
      meals.set("1", mealPayload(1, "Menu v2"));
      pushTo("meal-1");

      firstAnswer({ status: 200, data: asRead });
      await flush();
      expect(store.meal.description).toBe("Menu v1");
      confirmSubscription("meal-1");
      await flush();

      expect(store.meal.description).toBe("Menu v2");
    });
  });

  // The residents channel opens with the first month, meal or hosts
  // list drawn, and a rename pushes only the residents channel. A rename pushed before Pusher confirms it reaches
  // no one. So the confirmation does what a push on that channel does:
  // every copy read before it is dropped, and what is on screen is
  // fetched again.
  describe("a rename pushed before Pusher confirms the residents channel", () => {
    const JUNE = `community-${COMMUNITY}-calendar-2024-6`;
    const JULY = `community-${COMMUNITY}-calendar-2024-7`;
    const AUGUST = `community-${COMMUNITY}-calendar-2024-8`;

    // July on screen and the hosts list loaded. Pusher has confirmed
    // the three months' channels, which open first. The residents
    // channel's confirmation is still on its way, so July's own
    // confirmation left its fetch to it, and June and August wait for
    // it before they are prefetched.
    async function julyOnScreen() {
      const store = createStore({ meals: [] });
      store.switchMonths("2024-07-15");
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      await store.ensureHosts();
      await flush();
      [JULY, JUNE, AUGUST].forEach(confirmSubscription);
      await flush();
      expect(monthCache.size()).toBe(1);
      expect(store.calendarEvents[0].title).toBe("July");
      return store;
    }

    // An admin renames Bob to Robert. His name is in every month, the
    // hosts list and the meal's sign-up list.
    function renameBob() {
      payloads.set("2024-6", calendarData(2024, 6, "June, renamed"));
      payloads.set("2024-7", calendarData(2024, 7, "July, renamed"));
      payloads.set("2024-8", calendarData(2024, 8, "August, renamed"));
      hosts.rows = [[1, "Robert", "A"]];
      meals.set("1", mealPayload(1, "Menu v1", "Robert"));
    }

    it("shows the new name in the month next to the one on screen", async () => {
      // The clock stands still, so August's prefetch is under 5 seconds
      // old on the tap however slow the run is. On a run slower than
      // that, the tap would fetch August again, and the test would pass
      // without the confirmation's fix.
      vi.useFakeTimers({ toFake: ["Date"] });
      vi.setSystemTime(new Date("2024-07-15T12:00:00-07:00"));
      const store = await julyOnScreen();

      renameBob();
      pushTo(RESIDENTS_CHANNEL);
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();

      // A tap to August, less than 5 seconds after its prefetch, draws
      // the copy in memory and fetches nothing. That copy was read
      // before the rename.
      store.switchMonths("2024-08-15");
      await flush();
      expect(store.calendarEvents[0].title).toBe("August, renamed");
    });

    it("shows the new name in the hosts list", async () => {
      const store = await julyOnScreen();
      expect(store.hosts[0].name).toBe("Bob");
      const fetchesBefore = hostsRequests();

      renameBob();
      pushTo(RESIDENTS_CHANNEL);
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();

      expect(store.hosts[0].name).toBe("Robert");
      expect(hostsRequests()).toBe(fetchesBefore + 1);
    });

    // The calendar asks for the hosts list when it mounts, next to the
    // month, so its answer can come after the confirmation.
    it("shows the new name in a hosts list whose first answer is still on the wire", async () => {
      const sendHostsAnswer = holdNextHostsAnswer();
      const store = createStore({ meals: [] });
      store.switchMonths("2024-07-15");
      store.ensureHosts();
      await vitestWaitFor(() => {
        expect(store.calendarEvents[0].title).toBe("July");
      });
      [JULY, JUNE, AUGUST].forEach(confirmSubscription);
      await flush();
      const asRead = hosts.rows;

      renameBob();
      pushTo(RESIDENTS_CHANNEL);
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();
      sendHostsAnswer(asRead);
      await flush();

      expect(store.hosts[0].name).toBe("Robert");
    });

    it("shows the new name in the month on screen, which its own confirmation read before the rename", async () => {
      const store = await julyOnScreen();

      renameBob();
      pushTo(RESIDENTS_CHANNEL);
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();

      expect(store.calendarEvents[0].title).toBe("July, renamed");
    });

    it("shows the new name on the meal page, and drops the months saved on disk by an earlier visit", async () => {
      // A visit to the calendar before this page load saved July.
      const julyKey = monthCache.keyFor(COMMUNITY, "2024", "7");
      idbKeyval._disk.set(julyKey, calendarData(2024, 7, "July"));
      meals.set("1", mealPayload(1, "Menu v1", "Bob"));
      const store = createStore();
      store.loadDataAsync();
      await flush();
      expect(store.residents.get("1").name).toBe("Bob");
      confirmSubscription("meal-1");
      await flush();

      renameBob();
      pushTo(RESIDENTS_CHANNEL);
      confirmSubscription(RESIDENTS_CHANNEL);
      await flush();

      expect(store.residents.get("1").name).toBe("Robert");
      expect(idbKeyval._disk.has(julyKey)).toBe(false);
      // The meal page has no month on screen, so no month is fetched.
      expect(calendarRequests(2024, 7)).toBe(0);
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
      await vitestWaitFor(() => {
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
      store.loadData(mealPayload(1, "Menu v1"), "server");

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
      await vitestWaitFor(() => {
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
