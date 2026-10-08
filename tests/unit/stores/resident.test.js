import { describe, it, expect, beforeEach, onTestFinished, vi } from "vitest";

// Mock external modules before importing stores
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import { getSnapshot } from "mobx-state-tree";
import {
  createDataStore,
  stage,
  stubAction,
} from "../helpers/create_data_store.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import contract from "../../fixtures/api_contract.json";

// What the server answers for an attendance add (MealResidentSerializer).
// The add reads its created_at. It is the file's default answer; the
// PATCH and DELETE calls ignore their answer.
const MEAL_RESIDENT = {
  id: 900,
  meal_id: 1,
  resident_id: 10,
  late: false,
  vegetarian: false,
  created_at: "2023-06-15T18:30:00.000Z",
};
axios.mockImplementation(() =>
  Promise.resolve({ status: 200, data: MEAL_RESIDENT }),
);

// What the server answers for a guest add (GuestSerializer). A guest
// add must be answered with this, or the store cannot put the guest in
// and runs its failure path instead.
function guestAnswer(overrides = {}) {
  return {
    status: 200,
    data: {
      id: 555,
      meal_id: 1,
      resident_id: 10,
      vegetarian: false,
      created_at: "2023-06-15T18:30:00.000Z",
      ...overrides,
    },
  };
}

// The real DataStore, with loadDataAsync stubbed: these tests assert
// that a dead node's ack triggers a refetch, not what the refetch does
// (data_store.test.js covers that).
let loadDataAsyncSpy;
function createStore(opts = {}) {
  const store = createDataStore(opts);
  loadDataAsyncSpy = stubAction(store, "loadDataAsync", () => {});
  window.Comeals.socketId = "test";
  return store;
}

// Stage a raced refetch: the node the action captured is destroyed.
function removeResident(store, id) {
  stage(store, () => store.residents.delete(String(id)));
}

// Reading or writing a node that has left the tree does not throw in
// tests: MobX-State-Tree only warns through console.warn, and the action
// still runs (the app turns the check off, index.jsx). So a callback
// that goes on to use a dead node shows only as this warning.
function watchDeadNodeUse() {
  const warn = vi.spyOn(console, "warn");
  onTestFinished(() => warn.mockRestore());
  return function expectNoDeadNodeUse() {
    const deadNodeWarnings = warn.mock.calls.filter((args) =>
      String(args[0]).includes("mobx-state-tree"),
    );
    expect(deadNodeWarnings).toEqual([]);
  };
}

describe("Resident model", () => {
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

  // The answers above stand in for the server, so they must have the
  // keys it really sends (tests/fixtures/api_contract.json is written by
  // hand, and spec/serializers/api_contract_spec.rb checks it against
  // the Rails serializers).
  it("answers adds with the keys the server sends", () => {
    expect(Object.keys(MEAL_RESIDENT).sort()).toEqual(contract.MealResident);
    expect(Object.keys(guestAnswer().data).sort()).toEqual(contract.Guest);
  });

  // ── guests view ──

  describe("guests", () => {
    it("returns guests belonging to this resident", () => {
      const store = createStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true },
          { id: 11, meal_id: 1, name: "Bob", attending: true },
        ],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
          { id: 101, meal_id: 1, resident_id: 10, created_at: Date.now() },
          { id: 102, meal_id: 1, resident_id: 11, created_at: Date.now() },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.guests).toHaveLength(2);
      expect(alice.guests.map((g) => g.id)).toEqual(
        expect.arrayContaining([100, 101]),
      );
    });

    it("returns empty array when resident has no guests", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      expect(alice.guests).toHaveLength(0);
    });
  });

  // ── guestsCount view ──

  describe("guestsCount", () => {
    it("returns the number of guests for this resident", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
          { id: 101, meal_id: 1, resident_id: 10, created_at: Date.now() },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.guestsCount).toBe(2);
    });

    it("returns 0 when resident has no guests", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      expect(alice.guestsCount).toBe(0);
    });
  });

  // ── canRemove view ──

  describe("canRemove", () => {
    it("Scenario 1: returns false when not attending", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemove).toBe(false);
    });

    it("Scenario 2: returns true when attending and meal is open", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemove).toBe(true);
    });

    it("Scenario 3: returns true when attending, meal closed, added after closed_at", () => {
      const closedTime = new Date(2023, 0, 1, 12, 0, 0);
      const attendedTime = new Date(2023, 0, 1, 13, 0, 0); // after closed

      const store = createStore({
        mealProps: { closed: true, closed_at: closedTime.getTime() },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: attendedTime.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemove).toBe(true);
    });

    // The server lets a signup go from a closed meal only when it was
    // made after the close (ClosedMealAttendanceFreeze). Guests do not
    // change that.
    it.each([
      ["with a guest", 1],
      ["with no guest", 0],
    ])(
      "returns false for a signup made before the close, %s",
      (_name, guestCount) => {
        const attendedTime = new Date(2023, 0, 1, 11, 0, 0);
        const closedTime = new Date(2023, 0, 1, 12, 0, 0);

        const store = createStore({
          mealProps: { closed: true, closed_at: closedTime.getTime() },
          residents: [
            {
              id: 10,
              meal_id: 1,
              name: "Alice",
              attending: true,
              attending_at: attendedTime.getTime(),
            },
          ],
          guests: [
            {
              id: 100,
              meal_id: 1,
              resident_id: 10,
              created_at: attendedTime.getTime(),
            },
          ].slice(0, guestCount),
        });

        const alice = store.residents.get("10");
        expect(alice.guestsCount).toBe(guestCount);
        expect(alice.canRemove).toBe(false);
      },
    );
  });

  // ── canRemoveGuest view ──

  describe("canRemoveGuest", () => {
    it("Scenario 1: returns false when no guests", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemoveGuest).toBe(false);
    });

    it("Scenario 2: returns true when has guests and meal is open", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemoveGuest).toBe(true);
    });

    it("Scenario 3: returns true when has guests, meal closed, guest added after closed_at", () => {
      const closedTime = new Date(2023, 0, 1, 12, 0, 0);
      const guestTime = new Date(2023, 0, 1, 13, 0, 0);

      const store = createStore({
        mealProps: { closed: true, closed_at: closedTime.getTime() },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: guestTime.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemoveGuest).toBe(true);
    });

    it("returns false when every guest was added before closed_at", () => {
      const guestTime = new Date(2023, 0, 1, 11, 0, 0);
      const closedTime = new Date(2023, 0, 1, 12, 0, 0);

      const store = createStore({
        mealProps: { closed: true, closed_at: closedTime.getTime() },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: guestTime.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemoveGuest).toBe(false);
    });

    it("a guest added exactly at closed_at cannot be removed", () => {
      const guestTime = new Date(2023, 0, 1, 12, 0, 0);
      const closedTime = new Date(2023, 0, 1, 12, 0, 0); // exactly equal

      const store = createStore({
        mealProps: { closed: true, closed_at: closedTime.getTime() },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: guestTime.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      // Not strictly after the close, the same rule as the server's.
      expect(alice.canRemoveGuest).toBe(false);
    });
  });

  // ── toggleAttending ──

  describe("toggleAttending", () => {
    it("adds resident when not attending and meal is open", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(true);
    });

    it("removes resident when attending and meal is open", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(false);
    });

    it("stores the server's created_at as attending_at, not the client clock", async () => {
      const serverTime = "2023-06-15T18:30:00.000Z";
      axios.mockResolvedValueOnce({
        status: 200,
        data: { created_at: serverTime },
      });

      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();

      await new Promise((r) => setTimeout(r, 0));

      expect(alice.attending_at.getTime()).toBe(new Date(serverTime).getTime());
    });

    it("blocks adding when meal is closed and extras < 1 (null extras)", () => {
      const store = createStore({
        mealProps: { closed: true, extras: null },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      // null < 1 is true, so should block
      expect(alice.attending).toBe(false);
    });

    it("blocks adding when meal is closed and extras is 0", () => {
      const store = createStore({
        mealProps: { closed: true, extras: 0 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(false);
    });

    it("allows adding when meal is closed and extras >= 1", () => {
      const store = createStore({
        mealProps: { closed: true, extras: 5 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(true);
    });

    it("blocks removing when meal is closed and canRemove is false", () => {
      const attendedTime = new Date(2023, 0, 1, 11, 0, 0);
      const closedTime = new Date(2023, 0, 1, 12, 0, 0);

      const store = createStore({
        mealProps: {
          closed: true,
          closed_at: closedTime.getTime(),
          extras: 5,
        },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: attendedTime.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      // Signed up before the close.
      expect(alice.canRemove).toBe(false);
      alice.toggleAttending();
      expect(alice.attending).toBe(true); // unchanged
    });

    it("decrements extras when adding a resident", () => {
      const store = createStore({
        mealProps: { closed: true, extras: 5 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(store.meal.extras).toBe(4);
    });

    // The one removal that changes a seat count: someone who joined a
    // closed meal after it closed backs out (the server allows it,
    // ClosedMealAttendanceFreeze). An open meal has no seat count.
    it("increments extras when a resident who joined after the close backs out", async () => {
      const store = createStore({
        mealProps: {
          closed: true,
          closed_at: new Date(2023, 0, 1, 12, 0, 0).getTime(),
          extras: 2,
        },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: new Date(2023, 0, 1, 13, 0, 0).getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(false);
      expect(store.meal.extras).toBe(3);
      expect(axios).toHaveBeenCalledWith({
        method: "delete",
        url: "/api/v1/meals/1/residents/10",
        withCredentials: true,
        data: { socket_id: "test" },
      });

      await new Promise((r) => setTimeout(r, 0));
      expect(alice.attending).toBe(false);
      expect(alice.attending_at).toBeNull();
      expect(store.meal.extras).toBe(3);
    });

    it("sets late flag when options.late is true", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: false, late: false },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending({ late: true });
      expect(alice.attending).toBe(true);
      expect(alice.late).toBe(true);
    });

    it("sets vegetarian flag when options.toggleVeg is true", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            vegetarian: false,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending({ toggleVeg: true });
      expect(alice.attending).toBe(true);
      expect(alice.vegetarian).toBe(true);
    });

    // A plain add carries the profile's veg value to the server.
    it("makes correct API call when adding", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            vegetarian: true,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();

      expect(axios).toHaveBeenCalledWith({
        method: "post",
        url: "/api/v1/meals/1/residents/10",
        withCredentials: true,
        data: { late: false, vegetarian: true, socket_id: "test" },
      });
    });

    // The Late and Veg switches sign up someone who is not attending.
    // The server saves the flags it is sent, so they must be the flags
    // after the tap, or the screen and the server disagree.
    it.each([
      ["toggleLate", { late: true, vegetarian: false }],
      ["toggleVeg", { late: false, vegetarian: true }],
    ])("an add from %s sends the flag the tap set", (action, flags) => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            late: false,
            vegetarian: false,
          },
        ],
      });

      store.residents.get("10")[action]();

      expect(axios).toHaveBeenCalledWith({
        method: "post",
        url: "/api/v1/meals/1/residents/10",
        withCredentials: true,
        data: { ...flags, socket_id: "test" },
      });
    });

    it("makes correct API call when removing", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();

      expect(axios).toHaveBeenCalledWith(
        expect.objectContaining({
          method: "delete",
          url: expect.stringContaining("/api/v1/meals/1/residents/10"),
        }),
      );
    });
  });

  // ── toggleAttending edge cases ──

  describe("toggleAttending edge cases", () => {
    it("clears late flag when removing attendance", () => {
      // When a resident removes themselves, late should reset to false
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: true },
        ],
      });
      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(false);
      expect(alice.late).toBe(false);
    });

    it("boundary: adding at extras=1 decrements to 0", () => {
      // Boundary: after this add, no more people can join
      const store = createStore({
        mealProps: { closed: true, extras: 1 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });
      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(true);
      expect(store.meal.extras).toBe(0);
    });

    it("removing from an open meal leaves extras null", () => {
      // incrementExtras is a no-op when extras is null
      const store = createStore({
        mealProps: { closed: false, extras: null },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });
      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(false);
      expect(store.meal.extras).toBeNull(); // increment was a no-op
    });
  });

  // ── a reconciled meal ──

  // A settled meal's sign-ups and guests are final. The screen locks
  // its controls, but the name cell is locked only by the CSS rule
  // pointer-events: none, and a click sent to the cell itself (a screen
  // reader's activate action, or a script) does not go through that
  // rule. So every action checks the meal and sends nothing. A meal can
  // be settled while it is still open (Meal.settleable_by does not look
  // at closed), so both states are here. In the closed one Alice signed
  // up after the close and there are seats left, so only the settlement
  // stops each action.
  describe("on a reconciled meal", () => {
    const CLOSED_AT = new Date(2023, 0, 1, 12, 0, 0).getTime();
    const AFTER_CLOSE = new Date(2023, 0, 1, 13, 0, 0).getTime();
    const signedUp = { attending: true, attending_at: AFTER_CLOSE };
    const notSignedUp = { attending: false };

    describe.each([
      ["open", { closed: false, reconciled: true }],
      [
        "closed with seats left",
        { closed: true, closed_at: CLOSED_AT, extras: 3, reconciled: true },
      ],
    ])("that is %s", (_, mealProps) => {
      it.each([
        ["a sign-up from the name", notSignedUp, (a) => a.toggleAttending()],
        ["a removal from the name", signedUp, (a) => a.toggleAttending()],
        [
          "the late switch of someone signed up",
          signedUp,
          (a) => a.toggleLate(),
        ],
        ["the veg switch of someone signed up", signedUp, (a) => a.toggleVeg()],
        [
          "the late switch of someone not signed up",
          notSignedUp,
          (a) => a.toggleLate(),
        ],
        [
          "the veg switch of someone not signed up",
          notSignedUp,
          (a) => a.toggleVeg(),
        ],
        ["a guest add", signedUp, (a) => a.addGuest({ vegetarian: true })],
        ["a guest removal", signedUp, (a) => a.removeGuest()],
      ])("sends nothing and changes nothing for %s", async (_, alice, act) => {
        const store = createStore({
          mealProps,
          residents: [{ id: 10, meal_id: 1, name: "Alice", ...alice }],
          // A guest added after the close, so the closed meal would let
          // Alice remove it.
          guests: [
            { id: 100, meal_id: 1, resident_id: 10, created_at: AFTER_CLOSE },
          ],
        });
        const before = getSnapshot(store);

        act(store.residents.get("10"));
        await new Promise((r) => setTimeout(r, 0));

        expect(axios).not.toHaveBeenCalled();
        expect(getSnapshot(store)).toEqual(before);
      });
    });
  });

  // ── a retired resident ──

  // A retired resident has moved out or died. The sign-up list shows
  // one who is not signed up only for two reasons: they have a guest
  // on the meal (#134), or they were signed up when the meal was loaded
  // and a tap took them off (#91). Only the second may be signed up, so
  // the wrong tap can be undone. The screen locks the name and the
  // switches in the first case, but a click sent to the name cell
  // itself gets past pointer-events: none, so the action checks too.
  describe("a retired resident", () => {
    it.each([
      ["the name", (a) => a.toggleAttending()],
      ["the late switch", (a) => a.toggleLate()],
      ["the veg switch", (a) => a.toggleVeg()],
    ])(
      "is not signed up from %s when they were not signed up at load",
      async (_, act) => {
        const store = createStore({
          mealProps: { closed: false },
          residents: [{ id: 10, meal_id: 1, name: "Alice", active: false }],
          guests: [
            { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
          ],
        });
        const alice = store.residents.get("10");
        alice.rememberAtLoad();
        const before = getSnapshot(store);

        act(alice);
        await new Promise((r) => setTimeout(r, 0));

        expect(axios).not.toHaveBeenCalled();
        expect(getSnapshot(store)).toEqual(before);
      },
    );

    // The rule stops only a sign-up. Alice's row was not made by
    // loadData, so nothing was remembered at load.
    it("can always be taken off when signed up", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            active: false,
            attending: true,
          },
        ],
      });
      const alice = store.residents.get("10");

      alice.toggleAttending();

      expect(alice.attending).toBe(false);
      expect(axios).toHaveBeenCalledWith(
        expect.objectContaining({
          method: "delete",
          url: "/api/v1/meals/1/residents/10",
        }),
      );
    });

    it("is signed up again after a tap took them off, when they were signed up at load", async () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            active: false,
            attending: true,
            attending_at: new Date("2023-06-15T18:00:00.000Z"),
          },
        ],
      });
      const alice = store.residents.get("10");
      alice.rememberAtLoad();

      alice.toggleAttending();
      await new Promise((r) => setTimeout(r, 0));
      expect(alice.attending).toBe(false);

      alice.toggleAttending();
      await new Promise((r) => setTimeout(r, 0));

      expect(alice.attending).toBe(true);
      expect(axios).toHaveBeenLastCalledWith(
        expect.objectContaining({
          method: "post",
          url: "/api/v1/meals/1/residents/10",
        }),
      );
    });
  });

  // ── addGuest boundary ──

  describe("addGuest boundary", () => {
    it("decrements extras when adding a guest to a closed meal", async () => {
      // Guest additions also consume an extras slot, and the server's
      // yes keeps it taken.
      axios.mockResolvedValueOnce(guestAnswer());
      const store = createStore({
        mealProps: { closed: true, extras: 1 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });
      const alice = store.residents.get("10");
      alice.addGuest({ vegetarian: false });
      expect(store.meal.extras).toBe(0);

      await new Promise((r) => setTimeout(r, 0));
      expect(store.meal.extras).toBe(0);
      expect(alice.guestsCount).toBe(1);
    });

    // The guest shows from the server's answer. Without it a person
    // taps again and makes a second real guest, a second charge.
    it("a guest the server saved shows, with the server's time", async () => {
      axios.mockResolvedValueOnce(
        guestAnswer({
          id: 555,
          vegetarian: true,
          created_at: "2026-01-14T18:00:00Z",
        }),
      );
      const store = createStore({
        mealProps: { closed: true, closed_at: Date.now(), extras: 2 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });
      const alice = store.residents.get("10");
      alice.addGuest({ vegetarian: true });

      expect(axios).toHaveBeenCalledWith({
        method: "post",
        url: "/api/v1/meals/1/residents/10/guests",
        withCredentials: true,
        data: { vegetarian: true, socket_id: "test" },
      });
      await new Promise((r) => setTimeout(r, 0));

      const guest = store.guests.get("555");
      expect(guest.resident_id).toBe(10);
      expect(guest.vegetarian).toBe(true);
      expect(guest.created_at).toEqual(new Date("2026-01-14T18:00:00Z"));
      expect(alice.guestsCount).toBe(1);
      expect(store.meal.extras).toBe(1);
      expect(toastStore.toasts).toHaveLength(0);
    });
  });

  // ── toggleLate ──

  describe("toggleLate", () => {
    it("adds via toggleAttending with late when not attending", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: false, late: false },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleLate();
      expect(alice.attending).toBe(true);
      expect(alice.late).toBe(true);
    });

    it("toggles late when already attending", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: false },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleLate();
      expect(alice.late).toBe(true);
      expect(alice.attending).toBe(true); // stays attending
    });

    it("toggles late off when already late", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: true },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleLate();
      expect(alice.late).toBe(false);
    });

    it("makes patch API call when toggling late on an attending resident", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: false },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleLate();

      expect(axios).toHaveBeenCalledWith(
        expect.objectContaining({
          method: "patch",
          data: expect.objectContaining({ late: true }),
        }),
      );
    });
  });

  // ── toggleVeg ──

  describe("toggleVeg", () => {
    it("adds via toggleAttending with veg when not attending", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            vegetarian: false,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleVeg();
      expect(alice.attending).toBe(true);
      expect(alice.vegetarian).toBe(true);
    });

    it("toggles vegetarian when already attending", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: false,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleVeg();
      expect(alice.vegetarian).toBe(true);
      expect(alice.attending).toBe(true); // stays attending
    });

    it("toggles vegetarian off when already vegetarian", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: true,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleVeg();
      expect(alice.vegetarian).toBe(false);
    });

    it("makes patch API call when toggling veg on an attending resident", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: false,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleVeg();

      expect(axios).toHaveBeenCalledWith(
        expect.objectContaining({
          method: "patch",
          data: expect.objectContaining({ vegetarian: true }),
        }),
      );
    });
  });

  // ── Hardening: canRemove / canRemoveGuest boundary conditions ──

  describe("canRemove boundary: attending_at exactly equals closed_at", () => {
    it("returns false (not strictly after close)", () => {
      const sameTime = new Date(2023, 0, 1, 12, 0, 0);
      const store = createStore({
        mealProps: { closed: true, closed_at: sameTime.getTime() },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: sameTime.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      // attending_at === closed_at, not >, so scenario 3 doesn't match
      expect(alice.canRemove).toBe(false);
    });
  });

  describe("canRemoveGuest boundary: mixed pre- and post-close guests", () => {
    it("returns true when at least one guest was added after close", () => {
      const closedTime = new Date(2023, 0, 1, 12, 0, 0);
      const beforeClose = new Date(2023, 0, 1, 11, 0, 0);
      const afterClose = new Date(2023, 0, 1, 13, 0, 0);

      const store = createStore({
        mealProps: { closed: true, closed_at: closedTime.getTime() },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: beforeClose.getTime(),
          },
          {
            id: 101,
            meal_id: 1,
            resident_id: 10,
            created_at: afterClose.getTime(),
          },
        ],
      });

      const alice = store.residents.get("10");
      // Scenario 3: at least one guest after close
      expect(alice.canRemoveGuest).toBe(true);
    });
  });

  describe("canRemove with null timestamps", () => {
    it("returns false when attending_at is null and meal is closed", () => {
      const closedTime = new Date(2023, 0, 1, 12, 0, 0);
      const store = createStore({
        mealProps: { closed: true, closed_at: closedTime.getTime(), extras: 5 },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: null,
          },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemove).toBe(false);
    });

    it("returns false when closed_at is null and meal is closed (BUG-1 regression guard)", () => {
      const store = createStore({
        mealProps: { closed: true, closed_at: null, extras: 5 },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: Date.now(),
          },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemove).toBe(false);
    });
  });

  describe("canRemoveGuest with null closed_at", () => {
    it("returns false when closed_at is null and meal is closed", () => {
      const store = createStore({
        mealProps: { closed: true, closed_at: null },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
        ],
      });

      const alice = store.residents.get("10");
      expect(alice.canRemoveGuest).toBe(false);
    });
  });

  // ── Dead-node repair (issue #34) ──
  //
  // A raced refetch can destroy a resident node while its mutation request
  // is in flight. The server still saved the change. Every success callback
  // must then refetch through the root store instead of returning silently.

  describe("dead-node repair on mutation success", () => {
    const flush = () => new Promise((r) => setTimeout(r, 0));

    function killAlice(store) {
      removeResident(store, 10);
    }

    it("refetches when the node dies while an attendance add is in flight", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      killAlice(store); // the raced refetch lands before the 200

      await flush();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expectNoDeadNodeUse();
    });

    it("refetches when the node dies while an attendance remove is in flight", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      killAlice(store);

      await flush();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expectNoDeadNodeUse();
    });

    it("refetches when the node dies while a late update is in flight", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: false },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleLate();
      killAlice(store);

      await flush();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expectNoDeadNodeUse();
    });

    it("refetches when the node dies while a veg update is in flight", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: false,
          },
        ],
      });

      const alice = store.residents.get("10");
      alice.toggleVeg();
      killAlice(store);

      await flush();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expectNoDeadNodeUse();
    });

    it("refetches when the node dies while an add-guest is in flight", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      axios.mockResolvedValueOnce(guestAnswer());
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      const alice = store.residents.get("10");
      alice.addGuest({ vegetarian: false });
      killAlice(store);

      await flush();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      // The dropped guest must not be appended by hand — the refetch
      // brings it back. (Without the return after the refetch, the
      // callback goes on and throws: a dead node's root is the node
      // itself, which has no appendGuest. The catch then returns because
      // the node is dead, so nothing is written and no warning shows.)
      expect(store.guests.size).toBe(0);
      expectNoDeadNodeUse();
    });

    it("refetches when the node dies while a remove-guest is in flight", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
        ],
      });

      const alice = store.residents.get("10");
      alice.removeGuest();
      killAlice(store);

      await flush();
      expect(loadDataAsyncSpy).toHaveBeenCalledTimes(1);
      expectNoDeadNodeUse();
    });

    it("does not refetch when the node stays alive", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();

      await flush();
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expect(alice.attending).toBe(true);
      expectNoDeadNodeUse();
    });

    it("does not refetch when a request fails on a dead node", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      // On failure the server saved nothing; the raced snapshot already
      // matches the server, so a repair fetch is not needed.
      axios.mockRejectedValueOnce({ response: { status: 500 } });

      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      killAlice(store);

      await flush();
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expectNoDeadNodeUse();
    });
  });

  // The client that knows, invalidates (issue #37): mutations send
  // socketId, so the sender gets no Pusher echo, and nothing else updates
  // the cached meal payload. Every successful mutation must evict it.
  describe("meal cache eviction on mutation success (issue #37)", () => {
    const flush = () => new Promise((r) => setTimeout(r, 0));

    function aliceStore(residentProps = {}, opts = {}) {
      return createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", ...residentProps }],
        ...opts,
      });
    }

    it("evicts when adding attendance succeeds", async () => {
      const store = aliceStore({ attending: false });
      store.residents.get("10").toggleAttending();

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
    });

    it("evicts when removing attendance succeeds", async () => {
      const store = aliceStore({ attending: true });
      store.residents.get("10").toggleAttending();

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
    });

    it("evicts when a late update succeeds", async () => {
      const store = aliceStore({ attending: true, late: false });
      store.residents.get("10").toggleLate();

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
    });

    it("evicts when a veg update succeeds", async () => {
      const store = aliceStore({ attending: true, vegetarian: false });
      store.residents.get("10").toggleVeg();

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
    });

    it("evicts when adding a guest succeeds", async () => {
      axios.mockResolvedValueOnce(guestAnswer());
      const store = aliceStore({ attending: true });
      store.residents.get("10").addGuest({ vegetarian: false });

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
      expect(store.guests.has("555")).toBe(true);
    });

    it("evicts when removing a guest succeeds", async () => {
      const store = aliceStore(
        { attending: true },
        {
          guests: [
            { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
          ],
        },
      );
      store.residents.get("10").removeGuest();

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
    });

    it("evicts even when the node died before the response landed", async () => {
      const store = aliceStore({ attending: false });
      store.residents.get("10").toggleAttending();
      removeResident(store, 10);

      await flush();
      expect(idbKeyval.del).toHaveBeenCalledWith("1");
    });

    it("does not evict when the request fails", async () => {
      // The server saved nothing, so the cached payload still matches it.
      axios.mockRejectedValueOnce({
        response: { status: 500, data: { message: "Server error." } },
      });

      const store = aliceStore({ attending: false });
      store.residents.get("10").toggleAttending();

      await flush();
      expect(idbKeyval.del).not.toHaveBeenCalled();
    });
  });

  // ── the server refuses ──

  describe("when the server refuses", () => {
    const refusal = {
      response: { data: { message: "Meal has no open spots." } },
    };

    async function settle() {
      await new Promise((r) => setTimeout(r, 0));
    }

    // A seat count exists only on a closed meal (an open meal has
    // extras null), so the seat tests use one. Alice's rows below were
    // made after it closed, so she may back out.
    const CLOSED_AT = new Date(2023, 0, 1, 12, 0, 0).getTime();
    const AFTER_CLOSE = new Date(2023, 0, 1, 13, 0, 0).getTime();
    const closedWithSeats = {
      closed: true,
      closed_at: CLOSED_AT,
      extras: 3,
    };

    it("rolls back an add, with the late and veg flags it set", async () => {
      const store = createStore({
        mealProps: closedWithSeats,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            late: false,
            vegetarian: false,
          },
        ],
      });
      axios.mockRejectedValueOnce(refusal);

      const alice = store.residents.get("10");
      alice.toggleAttending({ late: true, toggleVeg: true });
      expect(alice.attending).toBe(true);
      await settle();

      expect(alice.attending).toBe(false);
      expect(alice.late).toBe(false);
      expect(alice.vegetarian).toBe(false);
      expect(alice.attending_at).toBeNull();
      expect(store.meal.extras).toBe(3);
    });

    // A resident who is not attending shows their profile's veg value
    // (MealFormSerializer), so the veg switch can start on. A refused
    // add must put back that value, not always false (issue #109).
    // Here someone else took the last seat first.
    function vegetarianNotAttending() {
      return createStore({
        mealProps: { closed: true, closed_at: Date.now(), extras: 1 },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            late: false,
            vegetarian: true,
          },
        ],
      });
    }

    it("rolls back an add made from the veg switch to the veg value from before the tap", async () => {
      const store = vegetarianNotAttending();
      axios.mockRejectedValueOnce(refusal);

      const alice = store.residents.get("10");
      alice.toggleVeg();
      expect(alice.attending).toBe(true);
      expect(alice.vegetarian).toBe(false);
      await settle();

      expect(alice.attending).toBe(false);
      expect(alice.vegetarian).toBe(true);
      expect(store.meal.extras).toBe(1);
    });

    it("leaves the profile's veg value alone when an add made from the name is refused", async () => {
      const store = vegetarianNotAttending();
      axios.mockRejectedValueOnce(refusal);

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.vegetarian).toBe(true);
      await settle();

      expect(alice.attending).toBe(false);
      expect(alice.vegetarian).toBe(true);
    });

    it("rolls back a removal and gives the late flag back", async () => {
      const store = createStore({
        mealProps: closedWithSeats,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: AFTER_CLOSE,
            late: true,
          },
        ],
      });
      axios.mockRejectedValueOnce(refusal);

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(alice.attending).toBe(false);
      expect(store.meal.extras).toBe(4);
      await settle();

      expect(alice.attending).toBe(true);
      expect(alice.late).toBe(true);
      expect(store.meal.extras).toBe(3);
    });

    it("rolls back a late toggle", async () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: false },
        ],
      });
      axios.mockRejectedValueOnce(refusal);

      const alice = store.residents.get("10");
      alice.toggleLate();
      expect(alice.late).toBe(true);
      await settle();

      expect(alice.late).toBe(false);
    });

    it("rolls back a veg toggle", async () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: false,
          },
        ],
      });
      axios.mockRejectedValueOnce(refusal);

      const alice = store.residents.get("10");
      alice.toggleVeg();
      expect(alice.vegetarian).toBe(true);
      await settle();

      expect(alice.vegetarian).toBe(false);
    });

    it("gives the seat back when a guest cannot be added", async () => {
      const store = createStore({
        mealProps: closedWithSeats,
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });
      axios.mockRejectedValueOnce(refusal);

      store.residents.get("10").addGuest();
      expect(store.meal.extras).toBe(2);
      await settle();

      expect(store.meal.extras).toBe(3);
    });

    it("does nothing more when the node died before the refusal arrived", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: closedWithSeats,
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });
      let reject;
      axios.mockImplementationOnce(
        () =>
          new Promise((_, rej) => {
            reject = rej;
          }),
      );

      store.residents.get("10").toggleAttending();
      removeResident(store, 10);
      reject(refusal);
      await settle();

      expect(store.residents.has("10")).toBe(false);
      expect(store.meal.extras).toBe(2);
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expectNoDeadNodeUse();
    });

    // The same rule for every write: a node that died while the
    // request was out cannot be rolled back, so the refusal must not
    // touch it.
    function refuseLater() {
      let reject;
      axios.mockImplementationOnce(
        () =>
          new Promise((_, rej) => {
            reject = rej;
          }),
      );
      return () => reject(refusal);
    }

    it("does nothing more when the node died before a removal was refused", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });
      const refuse = refuseLater();

      store.residents.get("10").toggleAttending();
      removeResident(store, 10);
      refuse();
      await settle();

      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expectNoDeadNodeUse();
    });

    it("does nothing more when the node died before a late toggle was refused", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: false },
        ],
      });
      const refuse = refuseLater();

      store.residents.get("10").toggleLate();
      removeResident(store, 10);
      refuse();
      await settle();

      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expectNoDeadNodeUse();
    });

    it("does nothing more when the node died before a veg toggle was refused", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: false,
          },
        ],
      });
      const refuse = refuseLater();

      store.residents.get("10").toggleVeg();
      removeResident(store, 10);
      refuse();
      await settle();

      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expectNoDeadNodeUse();
    });

    it("does nothing more when the node died before a guest add was refused", async () => {
      const expectNoDeadNodeUse = watchDeadNodeUse();
      const store = createStore({
        mealProps: closedWithSeats,
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });
      const refuse = refuseLater();

      store.residents.get("10").addGuest();
      removeResident(store, 10);
      refuse();
      await settle();

      expect(store.meal.extras).toBe(2);
      expect(loadDataAsyncSpy).not.toHaveBeenCalled();
      expectNoDeadNodeUse();
    });
  });

  // ── removeGuest ──

  describe("removeGuest", () => {
    // The newest guest (102) is neither first nor last in the list, nor
    // the lowest or highest id, so only a sort by created_at finds it.
    function storeWithGuests() {
      return createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          {
            id: 101,
            meal_id: 1,
            resident_id: 10,
            created_at: new Date(2026, 3, 1),
          },
          {
            id: 102,
            meal_id: 1,
            resident_id: 10,
            created_at: new Date(2026, 3, 3),
          },
          {
            id: 103,
            meal_id: 1,
            resident_id: 10,
            created_at: new Date(2026, 3, 2),
          },
        ],
      });
    }

    it("removes the newest guest first, whatever order they were listed in", () => {
      const store = storeWithGuests();

      store.residents.get("10").removeGuest();

      expect(axios).toHaveBeenCalledWith({
        method: "delete",
        url: "/api/v1/meals/1/residents/10/guests/102",
        withCredentials: true,
        data: { socket_id: "test" },
      });
    });

    // On a closed meal only a guest added after the close can go, and
    // its seat comes back once the server says yes.
    it("removes a guest added after the close and gives the seat back", async () => {
      const closedAt = new Date(2023, 0, 1, 12, 0, 0);
      const store = createStore({
        mealProps: { closed: true, closed_at: closedAt.getTime(), extras: 1 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: new Date(2023, 0, 1, 13, 0, 0),
          },
        ],
      });

      store.residents.get("10").removeGuest();
      expect(store.meal.extras).toBe(1);
      await new Promise((r) => setTimeout(r, 0));

      expect(store.guests.has("100")).toBe(false);
      expect(store.meal.extras).toBe(2);
    });

    it("answers false with no guest to remove", () => {
      const store = createStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      expect(store.residents.get("10").removeGuest()).toBe(false);
      expect(axios).not.toHaveBeenCalled();
    });

    it("keeps the guest when the server refuses", async () => {
      const store = storeWithGuests();
      axios.mockRejectedValueOnce({
        response: { data: { message: "Meal has been closed." } },
      });

      store.residents.get("10").removeGuest();
      await new Promise((r) => setTimeout(r, 0));

      expect(store.guests.has("102")).toBe(true);
    });
  });
});
