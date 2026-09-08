import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The meal page's loading rules (data_store_meal_page.ts): what a
// callback does when the screen has moved on, and the retry backoff's
// edges. The main paths are in data_store.test.js.

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";

function mealPayload(overrides = {}) {
  return {
    id: 1,
    date: "2023-06-15",
    description: "",
    closed: false,
    closed_at: null,
    reconciled: false,
    max: null,
    next_id: null,
    prev_id: null,
    residents: [],
    guests: [],
    bills: [],
    ...overrides,
  };
}

function resident(overrides) {
  return {
    id: 1,
    meal_id: 1,
    name: "Sam",
    attending: false,
    attending_at: null,
    late: false,
    vegetarian: false,
    can_cook: true,
    active: true,
    ...overrides,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function flush() {
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 0));
  }
}

// Pusher channels by name, so a test can fire what a channel bound.
const channels = new Map();

function createStore() {
  const store = createDataStore();
  window.Comeals.pusher.subscribe = vi.fn((name) => {
    const channel = { name, bind: vi.fn() };
    channels.set(name, channel);
    return channel;
  });
  window.Comeals.pusher.unsubscribe = vi.fn();
  return store;
}

describe("meal page store", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    channels.clear();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("ignores menu text for a node that is gone", () => {
    const store = createStore();

    store.setDescriptionOn(null, "Tacos");
    store.noteMenuTyping(null);

    expect(store.meal.description).toBe("");
    expect(store.meal.descriptionDirty).toBe(false);
  });

  it("does not send an open/close with no meal on screen", () => {
    const store = createStore();
    stage(store, () => {
      store.meal = null;
    });

    store.toggleClosed();

    expect(axios).not.toHaveBeenCalled();
    expect(store.closedPending).toBe(false);
  });

  it("loadData does nothing with no meal on screen", () => {
    const store = createStore();
    stage(store, () => {
      store.meal = null;
    });

    store.loadData(mealPayload({ residents: [resident()] }));

    expect(store.residents.size).toBe(0);
  });

  it("keeps two residents with the same name in the order they came", () => {
    const store = createStore();

    store.loadData(
      mealPayload({
        residents: [
          resident({ id: 2, name: "Sam" }),
          resident({ id: 1, name: "Sam" }),
        ],
      }),
    );

    expect(Array.from(store.residents.values()).map((r) => r.id)).toEqual([
      2, 1,
    ]);
  });

  it("refetches the meal when its channel says update", () => {
    const store = createStore();
    store.loadData(mealPayload());
    const loadDataAsync = stubAction(store, "loadDataAsync");

    const channel = channels.get("meal-1");
    const update = channel.bind.mock.calls.find(
      ([event]) => event === "update",
    );
    update[1]();

    expect(loadDataAsync).toHaveBeenCalledTimes(1);
  });

  describe("switching meals", () => {
    it("shows the cached copy first, then fetches", async () => {
      const store = createStore();
      idbKeyval.get.mockResolvedValueOnce(
        mealPayload({ id: 2, description: "Cached" }),
      );
      const loadDataAsync = stubAction(store, "loadDataAsync");

      store.switchMeals(2);
      await flush();

      expect(store.meal.description).toBe("Cached");
      expect(loadDataAsync).toHaveBeenCalledTimes(1);
    });

    it("still fetches when the unreadable copy cannot be deleted either", async () => {
      const store = createStore();
      idbKeyval.get.mockRejectedValueOnce(new Error("IndexedDB is closed"));
      idbKeyval.del.mockRejectedValueOnce(new Error("IndexedDB is closed"));
      const loadDataAsync = stubAction(store, "loadDataAsync");

      store.switchMeals(2);
      await flush();

      expect(loadDataAsync).toHaveBeenCalledTimes(1);
    });

    it("drops a cached copy it cannot read and fetches", async () => {
      const store = createStore();
      idbKeyval.get.mockRejectedValueOnce(new Error("IndexedDB is closed"));
      const loadDataAsync = stubAction(store, "loadDataAsync");

      store.switchMeals(2);
      await flush();

      expect(idbKeyval.del).toHaveBeenCalledWith("2");
      expect(loadDataAsync).toHaveBeenCalledTimes(1);
    });
  });

  describe("two fetches of the meal on the wire", () => {
    // The first answer was current when it arrived, so it went to the
    // cache; a second fetch started during that write. When the write
    // finishes, the first answer is stale and must not reach the screen.
    it("an answer overtaken during its cache write is dropped", async () => {
      const store = createStore();
      const firstWrite = deferred();
      axios.get
        .mockResolvedValueOnce({
          status: 200,
          data: mealPayload({ description: "First" }),
        })
        .mockResolvedValueOnce({
          status: 200,
          data: mealPayload({ description: "Second" }),
        });
      idbKeyval.set.mockImplementationOnce(() => firstWrite.promise);

      store.loadDataAsync();
      await flush();
      expect(idbKeyval.set).toHaveBeenCalledTimes(1);
      store.loadDataAsync();
      await flush();
      expect(store.meal.description).toBe("Second");

      firstWrite.resolve();
      await flush();

      expect(store.meal.description).toBe("Second");
    });
  });

  describe("the retry backoff", () => {
    it("ignores a failure for a meal that is no longer on screen", () => {
      const store = createStore();

      store.handleMealLoadError({ response: { status: 500 } }, 999);

      expect(store.mealLoadFailed).toBe(false);
      expect(store.mealRetryTimer).toBeNull();
    });

    it("a second failure while a retry is pending replaces the timer and doubles the wait", () => {
      vi.useFakeTimers();
      const store = createStore();

      store.scheduleMealRetry(1);
      const first = store.mealRetryTimer;
      expect(store.mealRetryDelayMs).toBe(2000);

      store.scheduleMealRetry(1);

      expect(store.mealRetryTimer).not.toBe(first);
      expect(store.mealRetryDelayMs).toBe(4000);
      store.cancelMealRetry();
    });

    it("a timer that fires after the meal changed, or after data arrived, does nothing", () => {
      const store = createStore();
      const loadDataAsync = stubAction(store, "loadDataAsync");

      store.onMealRetryTimer(999);
      stage(store, () => {
        store.mealLoading = false;
      });
      store.onMealRetryTimer(1);

      expect(loadDataAsync).not.toHaveBeenCalled();
    });

    it("retry-now fetches at once when no automatic retry is pending", () => {
      const store = createStore();
      const loadDataAsync = stubAction(store, "loadDataAsync");
      stage(store, () => {
        store.mealRetryDelayMs = 8000;
      });

      store.retryMealLoadNow();

      expect(loadDataAsync).toHaveBeenCalledTimes(1);
      expect(store.mealRetryDelayMs).toBeNull();
    });

    it("retry-now does nothing with data on screen or with no meal", () => {
      const store = createStore();
      const loadDataAsync = stubAction(store, "loadDataAsync");

      stage(store, () => {
        store.mealLoading = false;
      });
      store.retryMealLoadNow();
      stage(store, () => {
        store.mealLoading = true;
        store.meal = null;
      });
      store.retryMealLoadNow();

      expect(loadDataAsync).not.toHaveBeenCalled();
    });
  });
});
