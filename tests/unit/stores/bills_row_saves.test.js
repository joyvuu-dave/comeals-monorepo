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
import toastStore from "../../../app/frontend/src/stores/toast_store";
import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import { BOB, CAROL, billsServer, editsSent } from "../helpers/bills_server.js";

// Each cook row saves on its own (#150). A row's save names only that
// row's cooks, and saves for different rows go at the same time. While a
// row's save is on its way, the row takes no edits. After one second of
// waiting, the row shows a spinner. A row saves 2 seconds after its last
// edit, or at once when the person leaves its cost box or presses Enter.

let server;

beforeEach(() => {
  vi.stubEnv("VITE_PUSHER_KEY", "k");
  vi.useFakeTimers();
  vi.clearAllMocks();
  toastStore.clearAll();
  server = billsServer(axios);
  server.install();
  // Meal 1 starts with Bob and Carol at $0, so each has a row.
  server.stored[1][CAROL] = { amount: "0.0", no_cost: false };
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
  stubAction(store, "loadMonthAsync");
  store.loadData(server.mealForm(1), "server");
  return store;
}

function rowOf(store, residentId) {
  return Array.from(store.bills.values()).find(
    (bill) => bill.resident !== null && bill.resident.id === residentId,
  );
}

function blankRow(store) {
  return Array.from(store.bills.values()).find(
    (bill) => bill.resident === null,
  );
}

function change(residentId, from, to) {
  return {
    op: "change",
    resident_id: residentId,
    from: { amount: from, no_cost: false },
    to: { amount: to, no_cost: false },
  };
}

describe("when a row saves", () => {
  it("saves 2 seconds after the last edit, not before", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(1500);
    rowOf(store, BOB).setAmount("50");

    await vi.advanceTimersByTimeAsync(1999);
    expect(axios).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);
    expect(editsSent(axios)).toEqual([[change(BOB, "", "50")]]);
  });

  it("saves at once when the person leaves the cost box or presses Enter", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");

    store.saveBillRowNow(rowOf(store, BOB));

    expect(editsSent(axios)).toEqual([[change(BOB, "", "5")]]);
    await vi.advanceTimersByTimeAsync(2000);
    expect(axios).toHaveBeenCalledTimes(1);
  });

  // A pick starts the row's wait, and the person then goes to the cost
  // box. On a phone, closing the menu, tapping the box and waiting for
  // the keyboard can take about 2 seconds. If the pick's save went then,
  // the row would lock under the first digits typed.
  it("starts the row's wait again when the person comes to its cost box", async () => {
    const DAN = 13;
    server.residents.push([DAN, "Dan"]);
    const store = createStore();
    const row = blankRow(store);
    row.setResident(store.residents.get(String(DAN)));
    await vi.advanceTimersByTimeAsync(1900);

    store.restartBillRowWait(row);
    await vi.advanceTimersByTimeAsync(1999);
    expect(axios).not.toHaveBeenCalled();
    row.setAmount("25");
    await vi.advanceTimersByTimeAsync(2000);

    expect(editsSent(axios)).toEqual([
      [{ op: "add", resident_id: DAN, to: { amount: "25", no_cost: false } }],
    ]);
  });

  it("starts no wait when the person comes to the cost box of a row that does not wait", async () => {
    const store = createStore();

    store.restartBillRowWait(rowOf(store, BOB));

    expect(store.billsPendingFor(1)).toBe(false);
    await vi.advanceTimersByTimeAsync(2000);
    expect(axios).not.toHaveBeenCalled();
  });

  it("sends nothing when the person leaves a cost box with no change", () => {
    const store = createStore();

    store.saveBillRowNow(rowOf(store, BOB));

    expect(axios).not.toHaveBeenCalled();
  });
});

describe("two rows", () => {
  it("save at the same time, each with only its own cook", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    rowOf(store, CAROL).setAmount("7");
    await vi.advanceTimersByTimeAsync(2000);

    expect(server.saves).toHaveLength(2);
    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(CAROL, "", "7")],
    ]);
    const [bobsKey, carolsKey] = axios.mock.calls.map(
      ([config]) => config.headers["Idempotency-Key"],
    );
    expect(carolsKey).not.toBe(bobsKey);

    await server.answerSave();
    await server.answerSave();
    expect(server.stored[1]).toEqual({
      [BOB]: { amount: "5", no_cost: false },
      [CAROL]: { amount: "7", no_cost: false },
    });
  });

  // Bob's save has no answer yet, and Carol's row takes a cost and sends
  // it. Before, Carol's save waited until Bob's was answered.
  it("do not wait for each other", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    await vi.advanceTimersByTimeAsync(2000);
    rowOf(store, CAROL).setAmount("7");
    store.saveBillRowNow(rowOf(store, CAROL));

    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(CAROL, "", "7")],
    ]);
  });
});

describe("a row whose save is on its way", () => {
  it("takes no edit until its save is answered", async () => {
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("5");
    store.saveBillRowNow(bob);
    expect(bob.saving).toBe(true);

    expect(bob.setAmount("50")).toBe("5");
    expect(bob.toggleNoCost()).toBe(false);
    bob.setResident(store.residents.get(String(CAROL)));
    bob.setResident("");
    expect(bob.amount).toBe("5");
    expect(bob.no_cost).toBe(false);
    expect(bob.resident_id).toBe(BOB);
    await vi.advanceTimersByTimeAsync(2000);
    expect(axios).toHaveBeenCalledTimes(1);

    await server.answerSave();
    expect(bob.saving).toBe(false);
    expect(bob.setAmount("50")).toBe("50");
  });

  it("leaves the other rows free to take edits", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.saveBillRowNow(rowOf(store, BOB));

    expect(rowOf(store, CAROL).saving).toBe(false);
    expect(rowOf(store, CAROL).setAmount("7")).toBe("7");
  });

  it("shows a spinner once its save has waited one second, and not before", async () => {
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("5");
    store.saveBillRowNow(bob);

    await vi.advanceTimersByTimeAsync(999);
    expect(bob.saving).toBe(true);
    expect(bob.slowToSave).toBe(false);

    await vi.advanceTimersByTimeAsync(1);
    expect(bob.slowToSave).toBe(true);
    expect(rowOf(store, CAROL).slowToSave).toBe(false);

    await server.answerSave();
    expect(bob.saving).toBe(false);
    expect(bob.slowToSave).toBe(false);
  });

  it("shows no spinner for a save answered within one second", async () => {
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("5");
    store.saveBillRowNow(bob);
    await vi.advanceTimersByTimeAsync(500);
    await server.answerSave();

    await vi.advanceTimersByTimeAsync(1000);
    expect(bob.slowToSave).toBe(false);
  });

  // The shared screen stays open for weeks, and every save is one more.
  // So once a save is answered, the page keeps nothing about it, whether
  // it was answered before or after its spinner showed.
  it("keeps nothing about a save once it is answered", async () => {
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("5");
    store.saveBillRowNow(bob);
    await vi.advanceTimersByTimeAsync(500);
    await server.answerSave();
    await vi.advanceTimersByTimeAsync(1000);
    expect(store.billsSlowSaveKeys).toEqual([]);

    bob.setAmount("6");
    store.saveBillRowNow(bob);
    await vi.advanceTimersByTimeAsync(1000);
    expect(store.billsSlowSaveKeys).toHaveLength(1);
    await server.answerSave();
    expect(store.billsSlowSaveKeys).toEqual([]);
    expect(store.billsSavesOnTheirWay).toEqual([]);
  });

  // Decision 7 of #135: no answer is sent once more with the same key.
  // The row stays locked, with its spinner, until the second try is
  // answered.
  it("stays locked while its save is sent a second time", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("5");
    store.saveBillRowNow(bob);
    await vi.advanceTimersByTimeAsync(1000);

    await server.failSave({ request: {} });
    expect(axios).toHaveBeenCalledTimes(2);
    expect(bob.saving).toBe(true);
    expect(bob.slowToSave).toBe(true);
    expect(bob.setAmount("50")).toBe("5");

    await server.answerSave();
    expect(bob.saving).toBe(false);
    expect(bob.slowToSave).toBe(false);
  });
});

// A save names each cook once, and two saves on their way at once must
// not name the same cook: the server could take them in either order.
// So a row cannot take a cook while another row's change to that cook is
// not saved yet.
describe("a cook another row is still changing", () => {
  it("cannot be picked in another row until that row's save is answered", async () => {
    const store = createStore();
    const bobsRow = rowOf(store, BOB);
    const other = blankRow(store);
    bobsRow.setResident("");

    // Bob's old row has not sent its change yet.
    other.setResident(store.residents.get(String(BOB)));
    expect(other.resident).toBeNull();
    expect(store.cookTakenByAnotherRow(other, BOB)).toBe(true);

    // Its save is on its way.
    store.saveBillRowNow(bobsRow);
    other.setResident(store.residents.get(String(BOB)));
    expect(other.resident).toBeNull();
    expect(store.cookTakenByAnotherRow(other, BOB)).toBe(true);

    // Its save is answered.
    await server.answerSave();
    expect(store.cookTakenByAnotherRow(other, BOB)).toBe(false);
    other.setResident(store.residents.get(String(BOB)));
    expect(other.resident_id).toBe(BOB);
  });

  // A save for a meal the person left names that meal's cooks. The
  // meal on screen has its own bills, so its rows may take those cooks.
  it("can be picked on another meal while a save for the meal the person left names them", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.goToMeal(2);
    await vi.advanceTimersByTimeAsync(0);
    expect(editsSent(axios)).toEqual([[change(BOB, "", "5")]]);
    expect(store.meal.id).toBe(2);

    const row = blankRow(store);
    expect(store.cookTakenByAnotherRow(row, BOB)).toBe(false);
    row.setResident(store.residents.get(String(BOB)));
    expect(row.resident_id).toBe(BOB);
  });

  it("is not taken by the row that is changing them", () => {
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setResident("");

    expect(store.cookTakenByAnotherRow(bob, BOB)).toBe(false);
    bob.setResident(store.residents.get(String(BOB)));
    expect(bob.resident_id).toBe(BOB);
  });
});

// S16: a row with no cook has no cost. Picking the blank clears the
// cost, so the next cook picked in the row does not take the old cook's
// cost. Picking another cook straight away keeps the cost with the row.
describe("the blank choice in a row with a cost", () => {
  it("clears the cost and the no-cost switch", () => {
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("12.50");
    bob.setResident("");

    expect(bob.amount).toBe("");
    expect(bob.no_cost).toBe(false);

    const carol = rowOf(store, CAROL);
    carol.toggleNoCost();
    carol.setResident("");
    expect(carol.no_cost).toBe(false);
  });

  it("removes the cook with the cost the server has, and adds the next cook with no cost", async () => {
    const DAN = 13;
    server.residents.push([DAN, "Dan"]);
    server.stored[1][BOB] = { amount: "12.5", no_cost: false };
    const store = createStore();
    const row = rowOf(store, BOB);
    row.setResident("");
    store.saveBillRowNow(row);
    await server.answerSave();
    row.setResident(store.residents.get(String(DAN)));
    expect(row.amount).toBe("");
    store.saveBillRowNow(row);

    expect(editsSent(axios)).toEqual([
      [
        {
          op: "remove",
          resident_id: BOB,
          from: { amount: "12.50", no_cost: false },
        },
      ],
      [{ op: "add", resident_id: DAN, to: { amount: "", no_cost: false } }],
    ]);
  });

  // A cook no other menu offers (retired after cooking, #91) is offered
  // again in their own row after the blank, so the person can undo it.
  // Their cost comes back with them: nobody may know what it was.
  it("gives a cook their cost back when they are picked again in that row", () => {
    const XAVIER = 14;
    server.residents.push([XAVIER, "Xavier"]);
    server.stored[1][XAVIER] = { amount: "30.0", no_cost: false };
    const store = createStore();
    const row = rowOf(store, XAVIER);
    row.setResident("");
    row.setResident(store.residents.get(String(XAVIER)));

    expect(row.amount).toBe("30.00");
    expect(row.unsent).toBe(false);
    store.saveBillRowNow(row);
    expect(axios).not.toHaveBeenCalled();
  });

  it("gives the cost back after the blank was saved, as an add with that cost", async () => {
    server.stored[1][BOB] = { amount: "12.5", no_cost: false };
    const store = createStore();
    const row = rowOf(store, BOB);
    row.setResident("");
    store.saveBillRowNow(row);
    await server.answerSave();

    row.setResident(store.residents.get(String(BOB)));
    store.saveBillRowNow(row);

    expect(editsSent(axios)[1]).toEqual([
      { op: "add", resident_id: BOB, to: { amount: "12.50", no_cost: false } },
    ]);
  });

  it("gives the No cost switch back too", () => {
    const store = createStore();
    const row = rowOf(store, BOB);
    row.toggleNoCost();
    row.setResident("");

    row.setResident(store.residents.get(String(BOB)));

    expect(row.no_cost).toBe(true);
    expect(row.amount).toBe("");
  });

  // Each cook's cost is kept for that cook: picking another cook after
  // the blank does not give them the first cook's cost.
  it("gives each cook only their own cost back, and only once", () => {
    const DAN = 13;
    server.residents.push([DAN, "Dan"]);
    server.stored[1][BOB] = { amount: "20.0", no_cost: false };
    const store = createStore();
    const row = rowOf(store, BOB);
    row.setResident("");

    row.setResident(store.residents.get(String(DAN)));
    expect(row.amount).toBe("");
    // Picking Bob straight from Dan's row, which has no cost of its own.
    row.setResident(store.residents.get(String(BOB)));
    expect(row.amount).toBe("20.00");

    row.setAmount("");
    row.setResident(store.residents.get(String(DAN)));
    row.setResident(store.residents.get(String(BOB)));
    expect(row.amount).toBe("");
  });

  // The No cost switch turned on after the blank is the row's own too.
  it("keeps the No cost switch turned on after the blank when the first cook is picked again", () => {
    const DAN = 13;
    server.residents.push([DAN, "Dan"]);
    server.stored[1][BOB] = { amount: "20.0", no_cost: false };
    const store = createStore();
    const row = rowOf(store, BOB);
    row.setResident("");
    row.setResident(store.residents.get(String(DAN)));
    row.toggleNoCost();

    row.setResident(store.residents.get(String(BOB)));

    expect(row.no_cost).toBe(true);
    expect(row.amount).toBe("");
  });

  // A cost typed after the blank is the row's own, and stays with the
  // row, as any cost does when another cook is picked straight away.
  it("keeps a cost typed after the blank when the first cook is picked again", () => {
    const DAN = 13;
    server.residents.push([DAN, "Dan"]);
    server.stored[1][BOB] = { amount: "20.0", no_cost: false };
    const store = createStore();
    const row = rowOf(store, BOB);
    row.setResident("");
    row.setResident(store.residents.get(String(DAN)));
    row.setAmount("7");

    row.setResident(store.residents.get(String(BOB)));

    expect(row.amount).toBe("7");
  });

  // A menu fires no change when its value is picked again, but the
  // action must not fail on a row with no cook to keep a cost for.
  it("keeps nothing when picked in a row with no cook", async () => {
    const store = createStore();
    const row = blankRow(store);

    expect(row.setResident("")).toBeNull();

    expect(row.amount).toBe("");
    expect(row.no_cost).toBe(false);
    await vi.advanceTimersByTimeAsync(2000);
    expect(axios).not.toHaveBeenCalled();
  });

  it("does not clear the cost when another cook is picked straight away", () => {
    const DAN = 13;
    server.residents.push([DAN, "Dan"]);
    const store = createStore();
    const row = rowOf(store, BOB);
    row.setAmount("12.50");

    row.setResident(store.residents.get(String(DAN)));

    expect(row.amount).toBe("12.50");
  });
});

// #150. A phone fires visibilitychange (to hidden) when the person
// leaves the browser, and it may close the page after it with no other
// event. So a row with a change not sent yet is sent at once, with fetch
// keepalive, which lets the request finish after the page is gone.
describe("when the page is hidden or closed", () => {
  // The token is added by axios_auth.js, which the browser test checks
  // (tests/e2e/meal.spec.js).
  it("sends each row with a change not sent yet at once, with keepalive and its key", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    rowOf(store, CAROL).setAmount("7");

    store.sendBillsBeforeHidden();

    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(CAROL, "", "7")],
    ]);
    axios.mock.calls.forEach(([config]) => {
      expect(config.adapter).toBe("fetch");
      expect(config.fetchOptions).toEqual({ keepalive: true });
      expect(config.headers["Idempotency-Key"]).toMatch(/^"[^"\\]+"$/);
    });
  });

  it("sends nothing for rows with no change, or with a save on its way", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.saveBillRowNow(rowOf(store, BOB));

    store.sendBillsBeforeHidden();

    expect(axios).toHaveBeenCalledTimes(1);
    expect(axios.mock.calls[0][0].adapter).toBeUndefined();
  });

  // The page may stay open: the person comes back to the tab. The save
  // is answered like any other.
  it("handles the answer when the page stays open", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.sendBillsBeforeHidden();
    expect(rowOf(store, BOB).saving).toBe(true);

    await server.answerSave();

    expect(rowOf(store, BOB).saving).toBe(false);
    expect(server.stored[1][BOB]).toEqual({ amount: "5", no_cost: false });
    await vi.advanceTimersByTimeAsync(2000);
    expect(axios).toHaveBeenCalledTimes(1);
  });
});

// Logout, Refresh and the error page's Refresh reload the page, and a
// reload ends every request on its way. So they first send every row
// with a change not sent yet, and wait for the saves on their way, up to
// 5 seconds. The wait answers whether the page may reload: not when a
// save it waited for was not saved, because the reload would take the
// message away before the person could read it.
describe("before the page reloads itself", () => {
  // Starts the wait, and hands back what it has answered so far:
  // undefined until it answers.
  function startWait(store) {
    const wait = { answer: undefined };
    store.finishBillsSaves().then((mayReload) => {
      wait.answer = mayReload;
    });
    return wait;
  }

  it("sends the rows not sent yet, and waits until every save is answered", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);
    expect(editsSent(axios)).toEqual([[change(BOB, "", "5")]]);
    expect(wait.answer).toBeUndefined();

    await server.answerSave();
    expect(wait.answer).toBe(true);
  });

  // The reload will end the save. WebKit ends it as soon as the reload
  // starts, before the page fires pagehide, so it is sent again with
  // keepalive now, with the same key. Logout takes the token away right
  // after, so this must come first.
  it("goes on after 5 seconds when a save is still on its way, and sends it again with keepalive", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(4999);
    expect(wait.answer).toBeUndefined();
    expect(axios).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(1);
    expect(wait.answer).toBe(true);
    const [first, again] = axios.mock.calls.map(([config]) => config);
    expect(again.data).toEqual(first.data);
    expect(again.headers).toEqual(first.headers);
    expect(again.fetchOptions).toEqual({ keepalive: true });
  });

  it("goes on at once when nothing is waiting", async () => {
    const store = createStore();

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);

    expect(wait.answer).toBe(true);
  });

  // A save for a meal the person left is on its way too.
  it("waits for a save for a meal the person left", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.teardownMealPage();

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);
    expect(wait.answer).toBeUndefined();

    await server.answerSave();
    expect(wait.answer).toBe(true);
  });

  // The rows take no edit while the page waits to reload: an edit then
  // would wait 2 seconds before its save, and the reload, or logout
  // taking the token away, would lose it. When the page may reload, they
  // stay frozen until it does.
  it("freezes the cook rows while it waits, and until the page reloads", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    expect(store.waitingToReload).toBe(false);

    const wait = startWait(store);
    expect(store.waitingToReload).toBe(true);

    await server.answerSave();
    expect(wait.answer).toBe(true);
    expect(store.waitingToReload).toBe(true);
  });

  // The rows are frozen on screen, but an edit can still reach the
  // store. Its row's wait is part of what the page waits for.
  it("waits for a row that took an edit while it waited", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(100);
    rowOf(store, CAROL).setAmount("7");

    await server.answerSave();
    expect(wait.answer).toBeUndefined();

    await vi.advanceTimersByTimeAsync(2000);
    await server.answerSave();
    expect(wait.answer).toBe(true);
    expect(
      Array.from(store.bills.values()).filter((row) => row.unsent),
    ).toEqual([]);
    expect(server.stored[1][CAROL]).toEqual({ amount: "7", no_cost: false });
  });

  // Someone else saved Bob's cost first, so Bob's save is refused. The
  // page stays, with the message, and the rows take edits again. The
  // next tap of Logout or Refresh goes on.
  it("says no when a save it waited for was refused, and frees the rows", async () => {
    server.stored[1][BOB] = { amount: "0.0", no_cost: false };
    const store = createStore();
    rowOf(store, BOB).setAmount("5");

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };
    await server.answerSave();

    expect(wait.answer).toBe(false);
    expect(toastStore.toasts.map((toast) => toast.type)).toEqual(["error"]);
    expect(store.waitingToReload).toBe(false);

    const second = startWait(store);
    await vi.advanceTimersByTimeAsync(0);
    expect(second.answer).toBe(true);
  });

  it("says no when a save for a meal the person left was not saved", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.teardownMealPage();
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };

    const wait = startWait(store);
    await server.answerSave();

    expect(wait.answer).toBe(false);
    expect(toastStore.toasts.map((toast) => toast.message)).toEqual([
      "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.",
    ]);
  });

  // The second try of the save got no answer either, so the page cannot
  // tell whether it was written, and says so.
  it("says no when a save may not have been saved", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    rowOf(store, BOB).setAmount("5");

    const wait = startWait(store);
    await server.failSave({ request: {} });
    await server.failSave({ request: {} });

    expect(wait.answer).toBe(false);
    expect(toastStore.toasts.map((toast) => toast.message)).toEqual([
      "Your cooks and costs may not have been saved. Check them when the meal shows again.",
    ]);
  });

  // Only a bug in the page can pick one cook in two rows (the menus do
  // not offer it), but if it does, that row's edit cannot be sent.
  it("says no when a row cannot be sent, because its cook is picked in two rows", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const store = createStore();
    blankRow(store).setResident(store.residents.get(String(BOB)));

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);

    expect(axios).not.toHaveBeenCalled();
    expect(wait.answer).toBe(false);
    expect(toastStore.toasts.map((toast) => toast.message)).toEqual([
      "Bob is picked in two rows, so nothing was saved. Pick another cook in one of them.",
    ]);
  });

  // The refusal showed before, and the person closed it. The row still
  // shows an edit the server does not have, so the page says why it
  // stays, once: the row that has no edit is not sent.
  it("says again why a row that could not be sent is not saved", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const store = createStore();
    blankRow(store).setResident(store.residents.get(String(BOB)));
    await vi.advanceTimersByTimeAsync(2000);
    toastStore.clearAll();

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);

    expect(wait.answer).toBe(false);
    expect(toastStore.toasts.map((toast) => toast.message)).toEqual([
      "Bob is picked in two rows, so nothing was saved. Pick another cook in one of them.",
    ]);
  });

  // One save was refused, and another is still on its way after the 5
  // seconds. The refusal's message is on screen, so the page stays.
  it("says no after 5 seconds when a save it waited for was refused", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    rowOf(store, CAROL).setAmount("7");

    const wait = startWait(store);
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };
    await server.answerSave();
    expect(wait.answer).toBeUndefined();
    await vi.advanceTimersByTimeAsync(5000);

    expect(wait.answer).toBe(false);
    expect(store.waitingToReload).toBe(false);
    // The page stays, so Carol's save is not sent again.
    expect(axios).toHaveBeenCalledTimes(2);
  });

  // A failure the person saw before the tap is not about this wait.
  it("does not count a save that failed before it was called", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.saveBillRowNow(rowOf(store, BOB));
    server.stored[1][BOB] = { amount: "9.0", no_cost: false };
    await server.answerSave();
    expect(toastStore.toasts.map((toast) => toast.type)).toEqual(["error"]);

    const wait = startWait(store);
    await vi.advanceTimersByTimeAsync(0);

    expect(wait.answer).toBe(true);
  });
});

// #150. A save on its way goes by XMLHttpRequest, and the browser ends
// it when the page closes or reloads. So when the page closes, each save
// on its way is sent again with fetch keepalive, which can finish after
// the page is gone, and with the same key: if the first try was written,
// the server answers "replayed" and writes nothing more.
describe("when the page closes with saves on their way", () => {
  it("sends each save on its way again, with keepalive and the same key", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.saveBillRowNow(rowOf(store, BOB));
    rowOf(store, CAROL).setAmount("7");
    store.saveBillRowNow(rowOf(store, CAROL));

    store.sendBillsAgainBeforeClose();

    const [bob, carol, bobAgain, carolAgain] = axios.mock.calls.map(
      ([config]) => config,
    );
    expect(axios).toHaveBeenCalledTimes(4);
    [
      [bob, bobAgain],
      [carol, carolAgain],
    ].forEach(([first, again]) => {
      expect(again.url).toBe(first.url);
      expect(again.data).toEqual(first.data);
      expect(again.headers).toEqual(first.headers);
      expect(again.adapter).toBe("fetch");
      expect(again.fetchOptions).toEqual({ keepalive: true });
    });

    // The server writes the first try, and answers the second as
    // replayed.
    await server.answerSave();
    expect((await server.answerSave(1)).data.type).toBe("replayed");
    expect(server.stored[1][BOB]).toEqual({ amount: "5", no_cost: false });
  });

  it("sends a save again only once", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.saveBillRowNow(rowOf(store, BOB));

    store.sendBillsAgainBeforeClose();
    store.sendBillsAgainBeforeClose();

    expect(axios).toHaveBeenCalledTimes(2);
  });

  // A save sent because the page was hidden went with keepalive already.
  it("does not send again a save that went with keepalive", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.sendBillsBeforeHidden();

    store.sendBillsAgainBeforeClose();

    expect(axios).toHaveBeenCalledTimes(1);
  });

  it("sends again a save for a meal the person left", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.teardownMealPage();

    store.sendBillsAgainBeforeClose();

    expect(editsSent(axios)).toEqual([
      [change(BOB, "", "5")],
      [change(BOB, "", "5")],
    ]);
    expect(axios.mock.calls[1][0].url).toBe("/api/v1/meals/1/bills");
  });

  // If the page stays open after all, the first try's answer is the one
  // the page reads. The second try's answer, or its failure, changes
  // nothing and shows nothing.
  it("reads only the first try's answer when the page stays open", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    const store = createStore();
    const bob = rowOf(store, BOB);
    bob.setAmount("5");
    store.saveBillRowNow(bob);
    store.sendBillsAgainBeforeClose();

    await server.failSave({ request: {} }, 1);
    expect(logged).toHaveBeenCalledWith(
      "Error: no response received from server.",
    );
    expect(axios).toHaveBeenCalledTimes(2);
    expect(bob.saving).toBe(true);

    await server.answerSave();
    expect(bob.saving).toBe(false);
    expect(toastStore.toasts).toEqual([]);
  });

  it("sends nothing when no save is on its way", () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");

    store.sendBillsAgainBeforeClose();

    expect(axios).not.toHaveBeenCalled();
  });
});

// The third-cook warning comes with a 200: the cooks were saved. The
// page reads it on its success path.
describe("a save answered with the third-cook warning", () => {
  const THIRD_COOK =
    "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.";

  it("says the cooks were saved, and gives the warning", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("5");
    store.saveBillRowNow(rowOf(store, BOB));
    server.stored[1][BOB] = { amount: "5", no_cost: false };
    server.saves.shift().resolve({
      status: 200,
      data: {
        message: THIRD_COOK,
        type: "warning",
        bills: server.mealForm(1).bills,
      },
    });
    await vi.advanceTimersByTimeAsync(0);

    expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
      ["info", `Cooks saved. ${THIRD_COOK}`],
    ]);
    expect(rowOf(store, BOB).saving).toBe(false);
    expect(idbKeyval.del).toHaveBeenCalledWith("1");
  });
});
