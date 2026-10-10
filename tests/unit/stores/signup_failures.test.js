import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// What a person sees, and what the page does, when a sign-up, Late, Veg
// or guest request fails (S2). Mock external modules before importing
// stores.
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";
import { deadConnection } from "../helpers/dead_connection.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// The server's refusal, with its own words.
const REFUSAL = {
  response: { status: 400, data: { message: "Meal has no open spots." } },
};
// No answer at all: a dropped connection, or a request that never left.
const NO_ANSWER = { request: {} };
// Heroku's router page after 30 seconds, while the request may still run
// in the app: an answer, but not one the app wrote.
const ROUTER_TIMEOUT = {
  response: { status: 503, data: "<html>Application error</html>" },
};

const MAYBE_ON_SCREEN =
  "Alice Smith: this change may not have been saved. The meal will load again and show what was saved.";
const MAYBE_LEFT =
  "Alice Smith (Thu, Jun 15th): this change may not have been saved. Open that meal to check it.";

// The six requests a tap on a row of the sign-up list sends, and the row
// each starts from. Alice's guest was added while the meal was open, so
// it can be removed.
const TAPS = [
  ["a sign-up", { attending: false }, (alice) => alice.toggleAttending()],
  ["a take-off", { attending: true }, (alice) => alice.toggleAttending()],
  ["a Late tap", { attending: true }, (alice) => alice.toggleLate()],
  ["a Veg tap", { attending: true }, (alice) => alice.toggleVeg()],
  [
    "a guest add",
    { attending: true },
    (alice) => alice.addGuest({ vegetarian: false }),
  ],
  ["a guest removal", { attending: true }, (alice) => alice.removeGuest()],
];

let loadDataAsyncSpy;

// An open meal on Thu, Jun 15th 2023, with Alice's row. The day is how
// the date box shows it (mealDayLabel).
function aliceStore(row) {
  const store = createDataStore({
    mealProps: { closed: false, date: new Date(2023, 5, 15) },
    residents: [
      {
        id: 10,
        meal_id: 1,
        name: "A - Alice Smith",
        short_name: "Alice Smith",
        ...row,
      },
    ],
    guests: [{ id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() }],
  });
  loadDataAsyncSpy = stubAction(store, "loadDataAsync");
  window.Comeals.socketId = "test";
  return store;
}

// The next request waits for the test to answer it.
function answerLater() {
  let reject;
  axios.mockImplementationOnce(
    () =>
      new Promise((_, rej) => {
        reject = rej;
      }),
  );
  return (error) => reject(error);
}

// The meal loaded again while the request was out: every row was built
// again, so the row that was tapped is gone (preLoadData).
function rebuildRows(store) {
  stage(store, () => {
    store.residents.clear();
    store.residents.put({
      id: 10,
      meal_id: 1,
      name: "A - Alice Smith",
      short_name: "Alice Smith",
    });
  });
}

// The person went on to another meal while the request was out.
function moveToAnotherMeal(store) {
  stage(store, () => {
    store.meals.push({ id: 2, date: new Date(2023, 5, 16) });
    store.meal = 2;
    store.residents.clear();
    store.guests.clear();
  });
}

async function settle() {
  await new Promise((r) => setTimeout(r, 0));
}

function shown() {
  return toastStore.toasts.map((toast) => [toast.message, toast.type]);
}

describe("a failed sign-up, Late, Veg or guest request", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
    window.Comeals = {
      socketId: "test",
      pusher: null,
      mealChannel: null,
      calendarChannel: null,
    };
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe.each(TAPS)("%s", (_what, row, tap) => {
    // On a shared screen several people tap at once, so the words alone
    // do not say whose tap failed.
    it("shows the server's words after the name of the person whose row was tapped", async () => {
      const store = aliceStore(row);
      axios.mockRejectedValueOnce(REFUSAL);

      tap(store.residents.get("10"));
      await settle();

      expect(shown()).toEqual([
        ["Alice Smith: Meal has no open spots.", "error"],
      ]);
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    });

    // A change from another device makes the page load the meal again,
    // which builds every row again. The refusal must still show.
    it("shows the refusal when the row was built again while the request was out", async () => {
      const store = aliceStore(row);
      const answer = answerLater();

      tap(store.residents.get("10"));
      rebuildRows(store);
      answer(REFUSAL);
      await settle();

      expect(shown()).toEqual([
        ["Alice Smith: Meal has no open spots.", "error"],
      ]);
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    });

    // By the time the refusal comes, another meal or the calendar is on
    // screen, so the words also name the meal's day, as the cost
    // messages do (#107).
    it("names the meal's day when the person has moved to another meal", async () => {
      const store = aliceStore(row);
      const answer = answerLater();

      tap(store.residents.get("10"));
      moveToAnotherMeal(store);
      answer(REFUSAL);
      await settle();

      expect(shown()).toEqual([
        ["Alice Smith (Thu, Jun 15th): Meal has no open spots.", "error"],
      ]);
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    });

    // With no answer the page cannot tell whether the server saved the
    // change. The push for it skips this screen (it carried this
    // screen's socket id), so only a load shows what the server has.
    it("loads the meal again when the request gets no answer", async () => {
      const store = aliceStore(row);
      axios.mockRejectedValueOnce(NO_ANSWER);

      tap(store.residents.get("10"));
      await settle();

      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
      expect(shown()).toEqual([[MAYBE_ON_SCREEN, "error"]]);
    });

    // The connection can drop after the request left. The browser can
    // then wait for minutes, and all that time the page shows no message
    // and does not load the meal again, so the person cannot see what
    // was saved. Heroku's router ends a request at 30 seconds, so a
    // request still open after 35 seconds lost its answer, and the page
    // stops waiting then.
    it("stops waiting after 35 seconds on a dead connection, and loads the meal again", async () => {
      vi.useFakeTimers();
      const store = aliceStore(row);
      axios.mockImplementationOnce(deadConnection);

      tap(store.residents.get("10"));
      await vi.advanceTimersByTimeAsync(34999);
      expect(shown()).toEqual([]);
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(1);
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expect(shown()).toEqual([[MAYBE_ON_SCREEN, "error"]]);
    });

    it("loads the meal again when the request gets no answer after the row was built again", async () => {
      const store = aliceStore(row);
      const answer = answerLater();

      tap(store.residents.get("10"));
      rebuildRows(store);
      answer(NO_ANSWER);
      await settle();

      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
      expect(shown()).toEqual([[MAYBE_ON_SCREEN, "error"]]);
    });

    // The meal on screen is another one, so it is not loaded. The copy
    // of the tapped meal on the device may be out of date, so it goes,
    // and the meal is fetched when the person opens it again.
    it("drops the copy of the meal on the device, and names its day, when the person has moved on", async () => {
      const store = aliceStore(row);
      const answer = answerLater();

      tap(store.residents.get("10"));
      moveToAnotherMeal(store);
      answer(NO_ANSWER);
      await settle();

      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
      expect(shown()).toEqual([[MAYBE_LEFT, "error"]]);
    });
  });

  // An answer with no words from the app: Rails' own 500 page, or
  // Heroku's router page. The request may still have been saved, the
  // same as with no answer (noAnswerFromApp in data_store_bills.ts).
  it("treats a 5xx page with no message from the app as no answer", async () => {
    const store = aliceStore({ attending: false });
    axios.mockRejectedValueOnce(ROUTER_TIMEOUT);

    store.residents.get("10").toggleAttending();
    await settle();

    expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
    expect(shown()).toEqual([[MAYBE_ON_SCREEN, "error"]]);
  });

  // The app's own 5xx answers have words, and say nothing was saved.
  it("shows the app's own words on a 5xx answer, and loads nothing", async () => {
    const store = aliceStore({ attending: false });
    axios.mockRejectedValueOnce({
      response: {
        status: 503,
        data: { message: "The server is busy right now. Nothing was saved." },
      },
    });

    store.residents.get("10").toggleAttending();
    await settle();

    expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    expect(shown()).toEqual([
      [
        "Alice Smith: The server is busy right now. Nothing was saved.",
        "error",
      ],
    ]);
  });

  // An answer the page cannot read has no words to show.
  it("says the server had a problem when an answer from the app has no words", async () => {
    const store = aliceStore({ attending: true });
    axios.mockRejectedValueOnce({ response: { status: 404, data: "" } });

    store.residents.get("10").toggleLate();
    await settle();

    expect(shown()).toEqual([
      ["Alice Smith: The server had a problem. Please try again.", "error"],
    ]);
  });

  // An answer with an error status is an error, whatever its body says
  // (handle_axios_error.js). The one "warning" the server sends, the
  // bills save's third-cook advice, is a 200.
  it("shows an answer marked as a warning as an error", async () => {
    const store = aliceStore({ attending: true });
    axios.mockRejectedValueOnce({
      response: {
        status: 400,
        data: { message: "Look at this.", type: "warning" },
      },
    });

    store.residents.get("10").toggleVeg();
    await settle();

    expect(shown()).toEqual([["Alice Smith: Look at this.", "error"]]);
  });

  // The name is the one a sentence uses. A row from a copy of the meal
  // saved before short_name existed has only the list name.
  it("uses the list name when the row has no short name", async () => {
    const store = aliceStore({ attending: true, short_name: "" });
    axios.mockRejectedValueOnce(REFUSAL);

    store.residents.get("10").toggleLate();
    await settle();

    expect(shown()).toEqual([
      ["A - Alice Smith: Meal has no open spots.", "error"],
    ]);
  });
});
