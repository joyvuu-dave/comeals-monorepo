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

// A cost typed on a meal can reach the server after someone else has
// cancelled the dinner (ADR 0011 rule 11): another tab, the admin's
// Cancel button, or the settlement preview's button for dinners nobody
// cooked. The server refuses the save with a 400 and the sentence of
// CancelledDinnerFreeze (app/models/concerns/cancelled_dinner_freeze.rb).
// spec/models/meal_cancelled_spec.rb pins that sentence for a bill; no
// request spec sends a bills save to a cancelled dinner yet.
const CANCELLED_REFUSAL =
  "This dinner is cancelled. Restore it before changing it.";

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

function rowOf(store, residentId) {
  return Array.from(store.bills.values()).find(
    (bill) => bill.resident !== null && bill.resident.id === residentId,
  );
}

function toastsOnScreen() {
  return toastStore.toasts.map((toast) => [toast.type, toast.message]);
}

describe("a cost save refused because the dinner was cancelled", () => {
  // Meal 1 (Thu, Jun 15th) on screen. The person types $50 for Bob,
  // waits for the save to go, and goes on to meal 2 while it is on its
  // way. The dinner of meal 1 was cancelled before the save reached the
  // server, so the server refuses it.
  async function leaveMeal1AndHaveTheSaveRefused() {
    const store = createDataStore({ mealProps: { closed: false } });
    stubAction(store, "loadMonthAsync");
    store.loadData(server.mealForm(1), "server");

    rowOf(store, BOB).setAmount("50");
    vi.advanceTimersByTime(BILL_ROW_SAVE_WAIT_MS); // the save is on its way
    store.switchMeals(2);
    await vi.advanceTimersByTimeAsync(0); // meal 2 loads
    toastStore.clearAll();

    await server.failSave({
      response: { status: 400, data: { message: CANCELLED_REFUSAL } },
    });
    return store;
  }

  // The settled case has its own words for the same reason
  // (notSavedMessage in data_store_bills.ts): entering the costs again
  // cannot work. On a cancelled dinner it cannot work either: the cost
  // boxes are off until someone restores it, and the server refuses every
  // cost until then.
  it("says the dinner was cancelled, and does not ask the person to enter the costs again", async () => {
    await leaveMeal1AndHaveTheSaveRefused();

    const messages = toastsOnScreen();
    expect(messages).toHaveLength(1);
    const [type, words] = messages[0];
    expect(type).toBe("error");
    expect(words).toContain("Thu, Jun 15th");
    expect(words).not.toContain("enter them again");
    expect(words).toContain("cancelled");
  });
});
