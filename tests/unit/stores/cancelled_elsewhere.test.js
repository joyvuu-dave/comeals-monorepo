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
import { BILL_ROW_SAVE_WAIT_MS } from "../../../app/frontend/src/stores/data_store_bills";
import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import { BOB, billsServer } from "../helpers/bills_server.js";

// The dinner on screen is cancelled from somewhere else (another tab,
// the admin's Cancel button, the settlement preview's button) while this
// page has a request on its way or waiting (ADR 0011 rule 11). The
// server refuses that request with the sentence of CancelledDinnerFreeze,
// and pushes the meal's channel to this page, which did not make the
// change. Each test checks what the page shows once everything settles:
// the server's sentence, no row or seat left waiting, and the dinner
// shown cancelled, so every control that changes it is off.
const CANCELLED_REFUSAL =
  "This dinner is cancelled. Restore it before changing it.";
const REFUSED = {
  response: { status: 400, data: { message: CANCELLED_REFUSAL } },
};

let server;
// What the server has for meal 1 beyond its bills.
let serverMeal;
let channels;

beforeEach(() => {
  vi.stubEnv("VITE_PUSHER_KEY", "k");
  vi.useFakeTimers();
  vi.clearAllMocks();
  toastStore.clearAll();
  server = billsServer(axios);
  server.install();
  serverMeal = { cancelled: false, bobAttending: true };
  answerMealFetchesAtOnce();
});

afterEach(() => {
  vi.useRealTimers();
  [axios, axios.get, idbKeyval.get, idbKeyval.set].forEach((mock) =>
    mock.mockReset(),
  );
});

// The meal form as the server has it when the fetch arrives.
function mealForm() {
  const form = server.mealForm(1);
  return {
    ...form,
    cancelled: serverMeal.cancelled,
    residents: form.residents.map((row) =>
      row.id === BOB ? { ...row, attending: serverMeal.bobAttending } : row,
    ),
  };
}

function answerMealFetchesAtOnce() {
  axios.get.mockImplementation(() =>
    Promise.resolve({ status: 200, data: mealForm() }),
  );
}

// The next meal fetch waits until the test answers it, with what the
// server has then.
function holdNextMealFetch() {
  let answer;
  axios.get.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        answer = () => resolve({ status: 200, data: mealForm() });
      }),
  );
  return () => answer();
}

function createStore() {
  const store = createDataStore({ mealProps: { closed: false } });
  channels = new Map();
  vi.spyOn(window.Comeals.pusher, "subscribe").mockImplementation((name) => {
    const channel = { name, bind: vi.fn() };
    channels.set(name, channel);
    return channel;
  });
  vi.spyOn(window.Comeals.pusher, "unsubscribe").mockImplementation(() => {});
  stubAction(store, "loadMonthAsync");
  store.loadData(mealForm(), "server");
  return store;
}

function fire(channelName, event) {
  channels
    .get(channelName)
    .bind.mock.calls.filter(([bound]) => bound === event)
    .forEach(([, handler]) => handler());
}

// The dinner is cancelled on the server, and the meal's channel tells
// this page.
function cancelElsewhere() {
  serverMeal.cancelled = true;
  fire("meal-1", "update");
}

function rowOf(store, residentId) {
  return Array.from(store.bills.values()).find(
    (bill) => bill.resident !== null && bill.resident.id === residentId,
  );
}

function bob(store) {
  return store.residents.get(String(BOB));
}

function toastsOnScreen() {
  return toastStore.toasts.map((toast) => [toast.type, toast.message]);
}

// What the page shows once nothing is on its way: the dinner cancelled,
// and nothing left waiting.
function expectSettledAsCancelled(store) {
  expect(store.meal.cancelled).toBe(true);
  expect(store.meal.frozen).toBe(true);
  expect(store.mealLoading).toBe(false);
  expect(store.billsSavesOnTheirWay).toEqual([]);
  expect(Object.keys(store.billsSaveTimers)).toEqual([]);
  expect(store.billsPendingFor(1)).toBe(false);
  expect(store.signupRequestWaiting(1)).toBe(false);
  expect(store.takeOffsWaitingOn(1)).toBe(0);
  expect(store.guestAddsWaitingOn(1)).toBe(0);
}

describe("a cost row", () => {
  it("in its wait: the save is refused with the server's sentence, and the page then shows the dinner cancelled", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("50"); // in its 2-second wait
    cancelElsewhere();
    await vi.advanceTimersByTimeAsync(0);
    // The push's fetch waits for the cost (#136).
    expect(store.meal.cancelled).toBe(false);

    vi.advanceTimersByTime(BILL_ROW_SAVE_WAIT_MS); // the save goes
    expect(rowOf(store, BOB).saving).toBe(true);
    await server.failSave(REFUSED);

    expect(toastsOnScreen()).toEqual([["error", CANCELLED_REFUSAL]]);
    expectSettledAsCancelled(store);
    expect(rowOf(store, BOB).saving).toBe(false);
  });

  it("with its save on its way: the same", async () => {
    const store = createStore();
    rowOf(store, BOB).setAmount("50");
    vi.advanceTimersByTime(BILL_ROW_SAVE_WAIT_MS); // the save goes
    cancelElsewhere();
    await vi.advanceTimersByTimeAsync(0);
    expect(store.meal.cancelled).toBe(false);

    await server.failSave(REFUSED);

    expect(toastsOnScreen()).toEqual([["error", CANCELLED_REFUSAL]]);
    expectSettledAsCancelled(store);
  });
});

describe("a take-off", () => {
  it("answered before the push's fetch: the person is put back, the seat is freed, and the dinner shows cancelled", async () => {
    const store = createStore();
    bob(store).toggleAttending(); // the take-off is on its way
    expect(store.takeOffsWaitingOn(1)).toBe(1);

    const answerFetch = holdNextMealFetch();
    cancelElsewhere(); // the fetch goes out before the refusal
    await server.failSave(REFUSED);
    expect(bob(store).attending).toBe(true);
    answerFetch(); // read before the refusal was answered: not used (#156)
    await vi.advanceTimersByTimeAsync(0);

    expect(toastsOnScreen()).toEqual([["error", `Bob: ${CANCELLED_REFUSAL}`]]);
    expectSettledAsCancelled(store);
    expect(bob(store).attending).toBe(true);
  });

  it("answered after the push's fetch: the same", async () => {
    const store = createStore();
    bob(store).toggleAttending();
    cancelElsewhere();
    await vi.advanceTimersByTimeAsync(0); // the fetch lands first
    expect(store.meal.cancelled).toBe(true);

    await server.failSave(REFUSED);

    expect(toastsOnScreen()).toEqual([["error", `Bob: ${CANCELLED_REFUSAL}`]]);
    expectSettledAsCancelled(store);
    expect(bob(store).attending).toBe(true);
  });
});

describe("a guest add", () => {
  it("is refused with the server's sentence, its seat is freed, and the dinner shows cancelled", async () => {
    const store = createStore();
    bob(store).addGuest({ vegetarian: false });
    expect(store.guestAddsWaitingOn(1)).toBe(1);

    const answerFetch = holdNextMealFetch();
    cancelElsewhere();
    await server.failSave(REFUSED);
    answerFetch();
    await vi.advanceTimersByTimeAsync(0);

    expect(toastsOnScreen()).toEqual([["error", `Bob: ${CANCELLED_REFUSAL}`]]);
    expectSettledAsCancelled(store);
    expect(store.guests.size).toBe(0);
  });
});

describe("a restore from somewhere else", () => {
  it("turns the controls on again", async () => {
    serverMeal.cancelled = true;
    const store = createStore();
    expect(store.meal.frozen).toBe(true);

    serverMeal.cancelled = false;
    fire("meal-1", "update");
    await vi.advanceTimersByTimeAsync(0);

    expect(store.meal.cancelled).toBe(false);
    expect(store.meal.frozen).toBe(false);
  });
});
