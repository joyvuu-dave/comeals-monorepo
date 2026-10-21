import { describe, it, expect, beforeEach, vi } from "vitest";

// A tap on a row of the sign-up list sends the version of the person's
// attendance that the page expects the server to have before this write
// (attendance_version). The page does not wait for one answer before it
// sends the next tap, so a tap made while another write on the same row
// has no answer counts that write: off then on at once sends version 4,
// then 5. The server refuses a request built on another version with 409
// and type "stale", because the two requests reached it in the other
// order, or a request arrived after the page gave up on it. The page
// then loads the meal again, to show what the server has.
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
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

const STALE_WORDS =
  "This sign-up changed after the page showed it, so nothing was saved. Check it and tap again if needed.";
const STALE = {
  response: { status: 409, data: { message: STALE_WORDS, type: "stale" } },
};
const REFUSAL = {
  response: { status: 400, data: { message: "Meal has no open spots." } },
};

let loadDataAsyncSpy;

function aliceStore(row) {
  const store = createDataStore({
    mealProps: { closed: false, date: "2023-06-15" },
    residents: [
      {
        id: 10,
        meal_id: 1,
        name: "A - Alice Smith",
        short_name: "Alice Smith",
        ...row,
      },
    ],
  });
  loadDataAsyncSpy = stubAction(store, "loadDataAsync");
  window.Comeals.socketId = "test";
  return store;
}

// The requests sent so far, as [method, body].
function sent() {
  return axios.mock.calls.map(([config]) => [config.method, config.data]);
}

// Each request waits for the test to answer it, in any order.
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

async function settle() {
  await new Promise((r) => setTimeout(r, 0));
}

function shown() {
  return toastStore.toasts.map((toast) => [toast.message, toast.type]);
}

describe("the attendance version a tap sends", () => {
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

  // Case A: off, then on at once. The second tap counts the first.
  it("counts a write that has no answer yet when the next tap is sent", () => {
    answerEachLater();
    const store = aliceStore({ attending: true, attendance_version: 4 });
    const alice = store.residents.get("10");

    alice.toggleAttending();
    alice.toggleAttending();
    alice.toggleLate();
    alice.toggleVeg();

    const pushToken = expect.any(String);
    expect(sent()).toEqual([
      [
        "delete",
        { socket_id: "test", attendance_version: 4, push_token: pushToken },
      ],
      [
        "post",
        {
          late: false,
          vegetarian: false,
          socket_id: "test",
          attendance_version: 5,
          push_token: pushToken,
        },
      ],
      [
        "patch",
        {
          late: true,
          socket_id: "test",
          attendance_version: 6,
          push_token: pushToken,
        },
      ],
      [
        "patch",
        {
          vegetarian: true,
          socket_id: "test",
          attendance_version: 7,
          push_token: pushToken,
        },
      ],
    ]);
  });

  // Case A, when the sign-up reached the server first: it was refused,
  // and the take-off was written. The screen still says signed up, so
  // the meal loads again and the person is told.
  it("loads the meal again and says why when the server answers stale", async () => {
    const answers = answerEachLater();
    const store = aliceStore({ attending: true, attendance_version: 4 });
    const alice = store.residents.get("10");

    alice.toggleAttending();
    alice.toggleAttending();
    answers[1].reject(STALE);
    answers[0].resolve({ status: 200, data: { message: "ok" } });
    await settle();

    expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
    expect(shown()).toEqual([[`Alice Smith: ${STALE_WORDS}`, "error"]]);
  });

  // The person went on to another meal while the request was out. That
  // meal is not loaded again; the copy of the tapped meal on the device
  // goes, so it is fetched when the person opens it again.
  it("drops the copy of the meal on the device when the person has moved on", async () => {
    const answers = answerEachLater();
    const store = aliceStore({ attending: false, attendance_version: 1 });

    store.residents.get("10").toggleAttending();
    stage(store, () => {
      store.meals.push({ id: 2, date: "2023-06-16" });
      store.meal = 2;
      store.residents.clear();
    });
    answers[0].reject(STALE);
    await settle();

    expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    expect(idbKeyval.del).toHaveBeenCalledWith("1");
    expect(shown()).toEqual([
      [`Alice Smith (Thu, Jun 15th): ${STALE_WORDS}`, "error"],
    ]);
  });

  // A conflict that is not "stale" (two writes at once, or the meal lock
  // was busy) wrote nothing either, and is sent again by a new tap. The
  // screen was put back already, so the meal does not load again.
  it("does not load the meal again for a conflict that is not stale", async () => {
    const answers = answerEachLater();
    const store = aliceStore({ attending: false, attendance_version: 1 });

    store.residents.get("10").toggleAttending();
    answers[0].reject({
      response: { status: 409, data: { message: "Try again." } },
    });
    await settle();

    expect(loadDataAsyncSpy).not.toHaveBeenCalled();
    expect(store.residents.get("10").attendance_version).toBe(1);
  });

  // A refusal wrote nothing, so the server's version did not move. The
  // next tap sends the version from before the refused one.
  it("takes back the count of a write the server refused", async () => {
    const answers = answerEachLater();
    const store = aliceStore({ attending: false, attendance_version: 2 });
    const alice = store.residents.get("10");

    alice.toggleAttending();
    answers[0].reject(REFUSAL);
    await settle();
    alice.toggleAttending();

    expect(sent()[1][1].attendance_version).toBe(2);
    expect(loadDataAsyncSpy).not.toHaveBeenCalled();
  });

  // A copy of the meal saved on the device before this change has no
  // version. A tap then sends none, and the server does what it did
  // before it checked versions.
  it("sends no version when the row has none", () => {
    answerEachLater();
    const store = aliceStore({ attending: false });

    store.residents.get("10").toggleAttending();

    expect(sent()[0][1]).not.toHaveProperty("attendance_version");
  });
});
