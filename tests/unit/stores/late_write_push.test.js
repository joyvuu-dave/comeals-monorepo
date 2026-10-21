import { describe, it, expect, beforeEach, vi } from "vitest";

// A request from a row of the sign-up list can reach the server after
// the page stopped waiting for it and loaded the meal again. When it is
// still written, the push for it must make this page load the meal
// again too, or the screen goes on showing the meal without the change
// (#237).
//
// Each of the six requests carries a push_token. The server sends the
// meal's push to every screen, the sender's too, with the tokens of the
// requests that caused it. The page skips a push only when every token
// in it is one of its own requests that it has not given up on: that
// request's answer shows the change. Any other push loads the meal.
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// No answer at all: the page stops waiting, and the request may still be
// written later.
const NO_ANSWER = { request: {} };

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
let pushToMeal;

// An open meal with Alice's row, and a guest of hers that can be
// removed. The meal's channel records its "update" handler, so a test
// can send a push.
function aliceStore(row) {
  const store = createDataStore({
    mealProps: { closed: false, date: "2023-06-15" },
    residents: [
      {
        id: 10,
        meal_id: 1,
        name: "A - Alice Smith",
        short_name: "Alice Smith",
        attendance_version: 3,
        ...row,
      },
    ],
    guests: [{ id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() }],
  });
  loadDataAsyncSpy = stubAction(store, "loadDataAsync");
  window.Comeals.pusher = {
    subscribe: (name) => ({
      name,
      bind: (event, handler) => {
        if (event === "update") pushToMeal = handler;
      },
    }),
    unsubscribe: () => {},
  };
  store.watchMealChannel(1);
  return store;
}

// Each request waits for the test to answer it.
function answerEachLater() {
  const answers = [];
  axios.mockImplementation(
    () =>
      new Promise((resolve, reject) => {
        answers.push({ resolve, reject });
      }),
  );
  return answers;
}

function sentToken(index = 0) {
  return axios.mock.calls[index][0].data.push_token;
}

async function settle() {
  await new Promise((r) => setTimeout(r, 0));
}

describe("the push for a request from the sign-up list", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
    pushToMeal = null;
    window.Comeals = {
      socketId: "test",
      pusher: null,
      mealChannel: null,
      calendarChannel: null,
    };
  });

  describe.each(TAPS)("%s", (_what, row, tap) => {
    it("sends a new push_token with the request", () => {
      answerEachLater();
      const store = aliceStore(row);

      tap(store.residents.get("10"));

      expect(sentToken()).toMatch(/^[0-9a-f-]{36}$/);
    });

    // The answer shows the change, so a push for it changes nothing on
    // this screen, before or after the answer.
    it("skips the push for its own request, before and after the answer", async () => {
      const answers = answerEachLater();
      const store = aliceStore(row);

      tap(store.residents.get("10"));
      pushToMeal({ message: "meal updated", push_tokens: [sentToken()] });
      answers[0].resolve({
        status: 200,
        data: {
          id: 555,
          meal_id: 1,
          resident_id: 10,
          vegetarian: false,
          late: false,
          created_at: "2023-06-15T18:30:00.000Z",
          attendance_version: 4,
          message: "ok",
        },
      });
      await settle();
      pushToMeal({ message: "meal updated", push_tokens: [sentToken()] });

      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    });

    // #237: the page gave up on the request and loaded the meal, which
    // did not have the change yet. Then the request was written.
    it("loads the meal again for the push of a request it gave up on", async () => {
      const answers = answerEachLater();
      const store = aliceStore(row);

      tap(store.residents.get("10"));
      answers[0].reject(NO_ANSWER);
      await settle();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);

      pushToMeal({ message: "meal updated", push_tokens: [sentToken()] });

      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(2);
    });
  });

  // Another screen's change, or one from a page loaded before push
  // tokens, or from admin: no token this page sent.
  it("loads the meal for a push with no token, or with a token it did not send", () => {
    aliceStore({ attending: true });

    pushToMeal({ message: "meal updated" });
    pushToMeal({ message: "meal updated", push_tokens: ["another-tab"] });
    pushToMeal(undefined);

    expect(loadDataAsyncSpy).toHaveBeenCalledTimes(3);
  });

  // One push can carry the tokens of several requests. One that is not
  // this page's own means another change is in it.
  it("loads the meal when one of several tokens is not its own", () => {
    answerEachLater();
    const store = aliceStore({ attending: true });

    store.residents.get("10").toggleLate();
    pushToMeal({
      message: "meal updated",
      push_tokens: [sentToken(), "another-tab"],
    });

    expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
  });
});
