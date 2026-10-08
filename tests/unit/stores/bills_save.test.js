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
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag.js";
import toastStore from "../../../app/frontend/src/stores/toast_store";
import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import { BOB, CAROL, billsServer, editsSent } from "../helpers/bills_server.js";
import { SAVE_DEBOUNCE_MS } from "../../../app/frontend/src/helpers/helpers.js";

// A bills save sends edits: one per cook it changes, each with the bill
// the page saw for that cook (#135, docs/adr/0009-bills-saves-send-edits.md).
// Each row keeps a base, the bill the server has for its cook as far as
// the page knows, and a save is the difference between the rows and
// their bases. Every save carries an Idempotency-Key, and a save that
// failed in a way that may not be final is sent once more with the same
// key (decision 7 of #135).

let server;

beforeEach(() => {
  vi.stubEnv("VITE_PUSHER_KEY", "k");
  vi.useFakeTimers();
  vi.clearAllMocks();
  toastStore.clearAll();
  server = billsServer(axios);
  server.install();
});

afterEach(() => {
  vi.useRealTimers();
  [axios, axios.get, idbKeyval.get, idbKeyval.set].forEach((mock) =>
    mock.mockReset(),
  );
});

// Meal 1 on screen, loaded from the stand-in server.
function createStore() {
  const store = createDataStore({ mealProps: { closed: false } });
  // A reconnect fetches the calendar month too. No calendar is on
  // screen in these tests.
  stubAction(store, "loadMonthAsync");
  store.loadData(server.mealForm(1), "server");
  return store;
}

function rowOf(store, residentId) {
  return Array.from(store.bills.values()).find(
    (bill) => bill.resident !== null && bill.resident.id === residentId,
  );
}

function blankRows(store) {
  return Array.from(store.bills.values()).filter(
    (bill) => bill.resident === null,
  );
}

function blankRow(store) {
  return blankRows(store)[0];
}

// Type a cost and wait out the debounce, so its save is sent (or waits
// for the save in flight).
async function typeCost(store, residentId, amount) {
  rowOf(store, residentId).setAmount(amount);
  await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
}

function keysSent() {
  return axios.mock.calls.map(([config]) => config.headers["Idempotency-Key"]);
}

function mealFetches(mealId = 1) {
  return axios.get.mock.calls.filter(
    ([url]) => url === `/api/v1/meals/${mealId}/cooks`,
  ).length;
}

function toastsOnScreen() {
  return toastStore.toasts.map((toast) => [toast.type, toast.message]);
}

function change(residentId, from, to) {
  return {
    op: "change",
    resident_id: residentId,
    from: { amount: from, no_cost: false },
    to: { amount: to, no_cost: false },
  };
}

const PLAIN_CONFLICT = {
  response: {
    status: 409,
    data: {
      message:
        "Someone else was changing this meal at the same time. Nothing was saved. Try again.",
    },
  },
};

describe("what a bills save sends", () => {
  it("sends the edits, with an Idempotency-Key and a 35 second timeout, and nothing else", async () => {
    const store = createStore();
    window.Comeals.socketId = "123.456";

    await typeCost(store, BOB, "5");

    expect(axios).toHaveBeenCalledTimes(1);
    const [config] = axios.mock.calls[0];
    expect(config.method).toBe("patch");
    expect(config.url).toBe("/api/v1/meals/1/bills");
    expect(config.timeout).toBe(35000);
    expect(config.headers["Idempotency-Key"]).toMatch(/^"[^"\\]+"$/);
    expect(config.data).toEqual({
      edits: [change(BOB, "", "5")],
      socket_id: "123.456",
    });
  });

  it("sends a new key with each save", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await server.answerSave();
    await typeCost(store, BOB, "6");

    const [first, second] = keysSent();
    expect(second).not.toBe(first);
  });

  it("sends nothing when the cost is typed back to what the server has before the save goes", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await typeCost(store, BOB, "");

    expect(axios).not.toHaveBeenCalled();
  });

  // The save that waits is built only when the save in flight is
  // answered, from the bases that save moved, so it names only what
  // changed after that save was built.
  it("sends a cost typed behind a save in flight as a change from what that save sent", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await typeCost(store, BOB, "50");
    await server.answerSave();
    await server.answerSave();

    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(BOB, "5", "50")],
    ]);
    expect(server.stored[1][BOB]).toEqual({ amount: "50", no_cost: false });
  });

  // #107: the save made on leaving a meal is built from its rows then,
  // while the $5 save has no answer, and goes after it.
  it("builds the save for a meal left on top of the save in flight", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await typeCost(store, BOB, "50");
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    await server.answerSave();
    await server.answerSave();

    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(BOB, "5", "50")],
    ]);
    expect(server.stored[1][BOB]).toEqual({ amount: "50", no_cost: false });
  });

  it("adds a cook picked in a blank row, and removes a cook taken off a row", async () => {
    const store = createStore();
    blankRow(store).setResident(store.residents.get(String(CAROL)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    await server.answerSave();
    rowOf(store, BOB).setResident("");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    await server.answerSave();

    expect(editsSent(axios)).toEqual([
      [{ op: "add", resident_id: CAROL, to: { amount: "", no_cost: false } }],
      [
        {
          op: "remove",
          resident_id: BOB,
          from: { amount: "", no_cost: false },
        },
      ],
    ]);
    expect(server.stored[1]).toEqual({
      [CAROL]: { amount: "0.0", no_cost: false },
    });
  });

  // #135: another page added Xavier after this page loaded. A save from
  // this page does not name him, so the server keeps his bill.
  it("never names a cook the page does not show, so another page's cook stays", async () => {
    const store = createStore();
    server.stored[1][77] = { amount: "30.0", no_cost: false };

    await typeCost(store, BOB, "25");
    await server.answerSave();

    expect(editsSent(axios)).toEqual([[change(BOB, "", "25")]]);
    expect(server.stored[1]).toEqual({
      [BOB]: { amount: "25", no_cost: false },
      77: { amount: "30.0", no_cost: false },
    });
  });
});

// #91. The meal form lists every cook who has a bill, so a bill the page
// cannot show is a bug, and loadData reports it. A save never names that
// cook, so it cannot delete the bill, and saves go on.
describe("a bill whose cook is not in the residents list", () => {
  const HIDDEN_COOK = 999;

  it("is never named, so it stays, and the other cooks' saves are sent", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    server.stored[1][HIDDEN_COOK] = { amount: "40.0", no_cost: false };
    const store = createStore();
    expect(warn).toHaveBeenCalledWith(
      "These cooks have a bill but are not in the residents list, so the page does not show their bills:",
      [HIDDEN_COOK],
    );
    expect(notifyError).toHaveBeenCalledTimes(1);

    await typeCost(store, BOB, "50");
    await server.answerSave();

    expect(editsSent(axios)).toEqual([[change(BOB, "", "50")]]);
    expect(server.stored[1][HIDDEN_COOK]).toEqual({
      amount: "40.0",
      no_cost: false,
    });
    expect(toastsOnScreen()).toEqual([]);
    warn.mockRestore();
  });
});

describe("one cook picked in two rows", () => {
  const TWO_ROWS =
    "Bob is picked in two rows, so nothing was saved. Pick another cook in one of them.";

  it("sends nothing, and says which cook", async () => {
    const store = createStore();
    blankRow(store).setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

    expect(axios).not.toHaveBeenCalled();
    expect(toastsOnScreen()).toEqual([["error", TWO_ROWS]]);
  });

  it("sends the edits once one of the rows shows another cook", async () => {
    const store = createStore();
    const second = blankRow(store);
    second.setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    second.setResident(store.residents.get(String(CAROL)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

    expect(editsSent(axios)).toEqual([
      [{ op: "add", resident_id: CAROL, to: { amount: "", no_cost: false } }],
    ]);
  });

  // #137: the page made this check itself, not the server. So the
  // message is the one error that does not wait for the person to close
  // it: it goes as soon as the page sees the cause fixed.
  describe("once the rows no longer show the cook twice", () => {
    const MEAL_1_NOT_SAVED =
      "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.";

    // Bob is picked in the loaded row and in a second one, and the
    // refusal shows. Returns the second row.
    async function bobInTwoRows(store) {
      const second = blankRow(store);
      second.setResident(store.residents.get(String(BOB)));
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      expect(toastsOnScreen()).toEqual([["error", TWO_ROWS]]);
      return second;
    }

    it.each([
      ["another cook", (store) => store.residents.get(String(CAROL))],
      ["no cook", () => ""],
    ])(
      "takes the message away as soon as one of the rows shows %s",
      async (_label, pick) => {
        const store = createStore();
        const second = await bobInTwoRows(store);

        second.setResident(pick(store));

        expect(toastsOnScreen()).toEqual([]);
      },
    );

    it("keeps the message while both rows still show the cook, and takes it away once they do not", async () => {
      const store = createStore();
      const second = await bobInTwoRows(store);

      second.setAmount("5");
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      expect(toastsOnScreen()).toEqual([["error", TWO_ROWS]]);

      second.setResident(store.residents.get(String(CAROL)));
      expect(toastsOnScreen()).toEqual([]);
    });

    it("takes the message away when another cook is in two rows now, and then names that cook", async () => {
      const store = createStore();
      const second = await bobInTwoRows(store);
      const third = blankRow(store);
      third.setResident(store.residents.get(String(CAROL)));

      second.setResident(store.residents.get(String(CAROL)));
      expect(toastsOnScreen()).toEqual([]);
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

      expect(toastsOnScreen()).toEqual([
        [
          "error",
          "Carol is picked in two rows, so nothing was saved. Pick another cook in one of them.",
        ],
      ]);
    });

    it("takes away only its own message", async () => {
      const store = createStore();
      toastStore.show(MEAL_1_NOT_SAVED, "error");
      const second = blankRow(store);
      second.setResident(store.residents.get(String(BOB)));
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      expect(toastsOnScreen()).toEqual([
        ["error", TWO_ROWS],
        ["error", MEAL_1_NOT_SAVED],
      ]);

      second.setResident("");

      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
    });

    // The rows go with the meal. The message that names the meal says
    // its costs were not saved.
    it("takes the message away when the person leaves the meal", async () => {
      vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createStore();
      await bobInTwoRows(store);

      store.goToMeal(2);
      await vi.advanceTimersByTimeAsync(0);

      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
    });

    it("takes the message away when the meal's rows are built again from the server", async () => {
      const store = createStore();
      await bobInTwoRows(store);

      store.loadData(server.mealForm(1), "server");

      expect(toastsOnScreen()).toEqual([]);
    });
  });

  // The person left the meal, so the words name it, the same as any
  // other save for a meal left that was not saved (#107).
  it("names the meal when the person leaves it like that", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const store = createStore();
    blankRow(store).setResident(store.residents.get(String(BOB)));
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);

    expect(axios).not.toHaveBeenCalled();
    expect(toastsOnScreen()).toEqual([
      [
        "error",
        "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.",
      ],
    ]);
    expect(warn).toHaveBeenCalledWith(TWO_ROWS);
  });

  // The refusal leaves no wait before a save and no queued save, but the
  // rows still show edits the server does not have. Leaving the meal
  // clears the rows, so the message names the meal even when the
  // person closed the refusal's own message by then.
  it("names the meal when the person leaves it after closing the refusal's message", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const store = createStore();
    const [first, second] = blankRows(store);
    first.setResident(store.residents.get(String(CAROL)));
    first.setAmount("50");
    second.setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    expect(toastsOnScreen()).toEqual([["error", TWO_ROWS]]);
    toastStore.remove(toastStore.toasts[0].id); // the person closed it

    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);

    expect(axios).not.toHaveBeenCalled();
    expect(toastsOnScreen()).toEqual([
      [
        "error",
        "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.",
      ],
    ]);
  });

  // A "not saved" message about a meal the person left may be the only
  // sign that its costs were lost. The refusal's own words go on top of
  // it, and it stays under them (#137).
  it("shows its words on top of the message about a meal the person left that was not saved", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    server.stored[1][BOB] = { amount: "9.0", no_cost: false }; // another page
    await typeCost(store, BOB, "5");
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    await server.answerSave(); // meal 1's $5 is stale
    expect(toastsOnScreen()).toEqual([
      [
        "error",
        "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.",
      ],
    ]);

    const [first, second] = blankRows(store);
    first.setResident(store.residents.get(String(BOB)));
    second.setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

    expect(axios).toHaveBeenCalledTimes(1);
    expect(toastsOnScreen()).toEqual([
      ["error", TWO_ROWS],
      [
        "error",
        "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.",
      ],
    ]);
    expect(warn).not.toHaveBeenCalledWith(TWO_ROWS);
  });
});

// Decision 7 of #135. A 409 with no type wrote nothing for sure, and no
// answer or a 5xx leaves the page not knowing. The same save goes once
// more, with the same key, before any save built after it. If the first
// try was written, the server answers the second as replayed.
describe("a save that failed in a way that may not be final", () => {
  const AGAIN = [
    ["a 409 with no type", PLAIN_CONFLICT],
    [
      "a 503 from the router",
      { response: { status: 503, data: "<html>Application error</html>" } },
    ],
    ["no answer at all", { request: {} }],
    ["no answer before the timeout", { request: {}, code: "ECONNABORTED" }],
    ["a request that never left", new Error("Network Error")],
  ];

  it.each(AGAIN)(
    "is sent once more, unchanged and with the same key, after %s, and nothing is shown when that works",
    async (_label, error) => {
      vi.spyOn(console, "error").mockImplementation(() => {});
      const store = createStore();
      await typeCost(store, BOB, "5");
      await typeCost(store, BOB, "50"); // waits for the $5 save

      await server.failSave(error);
      expect(axios).toHaveBeenCalledTimes(2);
      expect(axios.mock.calls[1][0]).toEqual(axios.mock.calls[0][0]);

      await server.answerSave(); // the $5 save, the second time
      await server.answerSave(); // the $50 save
      expect(editsSent(axios)).toEqual([
        [change(BOB, "", "5")],
        [change(BOB, "", "5")],
        [change(BOB, "5", "50")],
      ]);
      expect(server.stored[1][BOB]).toEqual({ amount: "50", no_cost: false });
      expect(toastsOnScreen()).toEqual([]);
      expect(mealFetches()).toBe(0);
    },
  );

  // The critique's case: the $5 save was written but its answer was
  // lost, and the person set Bob back to $0 while it waited. The second
  // try is replayed, and the $0 is still sent, as a change from $5.
  it("still sends a cost set back to the old value while the first try's answer was lost", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    await typeCost(store, BOB, "5");
    await typeCost(store, BOB, "");

    await server.loseAnswer(); // the server has $5
    const replayed = await server.answerSave();
    expect(replayed.data.type).toBe("replayed");
    await server.answerSave();

    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(BOB, "", "5")],
      [change(BOB, "5", "")],
    ]);
    expect(server.stored[1][BOB]).toEqual({ amount: "0.0", no_cost: false });
    expect(toastsOnScreen()).toEqual([]);
  });

  // The same case on a meal the person left: Carol was added with $50,
  // that save was written and its answer lost, and the person took
  // Carol off again before leaving. The save made on leaving removes
  // her, from the $50 the first save sent.
  it("still removes a cook added by a save whose answer was lost, after the person took them off and left", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    const row = blankRow(store);
    row.setResident(store.residents.get(String(CAROL)));
    rowOf(store, CAROL).setAmount("50");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // add Carol $50
    row.setResident("");
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);

    await server.loseAnswer(); // the server has Carol's $50
    await server.answerSave(); // the second try is replayed
    await server.answerSave(); // the save made on leaving

    expect(editsSent(axios)[2]).toEqual([
      {
        op: "remove",
        resident_id: CAROL,
        from: { amount: "50", no_cost: false },
      },
    ]);
    expect(server.stored[1]).toEqual({
      [BOB]: { amount: "0.0", no_cost: false },
    });
    expect(toastsOnScreen()).toEqual([]);
  });

  // The second try alone decides what the person sees. When it got no
  // answer from the app, it may have been written, so the page must not
  // say that nothing was saved, whatever the first try got. The words
  // say that the costs may not have been saved, and the meal loads again
  // to show what the server has. "No answer from the app" is no answer
  // at all, or a 5xx page that has no message from the app: Rails' own
  // 500 page, or Heroku's router page.
  describe("when the second try fails too", () => {
    const MAYBE_NOT_SAVED =
      "Your cooks and costs may not have been saved. Check them when the meal shows again.";
    const NO_ANSWER = { request: {}, code: "ECONNABORTED" };
    const RAILS_500 = {
      response: {
        status: 500,
        data: "<!doctype html><html><head><title>We're sorry, but something went wrong (500)</title></head></html>",
      },
    };
    // ApiController#render_overloaded: a 5xx with a message from the app.
    const APP_BUSY = {
      response: {
        status: 503,
        data: {
          message:
            "The server is busy right now. Nothing was saved. Please try again in a moment.",
        },
      },
    };

    it.each([
      ["no answer twice", NO_ANSWER, NO_ANSWER],
      ["Rails' 500 page twice", RAILS_500, RAILS_500],
      ["no answer, then Rails' 500 page", NO_ANSWER, RAILS_500],
      // The first try wrote nothing, but the second may have.
      ["a 409 with no type, then no answer", PLAIN_CONFLICT, NO_ANSWER],
      ["the app's 503, then Rails' 500 page", APP_BUSY, RAILS_500],
    ])(
      "says the cooks and costs may not have been saved after %s, and loads the meal again",
      async (_label, first, second) => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        const store = createStore();
        await typeCost(store, BOB, "5");

        await server.failSave(first);
        expect(toastsOnScreen()).toEqual([]);
        await server.failSave(second);

        expect(axios).toHaveBeenCalledTimes(2);
        expect(toastsOnScreen()).toEqual([["error", MAYBE_NOT_SAVED]]);
        expect(mealFetches()).toBe(1);
        expect(store.mealLoading).toBe(false);
      },
    );

    // The case the words are for: the first try was written, and neither
    // answer reached the page. The meal shows the $5 again.
    it("shows the cost the server has once the meal loads again", async () => {
      vi.spyOn(console, "error").mockImplementation(() => {});
      const store = createStore();
      await typeCost(store, BOB, "5");

      await server.loseAnswer(); // the server has $5
      await server.failSave(NO_ANSWER);

      expect(toastsOnScreen()).toEqual([["error", MAYBE_NOT_SAVED]]);
      expect(rowOf(store, BOB).amount).toBe("5.00");
    });

    // When the second try's answer is the app's own words, those words
    // show, even when the first try got no answer. For a 409 with no type
    // and the app's 503, they say nothing was saved. That is true of the
    // first try too: Puma runs one thread, so the first try was finished
    // before the second was read, and if it had been written the server
    // would have answered the second as replayed.
    it.each([
      ["a 409 with no type twice", PLAIN_CONFLICT, PLAIN_CONFLICT],
      ["the app's 503 twice", APP_BUSY, APP_BUSY],
      ["no answer, then a 409 with no type", NO_ANSWER, PLAIN_CONFLICT],
      ["no answer, then the app's 503", NO_ANSWER, APP_BUSY],
    ])(
      "shows the server's words after %s, and loads the meal again",
      async (_label, first, second) => {
        vi.spyOn(console, "error").mockImplementation(() => {});
        const store = createStore();
        await typeCost(store, BOB, "5");

        await server.failSave(first);
        expect(toastsOnScreen()).toEqual([]);
        await server.failSave(second);

        expect(axios).toHaveBeenCalledTimes(2);
        expect(toastsOnScreen()).toEqual([
          ["error", second.response.data.message],
        ]);
        expect(mealFetches()).toBe(1);
        expect(rowOf(store, BOB).amount).toBe("");
        expect(store.mealLoading).toBe(false);
      },
    );

    // A message that says a save failed stays when a message that says
    // a save worked comes after it (#137). Here Carol's $50 waits behind
    // Bob's $5. Bob's save gets no answer twice, and Carol's is written
    // with the third-cook warning.
    it("keeps the words on screen, under the warning, when a save sent after it comes back with a warning", async () => {
      const THIRD_COOK =
        "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.";
      vi.spyOn(console, "error").mockImplementation(() => {});
      const store = createStore();
      await typeCost(store, BOB, "5");
      blankRow(store).setResident(store.residents.get(String(CAROL)));
      await typeCost(store, CAROL, "50"); // waits for the $5 save

      await server.failSave(NO_ANSWER);
      await server.failSave(NO_ANSWER);
      expect(toastsOnScreen()).toEqual([["error", MAYBE_NOT_SAVED]]);

      expect(editsSent(axios)[2]).toEqual([
        { op: "add", resident_id: CAROL, to: { amount: "50", no_cost: false } },
      ]);
      server.stored[1][CAROL] = { amount: "50", no_cost: false }; // written
      server.saves.shift().reject({
        response: {
          status: 400,
          data: {
            type: "warning",
            message: THIRD_COOK,
            bills: server.mealForm(1).bills,
          },
        },
      });
      await vi.advanceTimersByTimeAsync(0);

      expect(toastsOnScreen()).toEqual([
        ["info", `Cooks saved. ${THIRD_COOK}`],
        ["error", MAYBE_NOT_SAVED],
      ]);
    });
  });

  // The second try got no answer, so it may have been written, and the
  // words say the costs may not have been saved (#137).
  it("names the meal when the second try for a meal the person left fails too", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    await typeCost(store, BOB, "5");
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);

    await server.failSave({ request: {} });
    expect(toastsOnScreen()).toEqual([]);
    await server.failSave({ request: {} });

    expect(toastsOnScreen()).toEqual([
      [
        "error",
        "The cooks and costs you entered for Thu, Jun 15th may not have been saved. Please open that meal and check them.",
      ],
    ]);
  });

  // The second try got the app's own words, so nothing was written
  // (see billsSaveFailed).
  it("says the costs were not saved when the second try for a meal the person left gets the app's own words", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    await typeCost(store, BOB, "5");
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);

    await server.failSave({ request: {} });
    await server.failSave(PLAIN_CONFLICT);

    expect(toastsOnScreen()).toEqual([
      [
        "error",
        "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.",
      ],
    ]);
  });
});

// A stale 409, a 400 or a 422 would get the same answer again, so the
// save is not sent again. The person sees the server's words, and the
// meal loads again as on its first load, once nothing is pending for it.
describe("a save the server refused", () => {
  // Another page changed Bob to $9 after this page loaded the meal.
  async function refusedAsStale(store) {
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };
    await typeCost(store, BOB, "5");
    return server.answerSave();
  }

  it("is not sent again when it is stale; the server's words show, and the meal loads again", async () => {
    const store = createStore();
    const answer = await refusedAsStale(store);

    expect(answer.status).toBe(409);
    expect(axios).toHaveBeenCalledTimes(1);
    expect(toastsOnScreen()).toEqual([["error", answer.data.message]]);
    expect(mealFetches()).toBe(1);
    expect(rowOf(store, BOB).amount).toBe("9.00");
    expect(store.mealLoading).toBe(false);
  });

  it.each([
    [
      "the meal was settled",
      {
        response: {
          status: 400,
          data: {
            message: "Change not permitted. Meal has already been reconciled.",
          },
        },
      },
    ],
    [
      "the key was used for another save",
      {
        response: {
          status: 422,
          data: { message: "This Idempotency-Key was already used." },
        },
      },
    ],
  ])("is not sent again when %s", async (_label, error) => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await server.failSave(error);

    expect(axios).toHaveBeenCalledTimes(1);
    expect(toastsOnScreen()).toEqual([["error", error.response.data.message]]);
    expect(mealFetches()).toBe(1);
  });

  // A 422 means the page sent one key with two different saves. That is
  // a bug in the page, so it is reported.
  it("reports a 422, and only a 422, as a bug", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await server.failSave({
      response: { status: 400, data: { message: "x" } },
    });
    expect(notifyError).not.toHaveBeenCalled();

    await typeCost(store, BOB, "6");
    await server.failSave({
      response: { status: 422, data: { message: "y" } },
    });
    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(notifyError.mock.calls[0][0].message).toBe(
      "The server refused a bills save for meal 1: its Idempotency-Key was already used for a different save",
    );
  });

  // While the meal loads again the page is in its first-load state: the
  // rows are frozen, and a failed fetch is retried (LoadStatus).
  it("shows the meal as loading until it loads again, and retries a fetch that fails", async () => {
    const store = createStore();
    axios.get.mockRejectedValueOnce({ request: {} });
    vi.spyOn(console, "error").mockImplementation(() => {});
    await refusedAsStale(store);

    expect(store.mealLoading).toBe(true);
    expect(store.mealLoadFailed).toBe(true);
    expect(rowOf(store, BOB).amount).toBe("5");

    await vi.advanceTimersByTimeAsync(2000); // the retry
    expect(mealFetches()).toBe(2);
    expect(store.mealLoading).toBe(false);
    expect(rowOf(store, BOB).amount).toBe("9.00");
  });

  // The $50 typed behind the refused $5 save is sent as built: its
  // `from` is the $5 the page meant to save, the server has $9, so it is
  // refused too. Nothing is sent twice, and the meal loads once, after
  // both.
  it("sends a later save as built, and loads the meal once nothing is pending", async () => {
    const store = createStore();
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };
    await typeCost(store, BOB, "5");
    rowOf(store, BOB).setAmount("50"); // in the wait before its save

    await server.answerSave(); // the $5 save is stale
    expect(store.mealLoading).toBe(true);
    expect(mealFetches()).toBe(0);

    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(BOB, "5", "50")],
    ]);
    await server.answerSave(); // stale too
    expect(mealFetches()).toBe(1);
    expect(store.mealLoading).toBe(false);
    expect(rowOf(store, BOB).amount).toBe("9.00");
  });

  // A message that says a save failed stays when one that says a save
  // worked comes after it: the failure is still true, and the person
  // may not have read it yet (#137). Here Carol's $50 waits behind Bob's
  // $5. Bob's save is refused as stale, and Carol's is written with the
  // third-cook warning.
  describe("when a save sent after it comes back with a warning", () => {
    const THIRD_COOK =
      "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.";

    // Returns the stale words.
    async function staleThenWarning(store, betweenTheAnswers = () => {}) {
      server.stored[1][BOB] = { amount: "9.0", no_cost: false };
      await typeCost(store, BOB, "5");
      blankRow(store).setResident(store.residents.get(String(CAROL)));
      await typeCost(store, CAROL, "50"); // waits for the $5 save
      const stale = await server.answerSave();
      expect(toastsOnScreen()).toEqual([["error", stale.data.message]]);
      betweenTheAnswers();

      expect(editsSent(axios)[1]).toEqual([
        {
          op: "add",
          resident_id: CAROL,
          to: { amount: "50", no_cost: false },
        },
      ]);
      server.stored[1][CAROL] = { amount: "50", no_cost: false }; // written
      server.saves.shift().reject({
        response: {
          status: 400,
          data: {
            type: "warning",
            message: THIRD_COOK,
            bills: server.mealForm(1).bills,
          },
        },
      });
      await vi.advanceTimersByTimeAsync(0);
      return stale.data.message;
    }

    it("shows the warning on top of the stale words, which stay", async () => {
      const store = createStore();

      const staleWords = await staleThenWarning(store);

      expect(toastsOnScreen()).toEqual([
        ["info", `Cooks saved. ${THIRD_COOK}`],
        ["error", staleWords],
      ]);
      expect(notifyError).not.toHaveBeenCalled();
    });

    it("shows the warning alone when the person closed the stale words first", async () => {
      const store = createStore();

      await staleThenWarning(store, () =>
        toastStore.remove(toastStore.toasts[0].id),
      );

      expect(toastsOnScreen()).toEqual([
        ["info", `Cooks saved. ${THIRD_COOK}`],
      ]);
    });
  });

  // Rows that show what no save can send (one cook in two rows) do not
  // keep the meal from loading again: the rows are frozen while it
  // loads, so nobody could fix them, and the person was told nothing was
  // saved.
  it("loads the meal again even when its rows show one cook in two rows", async () => {
    const store = createStore();
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };
    await typeCost(store, BOB, "5");
    blankRow(store).setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS); // waits

    await server.answerSave(); // stale; the waiting save is refused

    expect(axios).toHaveBeenCalledTimes(1);
    expect(mealFetches()).toBe(1);
    expect(store.mealLoading).toBe(false);
    expect(rowOf(store, BOB).amount).toBe("9.00");
  });
});

// The answer holds the bills as stored right after the save's writes,
// so each cook the save named shows what the save sent. The rows'
// bases moved when the save was built, so the answer changes no row.
describe("the answer to a save that was written", () => {
  it("changes nothing on screen, even a cost typed after the save was sent", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    rowOf(store, BOB).setAmount("50");
    await server.answerSave();

    expect(rowOf(store, BOB).amount).toBe("50");
    expect(rowOf(store, BOB).baseAmount).toBe("5");
    expect(notifyError).not.toHaveBeenCalled();
    expect(store.mealLoading).toBe(false);
  });

  function answerWith(data) {
    const { resolve } = server.saves.shift();
    resolve({ status: 200, data });
    return vi.advanceTimersByTimeAsync(0);
  }

  it.each([
    [
      "holds another amount",
      [{ resident_id: BOB, amount: "12.34", no_cost: false }],
    ],
    [
      "holds another no_cost",
      [{ resident_id: BOB, amount: "5.0", no_cost: true }],
    ],
    ["leaves the cook out", []],
  ])(
    "is reported as a bug, and the meal loads again, when it %s",
    async (_label, bills) => {
      const store = createStore();
      await typeCost(store, BOB, "5");
      await answerWith({ message: "Form submitted.", bills });

      expect(notifyError).toHaveBeenCalledTimes(1);
      expect(notifyError.mock.calls[0][0].message).toBe(
        "The answer to a bills save for meal 1 does not hold what the save sent",
      );
      expect(mealFetches()).toBe(1);
    },
  );

  it("is reported as a bug when it still holds a cook the save removed", async () => {
    const store = createStore();
    rowOf(store, BOB).setResident("");
    await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
    await answerWith({
      message: "Form submitted.",
      bills: [{ resident_id: BOB, amount: "0.0", no_cost: false }],
    });

    expect(notifyError).toHaveBeenCalledTimes(1);
  });

  // A replayed answer holds the bills as stored now. Someone may have
  // saved since the first try, so a difference is not a bug, but the
  // rows may be out of date, so the meal loads again.
  it("loads the meal again, and reports nothing, when a replayed answer differs", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await answerWith({
      message: "This save was already made, so nothing more was written.",
      type: "replayed",
      bills: [{ resident_id: BOB, amount: "7.0", no_cost: false }],
    });

    expect(notifyError).not.toHaveBeenCalled();
    expect(mealFetches()).toBe(1);
    expect(store.mealLoading).toBe(false);
  });

  it("checks the warning answer too", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    server.saves.shift().reject({
      response: {
        status: 400,
        data: {
          type: "warning",
          message: "Warning: third cooks should not be added.",
          bills: [],
        },
      },
    });
    await vi.advanceTimersByTimeAsync(0);

    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(toastsOnScreen()).toEqual([
      ["info", "Cooks saved. Warning: third cooks should not be added."],
    ]);
    expect(mealFetches()).toBe(1);
  });

  // The server sends each amount as text. An amount that is not text can
  // only come from a bug in the server, and it makes the check throw. A
  // throw there must not stop the saves: the bug is reported, the meal
  // loads again, and the next cost is still sent.
  const AMOUNT_NOT_TEXT = [{ resident_id: BOB, amount: null, no_cost: false }];

  it.each([
    [
      "the answer",
      (save) =>
        save.resolve({
          status: 200,
          data: { message: "Form submitted.", bills: AMOUNT_NOT_TEXT },
        }),
    ],
    [
      "the warning answer",
      (save) =>
        save.reject({
          response: {
            status: 400,
            data: {
              type: "warning",
              message: "Warning: third cooks should not be added.",
              bills: AMOUNT_NOT_TEXT,
            },
          },
        }),
    ],
  ])(
    "reports %s as a bug when checking it throws, loads the meal again, and still sends the next cost",
    async (_label, answer) => {
      const store = createStore();
      await typeCost(store, BOB, "5");
      server.stored[1][BOB] = { amount: "5.0", no_cost: false }; // written
      answer(server.saves.shift());
      await vi.advanceTimersByTimeAsync(0);

      expect(notifyError).toHaveBeenCalledTimes(1);
      expect(notifyError.mock.calls[0][0]).toBeInstanceOf(TypeError);
      expect(mealFetches()).toBe(1);
      expect(store.mealLoading).toBe(false);
      expect(rowOf(store, BOB).amount).toBe("5.00");

      await typeCost(store, BOB, "6");
      expect(editsSent(axios)).toEqual([
        [change(BOB, "", "5")],
        [change(BOB, "5.00", "6")],
      ]);
    },
  );

  // The same bug in the answer for a meal the person left: the save made
  // on leaving it still goes, and that meal is not fetched.
  it("still sends the save made on leaving the meal when checking the answer throws", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    await typeCost(store, BOB, "50"); // waits for the $5 save
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    await answerWith({ message: "Form submitted.", bills: AMOUNT_NOT_TEXT });

    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(BOB, "5", "50")],
    ]);
    expect(mealFetches(1)).toBe(0);
  });

  // The person left the meal, so no rows on screen are out of date. The
  // bug is still reported, and nothing is fetched.
  it("reports a bug in the answer for a meal the person left, and fetches nothing", async () => {
    const store = createStore();
    await typeCost(store, BOB, "5");
    store.teardownMealPage();
    await answerWith({ message: "Form submitted.", bills: [] });

    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(axios.get).not.toHaveBeenCalled();
  });
});
