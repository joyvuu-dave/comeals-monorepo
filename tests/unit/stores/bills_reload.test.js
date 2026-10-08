import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
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
import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import { BOB, CAROL, billsServer, mealIdOf } from "../helpers/bills_server.js";
import { SAVE_DEBOUNCE_MS } from "../../../app/frontend/src/helpers/helpers.js";

// The page does not build a meal's rows again from the server while it
// has a bills edit for that meal the server may not have yet: typed and
// not sent, or sent and not answered. It fetches the meal once nothing
// is pending for it (#136, design 3.9 of #135).

// The shared mocks keep what a test set for them, so each test starts
// from the defaults the mock files define.
afterEach(() => {
  [axios, axios.get, idbKeyval.get, idbKeyval.set].forEach((mock) =>
    mock.mockReset(),
  );
});

// The red test from issue #136, as the issue gives it, with one line
// moved: the check that Bob's row still shows "50" now comes before the
// save is sent. Once the save is answered, the page fetches the meal the
// push asked for, and this test's server still answers $0 then (it does
// not store saves). The tests below use a server that does.
function payload() {
  return {
    id: 1,
    date: "2023-06-15",
    description: "",
    closed: false,
    closed_at: null,
    reconciled: false,
    max: null,
    next_id: 1,
    prev_id: 1,
    residents: [
      {
        id: 11,
        meal_id: 1,
        name: "Bob",
        short_name: "Bob",
        attending: false,
        attending_at: null,
        late: false,
        vegetarian: false,
        can_cook: true,
        active: true,
      },
    ],
    guests: [],
    bills: [{ resident_id: 11, amount: "0.0", no_cost: false }],
  };
}

describe("a live update of the meal while a cost is typed but not sent", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_PUSHER_KEY", "k");
    vi.useFakeTimers();
  });
  afterEach(() => vi.useRealTimers());
  it("still sends the typed cost", async () => {
    const store = createDataStore({ mealProps: { closed: false } });
    store.loadData(payload(), "server");
    axios.get.mockResolvedValue({ status: 200, data: payload() });
    const bob = () =>
      Array.from(store.bills.values()).find(
        (b) => b.resident && b.resident.id === 11,
      );
    bob().setAmount("50"); // in the debounce window
    store.loadDataAsync(); // what the meal channel's "update" handler calls
    await vi.advanceTimersByTimeAsync(0);
    expect(bob().amount).toBe("50");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    const patches = axios.mock.calls.filter(([c]) => c && c.method === "patch");
    expect(patches.length).toBe(1);
    // The issue checked the full list of cooks the page sent then. A
    // save now sends edits (#135).
    expect(patches[0][0].data.edits).toEqual([
      {
        op: "change",
        resident_id: 11,
        from: { amount: "", no_cost: false },
        to: { amount: "50", no_cost: false },
      },
    ]);
  });
});

describe("the meal is not loaded again while a bills edit for it is pending", () => {
  const RESIDENTS_CHANNEL = "community-test-community-id-residents";

  // The stand-in server: it applies a save the way the real one does,
  // and every save waits until the test answers it.
  let server;
  // The bills the stand-in server has, by meal id, then by cook id.
  let stored;

  beforeEach(() => {
    vi.stubEnv("VITE_PUSHER_KEY", "k");
    vi.useFakeTimers();
    server = billsServer(axios);
    server.install();
    stored = server.stored;
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  function answerSave() {
    return server.answerSave();
  }

  function failSave(error) {
    return server.failSave(error);
  }

  // The next fetch of a meal is read by the server now, and its answer
  // reaches the page when the test says so.
  function holdNextFetch() {
    let answer;
    axios.get.mockImplementationOnce((url) => {
      const data = server.mealForm(mealIdOf(url));
      return new Promise((resolve) => {
        answer = () => resolve({ status: 200, data });
      });
    });
    return async () => {
      answer();
      await vi.advanceTimersByTimeAsync(0);
    };
  }

  function mealFetches(mealId = 1) {
    return axios.get.mock.calls.filter(
      ([url]) => url === `/api/v1/meals/${mealId}/cooks`,
    ).length;
  }

  // The amount each bills save sent for Bob, oldest first.
  function amountsSentForBob() {
    return axios.mock.calls
      .map(([config]) =>
        config.data.edits.find((edit) => edit.resident_id === BOB),
      )
      .map((edit) => edit.to.amount);
  }

  // Pusher channels by name, so a test can run what a channel bound,
  // the same thing a real push does.
  let channels;

  // Meal 1 on screen, loaded from the server.
  function createStore() {
    const store = createDataStore({ mealProps: { closed: false } });
    channels = new Map();
    vi.spyOn(window.Comeals.pusher, "subscribe").mockImplementation((name) => {
      const channel = { name, bind: vi.fn() };
      channels.set(name, channel);
      return channel;
    });
    vi.spyOn(window.Comeals.pusher, "unsubscribe").mockImplementation(() => {});
    // A reconnect fetches the calendar month too. No calendar is on
    // screen in these tests.
    stubAction(store, "loadMonthAsync");
    store.loadData(server.mealForm(1), "server");
    return store;
  }

  function fire(channelName, event) {
    channels
      .get(channelName)
      .bind.mock.calls.filter(([bound]) => bound === event)
      .forEach(([, handler]) => handler());
  }

  function rowOf(store, residentId) {
    return Array.from(store.bills.values()).find(
      (bill) => bill.resident !== null && bill.resident.id === residentId,
    );
  }

  // Everything that fetches the meal on screen again, other than a save
  // that failed (#136).
  const TRIGGERS = [
    ["a push on the meal's channel", () => fire("meal-1", "update")],
    [
      "Pusher confirming the meal's channel (#112)",
      () => fire("meal-1", "pusher:subscription_succeeded"),
    ],
    ["the connection coming back", (store) => store.handleReconnect()],
    [
      "a push on the residents channel",
      () => fire(RESIDENTS_CHANNEL, "update"),
    ],
  ];

  it.each(TRIGGERS)(
    "%s does not load the meal while a cost waits to be saved or for its answer, and loads it once after the answer",
    async (_label, trigger) => {
      const store = createStore();

      rowOf(store, BOB).setAmount("50"); // in the wait before its save
      trigger(store);
      await vi.advanceTimersByTimeAsync(0);
      expect(mealFetches()).toBe(0);
      expect(rowOf(store, BOB).amount).toBe("50");

      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // the save is sent
      trigger(store);
      await vi.advanceTimersByTimeAsync(0);
      expect(mealFetches()).toBe(0);
      expect(amountsSentForBob()).toEqual(["50"]);

      await answerSave();
      expect(mealFetches()).toBe(1);
      // The rows were built again from the server's answer.
      expect(rowOf(store, BOB).amount).toBe("50.00");
    },
  );

  // A save sent while another has no answer waits, and is sent when
  // that one is answered (billsSaveQueued).
  it("does not load the meal while a cost waits behind a save that has no answer", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // the $5 save is sent
    rowOf(store, BOB).setAmount("50");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits for it

    fire("meal-1", "update");
    await answerSave(); // the $50 save is sent
    fire("meal-1", "update");
    await vi.advanceTimersByTimeAsync(0);
    expect(mealFetches()).toBe(0);
    expect(amountsSentForBob()).toEqual(["5", "50"]);

    await answerSave();
    expect(mealFetches()).toBe(1);
    expect(rowOf(store, BOB).amount).toBe("50.00");
  });

  // #136, the first comment. The $5 save is refused, so the page
  // fetches the meal to show what the server has. It does that after
  // the $50 typed behind it is sent, not before: a fetch first would
  // build the rows again, and the $50 would never be sent. (The $50
  // save is built on the $5 the server never stored, so it is refused
  // too, with a message, and the meal then shows what the server has.)
  it("does not load the meal after a failed save until the cost typed behind it is sent", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // the $5 save is sent
    rowOf(store, BOB).setAmount("50"); // in the wait before its save

    await failSave({
      response: {
        status: 400,
        data: { message: "Invalid cook assignment." },
      },
    });
    expect(mealFetches()).toBe(0);
    expect(rowOf(store, BOB).amount).toBe("50");

    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    expect(amountsSentForBob()).toEqual(["5", "50"]);
    await answerSave();
    expect(mealFetches()).toBe(1);
    expect(rowOf(store, BOB).amount).toBe("");
  });

  describe("an answer to a fetch sent before a cost was typed", () => {
    it("does not wipe the cost or go to the device, and the meal is fetched again after the cost is saved", async () => {
      const store = createStore();
      const answerFetch = holdNextFetch();
      fire("meal-1", "update"); // the server reads Bob's $0
      rowOf(store, BOB).setAmount("50");

      await answerFetch();
      expect(rowOf(store, BOB).amount).toBe("50");
      expect(idbKeyval.set).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      await answerSave();
      expect(mealFetches()).toBe(2);
      expect(rowOf(store, BOB).amount).toBe("50.00");
    });

    // Nothing is pending when the old answer arrives, but it was read
    // before the cost was saved, so it would show the old cost.
    it("is not used even when the cost was saved before it arrived; the meal is fetched again at once", async () => {
      const store = createStore();
      const answerFetch = holdNextFetch();
      fire("meal-1", "update"); // the server reads Bob's $0
      rowOf(store, BOB).setAmount("50");
      store.flushPendingBillsSave(); // the field loses focus
      await answerSave();
      expect(mealFetches()).toBe(1);

      await answerFetch();
      expect(mealFetches()).toBe(2);
      expect(rowOf(store, BOB).amount).toBe("50.00");
    });

    it("is not used when the cost is typed while the answer is written to the device", async () => {
      const store = createStore();
      let finishWrite;
      idbKeyval.set.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finishWrite = resolve;
          }),
      );
      fire("meal-1", "update");
      await vi.advanceTimersByTimeAsync(0); // the answer is being written
      expect(idbKeyval.set).toHaveBeenCalledTimes(1);

      rowOf(store, BOB).setAmount("50");
      finishWrite();
      await vi.advanceTimersByTimeAsync(0);
      expect(rowOf(store, BOB).amount).toBe("50");

      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      await answerSave();
      expect(mealFetches()).toBe(2);
      expect(rowOf(store, BOB).amount).toBe("50.00");
    });
  });

  // #135, the second comment. Bob's $5 save has no answer. The person
  // picks Carol as a second cook and types $50, which waits for the $5
  // save. They go to meal 2 and come back. Before #136's fix, coming
  // back built meal 1's rows from a server that did not have Carol yet,
  // and the next save, which listed every cook the page showed, deleted
  // her $50. A save now names only the cooks it changes, and the rows
  // load only after both saves are answered, so the $6 save is built on
  // the $5 the server has.
  it("shows a meal the person comes back to as loading until its saves are answered, then loads it with every cook those saves sent", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // the $5 save is sent
    const blankRow = Array.from(store.bills.values()).find(
      (bill) => bill.resident === null,
    );
    blankRow.setResident(store.residents.get(String(CAROL)));
    rowOf(store, CAROL).setAmount("50");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits

    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    expect(store.mealLoading).toBe(false);
    idbKeyval.get.mockClear();

    store.goToMeal(1);
    await vi.advanceTimersByTimeAsync(0);
    expect(store.mealLoading).toBe(true);
    expect(store.bills.size).toBe(0);
    expect(idbKeyval.get).not.toHaveBeenCalled(); // no copy from the device
    expect(mealFetches(1)).toBe(0);

    await answerSave(); // Bob's $5; then the save made on leaving is sent
    expect(mealFetches(1)).toBe(0);
    await answerSave(); // Bob's $5 and Carol's $50
    expect(mealFetches(1)).toBe(1);
    expect(store.mealLoading).toBe(false);
    expect(rowOf(store, BOB).amount).toBe("5.00");
    expect(rowOf(store, CAROL).amount).toBe("50.00");

    rowOf(store, BOB).setAmount("6");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    await answerSave();
    expect(stored[1]).toEqual({
      [BOB]: { amount: "6", no_cost: false },
      [CAROL]: { amount: "50", no_cost: false },
    });
  });

  // Meal 1's save is in flight when the person goes to meal 2 and types
  // a cost there. Meal 2's save waits behind meal 1's, and when the
  // person leaves meal 2 it waits for meal 2. They go back to meal 2
  // before it is sent.
  it("does not load a meal whose save waits behind another meal's save", async () => {
    stored[2] = { [BOB]: { amount: "7.0", no_cost: false } };
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // meal 1's save is sent
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
    rowOf(store, BOB).setAmount("8");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits for meal 1's
    store.goToMeal(1);
    await vi.advanceTimersByTimeAsync(0);

    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    expect(store.mealLoading).toBe(true);
    expect(store.bills.size).toBe(0);
    expect(mealFetches(2)).toBe(1); // only the first visit

    await answerSave(); // meal 1's; then meal 2's is sent
    expect(mealFetches(2)).toBe(1);
    await answerSave();
    expect(mealFetches(2)).toBe(2);
    expect(rowOf(store, BOB).amount).toBe("8.00");
  });

  // Meal 2's save has no answer. On meal 1, a push sends a fetch of
  // meal 1 that is slow, and a cost typed there waits behind meal 2's
  // save. The person goes back to meal 2, which shows loading until its
  // save is answered. Then the old answer for meal 1 arrives. It is
  // dropped, and it must not stop meal 2 from loading after its save is
  // answered.
  it("loads the meal on screen once its save is answered, even when an old answer for a meal the person left arrives first", async () => {
    stored[2] = { [BOB]: { amount: "7.0", no_cost: false } };
    const store = createStore();
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
    rowOf(store, BOB).setAmount("8");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // meal 2's save is sent

    store.goToMeal(1);
    await vi.advanceTimersByTimeAsync(0); // meal 1's rows load
    const answerFetch = holdNextFetch();
    fire("meal-1", "update"); // a fetch of meal 1 is sent, and is slow
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits for meal 2's save

    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    expect(store.mealLoading).toBe(true);
    await answerFetch(); // the old answer for meal 1
    expect(store.bills.size).toBe(0);

    await answerSave(); // meal 2's $8; then meal 1's $5 is sent
    await answerSave(); // meal 1's $5
    expect(mealFetches(2)).toBe(2);
    expect(store.mealLoading).toBe(false);
    expect(rowOf(store, BOB).amount).toBe("8.00");
    expect(stored[1][BOB].amount).toBe("5");
  });

  // A row's base says what the server will have once the saves already
  // built are stored. A save is built only when it is sent, so a cost
  // typed while a save has no answer leaves its row's base alone. If
  // that base moved to the new cost before any save carried it, the page
  // would count the cost as sent, and a save built from the bases would
  // not send it.
  it("keeps a cost that waits behind a save with no answer unsent, with its base at the cost that was sent", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // the $5 save is sent
    rowOf(store, BOB).setAmount("50");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits for it

    expect(amountsSentForBob()).toEqual(["5"]);
    expect(rowOf(store, BOB).unsent).toBe(true);
    expect(rowOf(store, BOB).baseAmount).toBe("5");

    await answerSave(); // the $50 save is sent
    expect(amountsSentForBob()).toEqual(["5", "50"]);
    expect(rowOf(store, BOB).unsent).toBe(false);
  });

  // Meal 2's save has no answer, and on meal 1 a cost waits behind it.
  // A push on meal 1 must not build meal 1's rows again before that
  // cost is sent: the new rows would not have it, and the save that
  // waits would send none.
  it("does not load the meal while a cost on it waits behind another meal's save", async () => {
    stored[2] = { [BOB]: { amount: "7.0", no_cost: false } };
    const store = createStore();
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
    rowOf(store, BOB).setAmount("8");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // meal 2's save is sent
    store.goToMeal(1);
    await vi.advanceTimersByTimeAsync(0); // meal 1's rows load
    expect(mealFetches(1)).toBe(1);
    rowOf(store, BOB).setAmount("50");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits for meal 2's save

    fire("meal-1", "update");
    await vi.advanceTimersByTimeAsync(0);
    expect(mealFetches(1)).toBe(1);
    expect(rowOf(store, BOB).amount).toBe("50");

    await answerSave(); // meal 2's $8; then meal 1's $50 is sent
    await answerSave(); // meal 1's $50
    expect(stored[1][BOB].amount).toBe("50");
    expect(mealFetches(1)).toBe(2);
    expect(rowOf(store, BOB).amount).toBe("50.00");
  });

  // One cook picked in two rows: no save can be built, so the edits stay
  // on the rows with nothing to carry them. A fetch would build the
  // rows again and drop them.
  it("does not load the meal while rows show what no save can send, and loads it once they show what the server has", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("50");
    const blankRow = Array.from(store.bills.values()).find(
      (bill) => bill.resident === null,
    );
    blankRow.setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // refused: no save
    expect(server.saves).toHaveLength(0);
    fire("meal-1", "update");
    await vi.advanceTimersByTimeAsync(0);
    expect(mealFetches()).toBe(0);
    expect(rowOf(store, BOB).amount).toBe("50");

    blankRow.setResident("");
    rowOf(store, BOB).setAmount("");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // nothing to send
    expect(server.saves).toHaveLength(0);
    expect(mealFetches()).toBe(1);
  });
});
