import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// These tests run the real DataStore with the month cache capped at 2
// entries (via VITE_MONTH_CACHE_MAX_ENTRIES). Every visit to a month
// also prefetches both neighbors, so with a cap this small something
// is evicted on almost every navigation. The point is to prove the
// app still behaves while eviction churns: the right month always
// renders, Pusher invalidation still works, and RAM never holds more
// than the cap.

vi.mock("axios", () => {
  const mockAxios = vi.fn(() => Promise.resolve({ status: 200 }));
  mockAxios.get = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
  mockAxios.interceptors = {
    response: { use: vi.fn(), eject: vi.fn() },
    request: { use: vi.fn() },
  };
  return { default: mockAxios };
});

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => {
      const cookies = {
        token: "test-token",
        community_id: "test-community-id",
        timezone: "America/Los_Angeles",
      };
      return cookies[name];
    }),
    remove: vi.fn(),
    set: vi.fn(),
  },
}));

vi.mock("pusher-js", () => {
  class MockPusher {
    constructor() {
      this.connection = { bind: vi.fn(), socket_id: "test-socket" };
      this.subscribe = vi.fn(() => ({ bind: vi.fn(), name: "test-channel" }));
      this.unsubscribe = vi.fn();
    }
  }
  return { default: MockPusher };
});

// A real in-memory "disk" so the IndexedDB tier behaves like the real
// one: what setItem stored, getItem returns later.
vi.mock("localforage", () => {
  const disk = new Map();
  return {
    default: {
      _disk: disk,
      getItem: vi.fn((key) =>
        Promise.resolve(disk.has(key) ? disk.get(key) : null),
      ),
      setItem: vi.fn((key, value) => {
        disk.set(key, value);
        return Promise.resolve(value);
      }),
      removeItem: vi.fn((key) => {
        disk.delete(key);
        return Promise.resolve();
      }),
    },
  };
});

vi.mock("uuid", () => {
  let counter = 0;
  return { v4: vi.fn(() => "test-uuid-" + ++counter) };
});

let DataStore;
let monthCache;
let axios;
let localforage;

// Calendar payloads the fake API serves. A test can replace a month's
// payload to prove a fresh fetch happened after invalidation.
const apiPayloads = new Map();

function payloadKey(year, month) {
  return `${year}-${month}`;
}

function titleFor(year, month) {
  return `${year}-${month} event`;
}

function calendarData(year, month, title) {
  return {
    id: "test-community-id",
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

// Pusher channels by name, so tests can fire their bound handlers.
const channels = new Map();

function createStore() {
  const store = DataStore.create({
    meals: [{ id: 1 }],
    meal: 1,
    residentStore: { residents: {} },
    billStore: { bills: {} },
    guestStore: { guests: {} },
  });
  window.Comeals.pusher.subscribe = vi.fn((name) => {
    const channel = { name, bind: vi.fn() };
    channels.set(name, channel);
    return channel;
  });
  window.Comeals.pusher.unsubscribe = vi.fn();
  return store;
}

// Fires the "update" handler bound to a month's Pusher channel — the
// same thing a real Pusher message would do.
function fireCalendarUpdate(year, month) {
  const name = `community-test-community-id-calendar-${year}-${month}`;
  const channel = channels.get(name);
  const call = channel.bind.mock.calls.find(([event]) => event === "update");
  call[1]();
}

// Waits until the given month is on screen, then lets the prefetch and
// revalidation chains finish so the next step starts from a quiet state.
async function settleOn(store, year, month) {
  await vi.waitFor(() => {
    expect(store.calendarEvents[0].title).toBe(titleFor(year, month));
  });
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 0));
  }
}

describe("month cache eviction through the store (cap = 2)", () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    channels.clear();
    apiPayloads.clear();

    // The cap must be in place before the store module loads, because
    // month_cache reads the env var once at import time.
    vi.stubEnv("VITE_MONTH_CACHE_MAX_ENTRIES", "2");
    vi.resetModules();
    ({ DataStore } =
      await import("../../../app/frontend/src/stores/data_store.js"));
    monthCache =
      await import("../../../app/frontend/src/stores/month_cache.js");
    axios = (await import("axios")).default;
    localforage = (await import("localforage")).default;
    localforage._disk.clear();

    axios.get.mockImplementation((url) => {
      const match = url.match(/\/calendar\/(\d{4})-(\d{2})-\d{2}$/);
      if (match) {
        const year = Number(match[1]);
        const month = Number(match[2]);
        const payload =
          apiPayloads.get(payloadKey(year, month)) ||
          calendarData(year, month, titleFor(year, month));
        return Promise.resolve({ status: 200, data: payload });
      }
      return Promise.resolve({ status: 200, data: {} });
    });

    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    window.alert = vi.fn();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("runs with the tiny cap from the env var", () => {
    expect(monthCache.MONTH_CACHE_MAX_ENTRIES).toBe(2);
  });

  it("browsing months keeps RAM at the cap and every month still renders", async () => {
    const store = createStore();

    // Forward through four months.
    for (const month of [7, 8, 9, 10]) {
      store.switchMonths(`2024-${String(month).padStart(2, "0")}-15`);
      await settleOn(store, 2024, month);
      expect(monthCache.size()).toBeLessThanOrEqual(2);
    }

    // And back again. Months long evicted from RAM come back from the
    // IndexedDB tier or a refetch — the screen never breaks.
    for (const month of [9, 8, 7]) {
      store.switchMonths(`2024-${String(month).padStart(2, "0")}-15`);
      await settleOn(store, 2024, month);
      expect(monthCache.size()).toBeLessThanOrEqual(2);
    }

    // The disk tier kept every visited month (plus prefetched
    // neighbors); only the RAM tier is capped.
    expect(localforage._disk.size).toBeGreaterThanOrEqual(4);
    expect(monthCache.size()).toBe(2);
  });

  it("a Pusher invalidation still clears an evicting cache, and the next visit fetches fresh data", async () => {
    const store = createStore();

    store.switchMonths("2024-07-15");
    await settleOn(store, 2024, 7);

    // August was prefetched as July's neighbor and sits in RAM and on
    // disk. A Pusher update on its channel invalidates both copies.
    fireCalendarUpdate(2024, 8);
    const augustKey = monthCache.keyFor("test-community-id", "2024", "8");
    expect(monthCache.get(augustKey)).toBeUndefined();
    expect(localforage._disk.has(augustKey)).toBe(false);

    // The server now has different data for August. The next visit
    // must show it — a stale copy anywhere would show the old title.
    apiPayloads.set(payloadKey(2024, 8), calendarData(2024, 8, "August fresh"));

    store.switchMonths("2024-08-15");
    await vi.waitFor(() => {
      expect(store.calendarEvents[0].title).toBe("August fresh");
    });
    expect(monthCache.size()).toBeLessThanOrEqual(2);
  });
});
