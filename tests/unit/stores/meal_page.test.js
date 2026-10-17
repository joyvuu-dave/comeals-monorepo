import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The meal page's loading rules (data_store_meal_page.ts): what a
// callback does when the screen has moved on, and the retry backoff's
// edges. The main paths are in data_store.test.js.

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));
vi.mock("../../../app/frontend/src/helpers/bugsnag.js", () => ({
  notifyError: vi.fn(),
}));

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import { DEVICE_READ_LIMIT_MS } from "../../../app/frontend/src/helpers/device_copy";
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { MEAL_REFETCH_RETRY_MS } from "../../../app/frontend/src/stores/data_store_meal_page";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";

// The server sends the meal's own id as next_id and prev_id when there
// is no meal after or before it (MealFormSerializer), never null.
function mealPayload(overrides = {}) {
  const id = overrides.id ?? 1;
  return {
    id,
    date: "2023-06-15",
    description: "",
    closed: false,
    closed_at: null,
    reconciled: false,
    cancelled: false,
    max: null,
    next_id: id,
    prev_id: id,
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

    store.loadData(mealPayload({ residents: [resident()] }), "server");

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
      "server",
    );

    expect(Array.from(store.residents.values()).map((r) => r.id)).toEqual([
      2, 1,
    ]);
  });

  // The server lists every cook who has a bill (MealFormSerializer), so
  // a bill whose cook is not in the residents list is a bug (#91), and
  // it is reported. A bills save names only the cooks it changes, and
  // no row names this cook, so saves go on and never touch their bill
  // (#135).
  describe("a bill whose cook is not in the residents list", () => {
    it("is reported once per load, naming the meal and every such cook", () => {
      vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();

      store.loadData(
        mealPayload({
          residents: [resident({ id: 10 })],
          bills: [
            { resident_id: 10, amount: "15.0", no_cost: false },
            { resident_id: 998, amount: "0.0", no_cost: true },
            { resident_id: 999, amount: "40.0", no_cost: false },
          ],
        }),
        "server",
      );

      expect(notifyError).toHaveBeenCalledTimes(1);
      const [reported] = notifyError.mock.calls[0];
      expect(reported).toBeInstanceOf(Error);
      expect(reported.message).toBe(
        "Meal 1 has bills whose cooks are not in its residents list: 998, 999",
      );
    });

    it("is not reported when every cook is listed", () => {
      const store = createStore();

      store.loadData(
        mealPayload({
          residents: [resident({ id: 10 })],
          bills: [{ resident_id: 10, amount: "15.0", no_cost: false }],
        }),
        "server",
      );

      expect(notifyError).not.toHaveBeenCalled();
    });

    // Meal 2 as an older server sent it: cook 999 has a bill but no row
    // in residents. Copies like this stay on devices after the deploy
    // that lists every cook (#91).
    function meal2WithHiddenCook() {
      return mealPayload({
        id: 2,
        residents: [resident({ id: 10 })],
        bills: [
          { resident_id: 10, amount: "15.0", no_cost: false },
          { resident_id: 999, amount: "40.0", no_cost: false },
        ],
      });
    }

    function billsPatches() {
      return axios.mock.calls.filter(([config]) => config.method === "patch");
    }

    // Types a cost for the cook the page shows, saves it right away, and
    // answers with the messages the person sees.
    function toastsAfterASave(store) {
      toastStore.clearAll();
      const row = Array.from(store.bills.values()).find(
        (bill) => bill.resident !== null,
      );
      row.setAmount("16");
      store.saveBillRowNow(row);
      return toastStore.toasts.map((toast) => [toast.type, toast.message]);
    }

    // The save names only the cook the page shows.
    const EDITS_SENT = [
      {
        op: "change",
        resident_id: 10,
        from: { amount: "15.00", no_cost: false },
        to: { amount: "16", no_cost: false },
      },
    ];

    // The copy on the device is not a bug in the server's answer: an old
    // copy is expected for a while after the deploy, and the server's
    // answer comes right after it. So it is not reported.
    it("is not reported when it is in the copy saved on the device, and a save never names that cook", async () => {
      vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();
      idbKeyval.get.mockResolvedValueOnce(meal2WithHiddenCook());
      // The server's answer does not come in this test.
      stubAction(store, "loadDataAsync");

      store.switchMeals(2);
      await flush();

      expect(store.meal.id).toBe(2);
      expect(store.bills.size).toBe(3);
      expect(notifyError).not.toHaveBeenCalled();
      expect(toastsAfterASave(store)).toEqual([]);
      expect(billsPatches()).toHaveLength(1);
      expect(billsPatches()[0][0].data.edits).toEqual(EDITS_SENT);
    });

    it("is reported once when the server's answer has it, after the copy on the device had it too", async () => {
      vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();
      idbKeyval.get.mockResolvedValueOnce(meal2WithHiddenCook());
      axios.get.mockResolvedValueOnce({
        status: 200,
        data: meal2WithHiddenCook(),
      });

      store.switchMeals(2);
      await flush();

      expect(axios.get).toHaveBeenCalledTimes(1);
      expect(notifyError).toHaveBeenCalledTimes(1);
      expect(notifyError.mock.calls[0][0].message).toBe(
        "Meal 2 has bills whose cooks are not in its residents list: 999",
      );
      expect(toastsAfterASave(store)).toEqual([]);
      expect(billsPatches()[0][0].data.edits).toEqual(EDITS_SENT);
    });
  });

  // The server lists the host of every guest (MealFormSerializer,
  // #134). The page shows a guest only in its host's row, so a guest
  // whose host is not in the residents list is counted in the totals,
  // but no row shows it and nobody can remove it. In the server's answer
  // that is a bug, and it is reported. In the copy saved on the device
  // it is not: a copy saved before the server listed every host can
  // still be on the device, and the server's answer comes right after.
  describe("a guest whose host is not in the residents list", () => {
    function guest(id, residentId) {
      return {
        id,
        meal_id: 1,
        resident_id: residentId,
        vegetarian: false,
        created_at: "2023-06-15T18:00:00.000Z",
      };
    }

    const WARNING =
      "These hosts have a guest but are not in the residents list, so the page does not show their guests:";

    it("is reported once per load, naming the meal and each such host once", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();

      store.loadData(
        mealPayload({
          max: 10,
          residents: [resident({ id: 10 })],
          guests: [
            guest(100, 10),
            guest(101, 999),
            guest(102, 998),
            guest(103, 999),
          ],
        }),
        "server",
      );

      expect(warn).toHaveBeenCalledWith(WARNING, [999, 998]);
      expect(notifyError).toHaveBeenCalledTimes(1);
      const [reported] = notifyError.mock.calls[0];
      expect(reported).toBeInstanceOf(Error);
      expect(reported.message).toBe(
        "Meal 1 has guests whose hosts are not in its residents list: 999, 998",
      );
      // The guests still count: the server charges them to their hosts.
      expect(store.guests.size).toBe(4);
      expect(store.meal.extras).toBe(6);
    });

    it("is not reported when every host is listed", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();

      store.loadData(
        mealPayload({
          residents: [resident({ id: 10 })],
          guests: [guest(100, 10)],
        }),
        "server",
      );

      expect(warn).not.toHaveBeenCalled();
      expect(notifyError).not.toHaveBeenCalled();
    });

    it("is not reported when it is in the copy saved on the device", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();
      idbKeyval.get.mockResolvedValueOnce(
        mealPayload({
          id: 2,
          residents: [resident({ id: 10 })],
          guests: [{ ...guest(100, 999), meal_id: 2 }],
        }),
      );
      // The server's answer does not come in this test.
      stubAction(store, "loadDataAsync");

      store.switchMeals(2);
      await flush();

      expect(store.meal.id).toBe(2);
      expect(store.guests.size).toBe(1);
      expect(warn).toHaveBeenCalledWith(WARNING, [999]);
      expect(notifyError).not.toHaveBeenCalled();
    });
  });

  describe("the meal's channel", () => {
    function handlersFor(name, event) {
      return channels
        .get(name)
        .bind.mock.calls.filter(([bound]) => bound === event);
    }

    it("refetches the meal when its channel says update", () => {
      const store = createStore();
      store.loadData(mealPayload(), "server");
      const loadDataAsync = stubAction(store, "loadDataAsync");

      const update = handlersFor("meal-1", "update");
      expect(update).toHaveLength(1);
      update[0][1]();

      expect(loadDataAsync).toHaveBeenCalledTimes(1);
    });

    // A push sent before Pusher confirmed the subscription reached no
    // one, and the meal on screen may have been read before that (#112).
    it("fetches the meal once more when Pusher confirms the subscription", () => {
      const store = createStore();
      store.loadData(mealPayload(), "server");
      const loadDataAsync = stubAction(store, "loadDataAsync");

      const confirmed = handlersFor("meal-1", "pusher:subscription_succeeded");
      expect(confirmed).toHaveLength(1);
      confirmed[0][1]();

      expect(loadDataAsync).toHaveBeenCalledTimes(1);
    });

    // Closing the channel and opening it again on every refetch would
    // miss a push sent in between, and each new subscription's
    // confirmation would fetch again, and again.
    it("stays open, and is opened once, while the same meal is fetched again", () => {
      const store = createStore();

      store.loadData(mealPayload({ description: "First" }), "server");
      store.loadData(mealPayload({ description: "Second" }), "server");

      expect(window.Comeals.pusher.subscribe.mock.calls).toEqual([
        ["meal-1"],
        [`community-test-community-id-residents`],
      ]);
      expect(window.Comeals.pusher.unsubscribe).not.toHaveBeenCalled();
      expect(window.Comeals.mealChannel.name).toBe("meal-1");
    });

    it("is closed when the next meal's answer lands, and that meal's is opened", async () => {
      const store = createStore();
      store.loadData(mealPayload(), "server");
      stubAction(store, "loadDataAsync");
      store.switchMeals(2);
      await flush();

      store.loadData(mealPayload({ id: 2 }), "server");

      expect(window.Comeals.pusher.unsubscribe.mock.calls).toEqual([
        ["meal-1"],
      ]);
      expect(window.Comeals.mealChannel.name).toBe("meal-2");
      expect(handlersFor("meal-2", "update")).toHaveLength(1);
    });
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

  // The page reads the meal's copy on the device before it asks the
  // server. In WebKit an IndexedDB read can stop answering, neither
  // value nor error, and then the page said "loading..." forever. So
  // the read has a time limit (#132). Fake timers here: the tests step
  // past the limit instead of waiting for it.
  describe("a copy on the device that is not read in time", () => {
    beforeEach(() => {
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      axios.get.mockImplementation(() =>
        Promise.resolve({
          status: 200,
          data: mealPayload({ id: 2, description: "Fetched" }),
        }),
      );
    });

    // Back to the shared mock's default, so no answer is left for the
    // next test.
    afterEach(() => {
      axios.get.mockImplementation(() =>
        Promise.resolve({ status: 200, data: {} }),
      );
    });

    it("asks the server when the read never answers", async () => {
      const store = createStore();
      idbKeyval.get.mockImplementationOnce(() => new Promise(() => {}));

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(2000);

      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/2/cooks");
      expect(store.meal.description).toBe("Fetched");
      expect(store.mealLoading).toBe(false);
    });

    it("draws the copy first when the read answers just inside the limit", async () => {
      const store = createStore();
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);
      axios.get.mockImplementationOnce(() => new Promise(() => {}));

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(DEVICE_READ_LIMIT_MS - 1);
      expect(axios.get).not.toHaveBeenCalled();
      read.resolve(mealPayload({ id: 2, description: "Saved copy" }));
      await vi.advanceTimersByTimeAsync(2000);

      expect(store.meal.description).toBe("Saved copy");
      expect(axios.get).toHaveBeenCalledTimes(1);
    });

    it("keeps the server's meal when the read answers after the server", async () => {
      const store = createStore();
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(2000);
      read.resolve(mealPayload({ id: 2, description: "Old copy" }));
      await vi.advanceTimersByTimeAsync(2000);

      expect(store.meal.description).toBe("Fetched");
      expect(axios.get).toHaveBeenCalledTimes(1);
    });
  });

  // The copy on disk only makes the next visit faster. When IndexedDB
  // fails (a tab open for weeks can lose it), the fetched meal must
  // still reach the screen, not leave it on "loading..." (#111).
  it("shows the fetched meal when the cache write fails, and logs the failure", async () => {
    const store = createStore();
    axios.get.mockResolvedValueOnce({
      status: 200,
      data: mealPayload({ description: "Fetched" }),
    });
    const diskClosed = new Error("IndexedDB is closed");
    idbKeyval.set.mockRejectedValueOnce(diskClosed);

    store.loadDataAsync();
    await flush();

    expect(store.meal.description).toBe("Fetched");
    expect(store.mealLoading).toBe(false);
    expect(console.error).toHaveBeenCalledWith(
      "IndexedDB failed; going on without the copy on disk:",
      diskClosed,
    );
  });

  // An answer the page cannot use (processing it throws) is a bug, not
  // a network state: it goes to Bugsnag and nothing retries it. On the
  // first load the page would say "loading..." forever, so it is marked
  // broken for LoadStatus instead (#110).
  describe("an answer the page cannot use", () => {
    // A 200 with no id: reading response.data.id throws.
    const unusable = { status: 200, data: {} };

    it("on the first load: marks the load broken, logs it, and reports it", async () => {
      const store = createStore();
      axios.get.mockResolvedValueOnce(unusable);

      store.loadDataAsync();
      await flush();

      expect(store.mealLoadBroken).toBe(true);
      expect(store.mealLoading).toBe(true);
      const [reported] = notifyError.mock.calls[0];
      expect(reported).toBeInstanceOf(TypeError);
      expect(notifyError.mock.calls).toEqual([[reported]]);
      expect(console.error).toHaveBeenCalledWith(
        "Could not use the meal from the server:",
        reported,
      );
    });

    it("stops a pending retry: nothing fetches on its own after that", () => {
      vi.useFakeTimers();
      const store = createStore();
      const loadDataAsync = stubAction(store, "loadDataAsync");
      store.handleMealLoadError({ response: { status: 500 } }, 1);
      expect(store.mealLoadFailed).toBe(true);

      store.handleMealProcessingError(new TypeError("no id"), 1);
      vi.advanceTimersByTime(60000);

      expect(store.mealLoadBroken).toBe(true);
      expect(store.mealLoadFailed).toBe(false);
      expect(store.mealRetryTimer).toBeNull();
      expect(loadDataAsync).not.toHaveBeenCalled();
    });

    it("with data already on screen: reports it, and shows no notice", () => {
      const store = createStore();
      stage(store, () => {
        store.mealLoading = false;
      });
      const error = new TypeError("no id");

      store.handleMealProcessingError(error, 1);

      expect(store.mealLoadBroken).toBe(false);
      expect(notifyError).toHaveBeenCalledWith(error);
    });

    it("for a meal no longer on screen, or with no meal: reports it, and shows no notice", () => {
      const store = createStore();

      store.handleMealProcessingError(new TypeError("no id"), 999);
      stage(store, () => {
        store.meal = null;
      });
      store.handleMealProcessingError(new TypeError("no id"), 1);

      expect(store.mealLoadBroken).toBe(false);
      expect(notifyError).toHaveBeenCalledTimes(2);
    });

    it("the notice goes when the screen moves to another meal", async () => {
      const store = createStore();
      stubAction(store, "loadDataAsync");
      store.handleMealProcessingError(new TypeError("no id"), 1);
      expect(store.mealLoadBroken).toBe(true);

      store.switchMeals(2);

      expect(store.mealLoadBroken).toBe(false);
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
      const loadDataAsync = stubAction(store, "loadDataAsync");

      store.scheduleMealRetry(1);
      expect(store.mealRetryDelayMs).toBe(2000);
      store.scheduleMealRetry(1);
      expect(store.mealRetryDelayMs).toBe(4000);

      // The first timer is gone: nothing fires at 2 seconds. If it
      // fired, it would fetch once too often and drop the handle of the
      // second timer, which nothing could then cancel.
      vi.advanceTimersByTime(2000);
      expect(loadDataAsync).not.toHaveBeenCalled();
      // Only the second one fires, at 4 seconds.
      vi.advanceTimersByTime(2000);
      expect(loadDataAsync).toHaveBeenCalledTimes(1);
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

    // #174. A fetch with data already on screen (a push, a Cancel that
    // settled) gets one more try after a wait. Without it, the screen
    // shows the old rows until the next push or reconnect.
    describe("a fetch that fails with data on screen", () => {
      function storeWithDataOnScreen() {
        const store = createStore();
        stage(store, () => {
          store.mealLoading = false;
        });
        return store;
      }

      it("is tried once more after a wait, and the answer is shown", async () => {
        vi.useFakeTimers();
        const store = storeWithDataOnScreen();
        axios.get
          .mockRejectedValueOnce({ response: { status: 500 } })
          .mockResolvedValueOnce({
            status: 200,
            data: mealPayload({ description: "Soup" }),
          });

        store.loadDataAsync();
        await vi.advanceTimersByTimeAsync(0);
        expect(axios.get).toHaveBeenCalledTimes(1);

        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS - 1);
        expect(axios.get).toHaveBeenCalledTimes(1);
        await vi.advanceTimersByTimeAsync(1);
        expect(axios.get).toHaveBeenCalledTimes(2);
        await vi.advanceTimersByTimeAsync(0);
        expect(store.meal.description).toBe("Soup");
        expect(store.mealLoadFailed).toBe(false);
      });

      it("is tried only once: when that try fails too, nothing fetches on its own", async () => {
        vi.useFakeTimers();
        const store = storeWithDataOnScreen();
        axios.get.mockRejectedValue({ response: { status: 500 } });

        store.loadDataAsync();
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS);
        expect(axios.get).toHaveBeenCalledTimes(2);
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS * 10);

        expect(axios.get).toHaveBeenCalledTimes(2);
        // The rows on screen stay; no notice covers them.
        expect(store.mealLoadFailed).toBe(false);
        axios.get.mockReset();
      });

      it("is tried again after the next push, when that fetch fails too", async () => {
        vi.useFakeTimers();
        const store = storeWithDataOnScreen();
        axios.get.mockRejectedValue({ response: { status: 500 } });

        store.loadDataAsync();
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS);
        store.loadDataAsync();
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS);

        expect(axios.get).toHaveBeenCalledTimes(4);
        axios.get.mockReset();
      });

      it("is not tried again for a 404, or once the person left the meal", async () => {
        vi.useFakeTimers();
        const store = storeWithDataOnScreen();
        const loadDataAsync = stubAction(store, "loadDataAsync");

        store.handleMealLoadError({ response: { status: 404 } }, 1);
        store.handleMealLoadError({ response: { status: 500 } }, 1);
        stage(store, () => {
          store.meals.push({ id: 2 });
          store.meal = 2;
        });
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS);

        expect(loadDataAsync).not.toHaveBeenCalled();
      });

      it("is tried once for two failures that come during the same wait", async () => {
        vi.useFakeTimers();
        const store = storeWithDataOnScreen();
        const loadDataAsync = stubAction(store, "loadDataAsync");

        store.handleMealLoadError({ response: { status: 500 } }, 1);
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS - 1);
        store.handleMealLoadError({ request: {} }, 1);
        await vi.advanceTimersByTimeAsync(1);
        expect(loadDataAsync).toHaveBeenCalledExactlyOnceWith({
          afterRefetchRetry: true,
        });
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS);

        expect(loadDataAsync).toHaveBeenCalledTimes(1);
      });

      it("has its wait stopped when the meal on screen changes", async () => {
        vi.useFakeTimers();
        const store = storeWithDataOnScreen();
        const loadDataAsync = stubAction(store, "loadDataAsync");

        store.handleMealLoadError({ response: { status: 500 } }, 1);
        store.cancelMealRetry();
        await vi.advanceTimersByTimeAsync(MEAL_REFETCH_RETRY_MS);

        expect(loadDataAsync).not.toHaveBeenCalled();
      });
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
