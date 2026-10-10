import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { comparer, reaction } from "mobx";

// What the meal page counts, and which controls take taps, while a
// request from the sign-up list waits for its answer (S4). Mock
// external modules before importing stores.
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

vi.mock("../../../app/frontend/src/helpers/bugsnag.js", () => ({
  notifyError: vi.fn(),
}));

import axios from "axios";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";
import { deadConnection } from "../helpers/dead_connection.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

const REFUSAL = {
  response: { status: 400, data: { message: "Meal has no open spots." } },
};
const NO_ANSWER = { request: {} };

// The meal closed at noon. Rows and guests made after that can still be
// taken back.
const CLOSED_AT = new Date(2023, 5, 15, 12).getTime();
const AFTER_CLOSE = new Date(2023, 5, 15, 13).getTime();

// What the server answers for a sign-up (MealResidentSerializer).
const MEAL_RESIDENT = {
  status: 200,
  data: {
    id: 900,
    meal_id: 1,
    resident_id: 10,
    late: false,
    vegetarian: false,
    created_at: "2023-06-15T18:30:00.000Z",
  },
};

// What the server answers for a guest it added (GuestSerializer).
function added(id, host = 10) {
  return {
    status: 200,
    data: {
      id,
      meal_id: 1,
      resident_id: host,
      vegetarian: false,
      created_at: "2023-06-15T18:30:00.000Z",
    },
  };
}

// What the server answers for a guest add key it has seen
// (GuestReplayedSerializer).
function replayed(id) {
  return {
    status: 200,
    data: {
      message: "This guest was already added, so nothing more was added.",
      type: "replayed",
      guest: added(id).data,
    },
  };
}

// The answer each tap below gets when the server says yes.
const YES = {
  "a sign-up": MEAL_RESIDENT,
  "a take-off": { status: 200, data: {} },
  "a Late tap": { status: 200, data: {} },
  "a Veg tap": { status: 200, data: {} },
  "a guest add": added(555),
  "a guest removal": { status: 200, data: {} },
};

// The six requests a tap on a row of the sign-up list sends, and Alice's
// row for each.
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

// A closed meal with a cap of 5. Alice and Bob signed up after the
// close, unless the test says otherwise, and Alice brought guest 100
// after the close. So Total is 3 and Extras is 2.
function closedStore(alice = { attending: true }) {
  const store = createDataStore({
    mealProps: {
      closed: true,
      closed_at: CLOSED_AT,
      extras: alice.attending ? 2 : 3,
      date: new Date(2023, 5, 15),
    },
    residents: [
      {
        id: 10,
        meal_id: 1,
        name: "A - Alice Smith",
        short_name: "Alice Smith",
        attending_at: alice.attending ? AFTER_CLOSE : null,
        ...alice,
      },
      {
        id: 11,
        meal_id: 1,
        name: "B - Bob Jones",
        short_name: "Bob Jones",
        attending: true,
        attending_at: AFTER_CLOSE,
      },
    ],
    guests: [{ id: 100, meal_id: 1, resident_id: 10, created_at: AFTER_CLOSE }],
  });
  loadDataAsyncSpy = stubAction(store, "loadDataAsync");
  window.Comeals.socketId = "test";
  return store;
}

// The same meal as the server sends it (MealFormSerializer): cap 5,
// Alice and Bob signed up after the close, and Alice's guests, 100
// unless the test says otherwise.
function mealForm({ guests = [100] } = {}) {
  const row = (id, name, shortName) => ({
    id,
    meal_id: 1,
    name,
    short_name: shortName,
    attending: true,
    attending_at: new Date(AFTER_CLOSE).toISOString(),
    late: false,
    vegetarian: false,
    can_cook: true,
    active: true,
  });
  return {
    id: 1,
    date: "2023-06-15",
    description: "",
    closed: true,
    closed_at: new Date(CLOSED_AT).toISOString(),
    reconciled: false,
    max: 5,
    next_id: null,
    prev_id: null,
    residents: [
      row(10, "A - Alice Smith", "Alice Smith"),
      row(11, "B - Bob Jones", "Bob Jones"),
    ],
    guests: guests.map((id) => ({
      id,
      meal_id: 1,
      resident_id: 10,
      vegetarian: false,
      created_at: new Date(AFTER_CLOSE).toISOString(),
    })),
    bills: [],
  };
}

const alice = (store) => store.residents.get("10");
const bob = (store) => store.residents.get("11");

// The next request waits until the test answers it. Returns the answer
// and the refusal.
function answerLater() {
  let answer;
  let refuse;
  axios.mockImplementationOnce(
    () =>
      new Promise((resolve, reject) => {
        answer = resolve;
        refuse = reject;
      }),
  );
  return {
    answer: (response) => answer(response),
    refuse: (error) => refuse(error),
  };
}

// Every change to what the info box shows and the cap the Extras boxes
// send: [Extras, Total, cap]. One entry per change a person could see.
function watchCounts(store) {
  const seen = [];
  const stop = reaction(
    () => [store.meal.extras, store.attendeesCount, store.meal.max],
    (counts) => seen.push(counts),
    { equals: comparer.structural },
  );
  return {
    seen,
    stop,
  };
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
      attending: true,
      attending_at: AFTER_CLOSE,
    });
  });
}

// The person went to meal 2 and came back to meal 1 while the request
// was out. Leaving a meal drops its node (switchMeals), so meal 1 comes
// back as a new node.
function leaveAndComeBack(store) {
  stage(store, () => {
    store.meals.push({ id: 2, date: new Date(2023, 5, 16) });
    store.meal = 2;
    store.meals.remove(store.meals.find((meal) => meal.id === 1));
    store.residents.clear();
    store.guests.clear();
    store.meals.push({
      id: 1,
      closed: true,
      closed_at: CLOSED_AT,
      extras: 2,
      date: new Date(2023, 5, 15),
    });
    store.meal = 1;
  });
}

async function settle() {
  await new Promise((r) => setTimeout(r, 0));
}

function guestKeysSent() {
  return axios.mock.calls
    .map(([config]) => config)
    .filter(
      (config) => config.method === "post" && config.url.endsWith("/guests"),
    )
    .map((config) => config.headers["Idempotency-Key"]);
}

describe("while a request from the sign-up list waits", () => {
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

  // A cap picked now would be worked out from a head count that is
  // about to change. A cook who picks 2 while a guest add waits would
  // end up with 1 extra.
  describe("the Extras boxes", () => {
    describe.each(TAPS)("for %s", (what, row, tap) => {
      it("are locked until the server says yes, and a pick sends nothing then", async () => {
        const store = closedStore(row);
        const later = answerLater();

        tap(alice(store));
        await settle();
        expect(store.meal.extrasLocked).toBe(true);
        store.meal.setExtras(5);
        expect(axios).toHaveBeenCalledTimes(1);

        later.answer(YES[what]);
        await settle();
        expect(store.meal.extrasLocked).toBe(false);
      });

      it("are unlocked when the server says no", async () => {
        const store = closedStore(row);
        const later = answerLater();

        tap(alice(store));
        later.refuse(REFUSAL);
        await settle();

        expect(store.meal.extrasLocked).toBe(false);
      });

      // No answer: the server may have written the request, and the page
      // loads the meal again to show what it has. Until that load lands,
      // the head count on the screen may be wrong, so a cap picked then
      // may be wrong too.
      it("stay locked when no answer comes, until the meal loads from the server again", async () => {
        const store = closedStore(row);
        const later = answerLater();

        tap(alice(store));
        later.refuse(NO_ANSWER);
        await settle();
        expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
        expect(store.meal.extrasLocked).toBe(true);

        // The copy on the device is not what the server has now.
        store.loadData(mealForm(), "device");
        expect(store.meal.extrasLocked).toBe(true);

        store.loadData(mealForm(), "server");
        expect(store.meal.extrasLocked).toBe(false);
      });

      // The server said yes, but a load built the rows again while the
      // request was out, perhaps from a read made before the write. The
      // page loads the meal again, and until that load lands the head
      // count on the screen may be wrong.
      it("stay locked when the server says yes after the rows were built again, until the meal loads from the server again", async () => {
        const store = closedStore(row);
        const later = answerLater();

        tap(alice(store));
        rebuildRows(store);
        later.answer(YES[what]);
        await settle();
        expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
        expect(store.meal.extrasLocked).toBe(true);

        store.loadData(mealForm(), "server");
        expect(store.meal.extrasLocked).toBe(false);
      });
    });

    it("stay locked until every waiting request is answered", async () => {
      const store = closedStore();
      const late = answerLater();
      const veg = answerLater();

      alice(store).toggleLate();
      bob(store).toggleVeg();
      late.answer({ status: 200, data: {} });
      await settle();
      expect(store.meal.extrasLocked).toBe(true);

      veg.answer({ status: 200, data: {} });
      await settle();
      expect(store.meal.extrasLocked).toBe(false);
    });

    // The answer finds the row that was tapped gone, so the meal loads
    // again, and the boxes stay locked until that load lands.
    it("stay locked when the rows were built again while the request waits", async () => {
      const store = closedStore();
      const later = answerLater();

      alice(store).toggleLate();
      rebuildRows(store);
      expect(store.meal.extrasLocked).toBe(true);

      later.answer({ status: 200, data: {} });
      await settle();
      expect(store.meal.extrasLocked).toBe(true);

      store.loadData(mealForm(), "server");
      expect(store.meal.extrasLocked).toBe(false);
    });

    it("stay locked when the person leaves the meal and comes back while the request waits", async () => {
      const store = closedStore();
      const later = answerLater();

      alice(store).toggleLate();
      leaveAndComeBack(store);
      expect(store.meal.extrasLocked).toBe(true);

      later.answer({ status: 200, data: {} });
      await settle();
      expect(store.meal.extrasLocked).toBe(true);

      store.loadData(mealForm(), "server");
      expect(store.meal.extrasLocked).toBe(false);
    });

    // The page does not know the head count until a load lands.
    it("stay locked when the load after no answer fails, until a later load lands", async () => {
      const store = closedStore();
      const later = answerLater();

      alice(store).toggleLate();
      later.refuse(NO_ANSWER);
      await settle();
      // The load failed: nothing reached loadData.
      expect(store.meal.extrasLocked).toBe(true);

      store.loadData(mealForm(), "server");
      expect(store.meal.extrasLocked).toBe(false);
    });

    // The person moved on to meal 2 before a rebuilt row's answer came.
    // Meal 1's head count is known again only when meal 1 loads.
    it("stay locked on a meal the person left, until that meal loads from the server", async () => {
      const store = closedStore();
      const later = answerLater();

      alice(store).toggleLate();
      rebuildRows(store);
      stage(store, () => {
        store.meals.push({ id: 2, closed: true, extras: 1 });
        store.meal = 2;
      });
      later.answer({ status: 200, data: {} });
      await settle();
      expect(store.signupRequestWaiting(1)).toBe(true);

      store.loadData({ ...mealForm(), id: 2 }, "server");
      expect(store.signupRequestWaiting(1)).toBe(true);

      stage(store, () => {
        store.meal = 1;
      });
      store.loadData(mealForm(), "server");
      expect(store.signupRequestWaiting(1)).toBe(false);
    });

    it("of another meal are not locked", () => {
      const store = closedStore();
      answerLater();

      alice(store).toggleLate();
      stage(store, () => {
        store.meals.push({ id: 2, closed: true, extras: 1 });
        store.meal = 2;
      });

      expect(store.meal.extrasLocked).toBe(false);
    });

    it("are locked while an Extras save waits, as before", () => {
      const store = closedStore();
      answerLater();

      store.meal.setExtras(4);

      expect(store.meal.extrasLocked).toBe(true);
    });
  });

  describe("a guest add", () => {
    // Before S4 the seat went at the tap and the guest at the answer, so
    // for that time the page counted one seat less than the meal had.
    it("changes Extras, Total and the cap together when the server says yes, and nothing before", async () => {
      const store = closedStore();
      const counts = watchCounts(store);
      const later = answerLater();

      alice(store).addGuest({ vegetarian: false });
      expect(counts.seen).toEqual([]);

      later.answer(added(555));
      await settle();
      expect(counts.seen).toEqual([[1, 4, 5]]);
      expect(alice(store).guestsCount).toBe(2);
      counts.stop();
    });

    it("changes nothing when the server says no", async () => {
      const store = closedStore();
      const counts = watchCounts(store);
      const later = answerLater();

      alice(store).addGuest({ vegetarian: false });
      later.refuse(REFUSAL);
      await settle();

      expect(counts.seen).toEqual([]);
      expect(store.meal.extras).toBe(2);
      counts.stop();
    });

    it("changes nothing when no answer comes", async () => {
      const store = closedStore();
      const counts = watchCounts(store);
      const later = answerLater();

      alice(store).addGuest({ vegetarian: false });
      later.refuse(NO_ANSWER);
      await settle();

      expect(counts.seen).toEqual([]);
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      counts.stop();
    });

    // A load built the rows again while the add was out, from a read
    // made before the guest was written. The add's answer still shows
    // the guest and takes its seat, so the person does not tap again
    // for a guest that was added, and Extras, Total and the cap agree.
    // The meal still loads again, to show what else the server has.
    describe("answered after the rows were built again", () => {
      it("shows the guest and takes its seat at once", async () => {
        const store = closedStore();
        const later = answerLater();

        alice(store).addGuest({ vegetarian: false });
        rebuildRows(store);
        const counts = watchCounts(store);
        later.answer(added(555));
        await settle();

        expect(alice(store).guestsCount).toBe(2);
        // The rows built again have Alice only, so Total is 3 with the
        // guest. Extras and Total change in one step, and the cap stays.
        expect(counts.seen).toEqual([[1, 3, 4]]);
        expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
        counts.stop();
      });

      // The read was made after the guest was written, so the load
      // already counted it.
      it("takes no second seat when the load already had the guest", async () => {
        const store = closedStore();
        const later = answerLater();

        alice(store).addGuest({ vegetarian: false });
        rebuildRows(store);
        stage(store, () => {
          store.guests.put({
            id: 555,
            meal_id: 1,
            resident_id: 10,
            created_at: AFTER_CLOSE,
          });
          store.meal.extras = 1;
        });
        later.answer(added(555));
        await settle();

        expect(alice(store).guestsCount).toBe(2);
        expect(store.meal.extras).toBe(1);
      });

      it("shows nothing on the meal the person moved on to", async () => {
        const store = closedStore();
        const later = answerLater();

        alice(store).addGuest({ vegetarian: false });
        stage(store, () => {
          store.meals.push({ id: 2, closed: true, extras: 1 });
          store.meal = 2;
          store.residents.clear();
          store.guests.clear();
        });
        later.answer(added(555));
        await settle();

        expect(store.guests.size).toBe(0);
        expect(store.meal.extras).toBe(1);
        expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      });

      // The S4 review found this. Before, the guest showed only when the
      // load landed, and a tap in that time sent a new key: a second
      // guest, and the host paid twice. Now a tap then is for one guest
      // more, which the screen shows.
      it("lets the next tap ask for one guest more, with the guest on the screen", async () => {
        const store = closedStore();
        const later = answerLater();

        alice(store).addGuest({ vegetarian: false });
        rebuildRows(store);
        later.answer(added(555));
        await settle();
        axios.mockResolvedValueOnce(added(556));
        alice(store).addGuest({ vegetarian: false });
        await settle();

        expect(guestKeysSent()).toHaveLength(2);
        expect(alice(store).guestsCount).toBe(3);
        expect(store.meal.extras).toBe(0);
      });
    });

    // An open meal has no seat count, so before S4 nothing on the page
    // changed at the tap, and a second tap added a second guest.
    describe("the host's add-guest control", () => {
      it("takes no taps while the host's add waits, and takes them again after the answer", async () => {
        const store = closedStore();
        const later = answerLater();

        alice(store).addGuest({ vegetarian: false });
        expect(store.guestAddWaiting(1, 10)).toBe(true);
        alice(store).addGuest({ vegetarian: true });
        expect(guestKeysSent()).toHaveLength(1);

        later.answer(added(555));
        await settle();
        expect(store.guestAddWaiting(1, 10)).toBe(false);

        axios.mockResolvedValueOnce(added(556));
        alice(store).addGuest({ vegetarian: false });
        await settle();
        expect(guestKeysSent()).toHaveLength(2);
        expect(alice(store).guestsCount).toBe(3);
      });

      it("of another host still takes taps", async () => {
        const store = closedStore();
        answerLater();
        axios.mockResolvedValueOnce(added(556, 11));

        alice(store).addGuest({ vegetarian: false });
        bob(store).addGuest({ vegetarian: false });
        await settle();

        expect(guestKeysSent()).toHaveLength(2);
        expect(store.guestAddWaiting(1, 10)).toBe(true);
        expect(store.guestAddWaiting(1, 11)).toBe(false);
        expect(bob(store).guestsCount).toBe(1);
      });

      it("of the same host on another meal still takes taps", () => {
        const store = closedStore();
        answerLater();

        alice(store).addGuest({ vegetarian: false });

        expect(store.guestAddWaiting(1, 10)).toBe(true);
        expect(store.guestAddWaiting(2, 10)).toBe(false);
      });

      it("takes taps again when the server says no, or no answer comes", async () => {
        for (const error of [REFUSAL, NO_ANSWER]) {
          const store = closedStore();
          const later = answerLater();

          alice(store).addGuest({ vegetarian: false });
          later.refuse(error);
          await settle();

          expect(store.guestAddWaiting(1, 10)).toBe(false);
        }
      });

      // A load builds every row again. The add is still out, and the
      // new row may not show its guest yet.
      it("takes no taps while the add waits, also after the rows were built again", async () => {
        const store = closedStore();
        const later = answerLater();

        alice(store).addGuest({ vegetarian: false });
        rebuildRows(store);
        alice(store).addGuest({ vegetarian: false });
        expect(guestKeysSent()).toHaveLength(1);

        later.answer(added(555));
        await settle();
        expect(store.guestAddWaiting(1, 10)).toBe(false);
      });

      // The server says the key's guest was already added, and that
      // guest is already on the page, so the tap is for one more guest
      // and a new add goes out. The tap is not answered until that one
      // is.
      it("takes no taps while a replayed add goes out again", async () => {
        const store = closedStore();
        axios.mockRejectedValueOnce(NO_ANSWER);
        alice(store).addGuest({ vegetarian: false });
        await settle();
        // The load after no answer shows the lost add's guest.
        store.loadData(mealForm({ guests: [100, 555] }), "server");

        axios.mockResolvedValueOnce(replayed(555));
        const oneMore = answerLater();
        alice(store).addGuest({ vegetarian: false });
        await settle();
        expect(guestKeysSent()).toHaveLength(3);
        expect(store.guestAddWaiting(1, 10)).toBe(true);
        expect(store.meal.extrasLocked).toBe(true);

        oneMore.answer(added(556));
        await settle();
        expect(store.guestAddWaiting(1, 10)).toBe(false);
        expect(store.meal.extrasLocked).toBe(false);
      });

      // The S2 review found this. A phone's connection drops after the
      // add left. The add waits 35 seconds for an answer, and its key is
      // not kept for the next tap until then. A second tap in that time
      // sent a new key, so both adds could be written and the host would
      // pay for two guests.
      it("takes no taps during the 35-second wait on a dead connection, and the tap after it sends the same key", async () => {
        vi.useFakeTimers();
        const store = closedStore();
        axios.mockImplementationOnce(deadConnection);

        alice(store).addGuest({ vegetarian: false });
        await vi.advanceTimersByTimeAsync(20000);
        alice(store).addGuest({ vegetarian: false });
        expect(guestKeysSent()).toHaveLength(1);

        await vi.advanceTimersByTimeAsync(15000);
        axios.mockResolvedValueOnce(replayed(555));
        alice(store).addGuest({ vegetarian: false });
        await vi.advanceTimersByTimeAsync(0);

        const [first, second] = guestKeysSent();
        expect(second).toBe(first);
        expect(alice(store).guestsCount).toBe(2);
      });
    });
  });

  describe("a guest removal", () => {
    it("changes Extras, Total and the cap together when the server says yes, and nothing before", async () => {
      const store = closedStore();
      const counts = watchCounts(store);
      const later = answerLater();

      alice(store).removeGuest();
      expect(counts.seen).toEqual([]);

      later.answer({ status: 200, data: {} });
      await settle();
      expect(counts.seen).toEqual([[3, 2, 5]]);
      counts.stop();
    });

    // A second tap while the first removal waits sent a second removal
    // of the same guest. The server had removed it, so the second one
    // showed "Alice Smith: The page you were looking for doesn't
    // exist..." after a removal that worked.
    describe("the host's remove-guest control", () => {
      function twoGuests() {
        const store = closedStore();
        stage(store, () => {
          store.guests.put({
            id: 101,
            meal_id: 1,
            resident_id: 10,
            created_at: AFTER_CLOSE + 1000,
          });
          store.meal.extras = 1;
        });
        return store;
      }

      function removalsSent() {
        return axios.mock.calls
          .map(([config]) => config)
          .filter((config) => config.method === "delete");
      }

      it("takes no taps while the host's removal waits, and takes them again after the answer", async () => {
        const store = twoGuests();
        const later = answerLater();

        alice(store).removeGuest();
        alice(store).removeGuest();
        expect(removalsSent()).toHaveLength(1);
        expect(store.guestRemovalWaiting(1, 10)).toBe(true);

        later.answer({ status: 200, data: {} });
        await settle();
        expect(store.guestRemovalWaiting(1, 10)).toBe(false);
        expect(toastStore.toasts).toHaveLength(0);

        alice(store).removeGuest();
        await settle();
        expect(removalsSent()).toHaveLength(2);
        expect(alice(store).guestsCount).toBe(0);
      });

      it("takes taps again when the server says no, or no answer comes", async () => {
        for (const error of [REFUSAL, NO_ANSWER]) {
          const store = twoGuests();
          const later = answerLater();

          alice(store).removeGuest();
          later.refuse(error);
          await settle();

          expect(store.guestRemovalWaiting(1, 10)).toBe(false);
        }
      });

      // A load builds every row again. The removal is still out, and the
      // new row may still show the guest.
      it("takes no taps while the removal waits, also after the rows were built again", () => {
        const store = twoGuests();
        answerLater();

        alice(store).removeGuest();
        rebuildRows(store);
        alice(store).removeGuest();

        expect(removalsSent()).toHaveLength(1);
      });

      it("of another host, or of the same host on another meal, still takes taps", () => {
        const store = twoGuests();
        answerLater();
        stage(store, () => {
          store.guests.put({
            id: 102,
            meal_id: 1,
            resident_id: 11,
            created_at: AFTER_CLOSE,
          });
          store.meal.extras = 0;
        });

        alice(store).removeGuest();
        bob(store).removeGuest();

        expect(removalsSent()).toHaveLength(2);
        expect(store.guestRemovalWaiting(1, 11)).toBe(true);
        expect(store.guestRemovalWaiting(2, 10)).toBe(false);
      });
    });
  });

  // A guest add shows nothing until the server says yes (S4), but the
  // seat it asks for is taken once the server says yes. So while it
  // waits, no other tap on the same screen may take that seat. Before
  // this, both taps went out, the server took the guest and refused the
  // other, and in between the page showed Total over the cap and
  // Extras at -1.
  describe("a guest add that waits for the last seat", () => {
    // Cap 4: Alice, Bob and Alice's guest 100 eat, and Carol, who is not
    // signed up, could take the last seat.
    function lastSeat() {
      const store = closedStore();
      stage(store, () => {
        store.meal.extras = 1;
        store.residents.put({
          id: 12,
          meal_id: 1,
          name: "C - Carol Diaz",
          short_name: "Carol Diaz",
        });
      });
      return store;
    }
    const carol = (store) => store.residents.get("12");

    it("keeps everyone else from taking the seat while it waits", () => {
      const store = lastSeat();
      answerLater();

      alice(store).addGuest({ vegetarian: false });
      expect(store.canAdd).toBe(false);
      carol(store).toggleAttending();

      expect(axios).toHaveBeenCalledTimes(1);
      expect(carol(store).attending).toBe(false);
      expect(store.meal.extras).toBe(1);
    });

    it("gives the seat back to everyone when the server says no", async () => {
      const store = lastSeat();
      const later = answerLater();

      alice(store).addGuest({ vegetarian: false });
      later.refuse(REFUSAL);
      await settle();

      expect(store.canAdd).toBe(true);
      axios.mockResolvedValueOnce(MEAL_RESIDENT);
      carol(store).toggleAttending();
      expect(carol(store).attending).toBe(true);
    });

    // The case the S4 review found, step by step: Extras never goes
    // below 0, and Total never goes over the cap.
    it("never shows Total over the cap", async () => {
      const store = lastSeat();
      const counts = watchCounts(store);
      const later = answerLater();

      alice(store).addGuest({ vegetarian: false });
      carol(store).toggleAttending();
      later.answer(added(555));
      await settle();

      expect(counts.seen).toEqual([[0, 4, 4]]);
      counts.stop();
    });

    it("leaves the other seats to other taps", async () => {
      const store = lastSeat();
      stage(store, () => {
        store.meal.extras = 2;
      });
      answerLater();
      axios.mockResolvedValueOnce(MEAL_RESIDENT);

      alice(store).addGuest({ vegetarian: false });
      expect(store.canAdd).toBe(true);
      carol(store).toggleAttending();

      expect(carol(store).attending).toBe(true);
      expect(axios).toHaveBeenCalledTimes(2);
    });

    it("counts one seat for each host whose add waits", () => {
      const store = lastSeat();
      stage(store, () => {
        store.meal.extras = 2;
      });
      answerLater();
      answerLater();

      alice(store).addGuest({ vegetarian: false });
      bob(store).addGuest({ vegetarian: true });

      expect(store.canAdd).toBe(false);
    });

    // An open meal has no cap, so a waiting add holds no seat.
    it("holds no seat on an open meal", () => {
      const store = lastSeat();
      stage(store, () => {
        store.meal.closed = false;
        store.meal.extras = null;
      });
      answerLater();

      alice(store).addGuest({ vegetarian: false });

      expect(store.canAdd).toBe(true);
    });
  });
});
