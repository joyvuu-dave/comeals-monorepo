import { describe, it, expect, beforeEach, vi } from "vitest";

// Mock external modules before importing stores
vi.mock("axios", () => ({
  default: vi.fn(() => Promise.resolve({ status: 200 })),
}));

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn(() => "test-token"),
    remove: vi.fn(),
  },
}));

vi.mock("pusher-js", () => {
  return {
    default: vi.fn().mockImplementation(() => ({
      connection: {
        bind: vi.fn(),
        socket_id: "test-socket",
      },
      subscribe: vi.fn(() => ({ bind: vi.fn(), name: "test-channel" })),
      unsubscribe: vi.fn(),
    })),
  };
});

vi.mock("localforage", () => ({
  default: {
    getItem: vi.fn(() => Promise.resolve(null)),
    setItem: vi.fn(() => Promise.resolve()),
  },
}));

import { types } from "mobx-state-tree";
import axios from "axios";
import Meal from "../../../app/frontend/src/stores/meal.js";
import ResidentStore from "../../../app/frontend/src/stores/resident_store.js";
import BillStore from "../../../app/frontend/src/stores/bill_store.js";
import GuestStore from "../../../app/frontend/src/stores/guest_store.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// Meal.settleExtras calls self.form.loadDataAsync(); this spy records it.
const loadDataAsyncMock = vi.fn();

// Build a minimal DataStore-like parent so Meal.form (getParent(self, 2)) resolves.
// The real DataStore uses afterCreate to set up Pusher, so we create a slimmed-down
// wrapper that has the same shape the Meal model expects.
const TestDataStore = types
  .model("TestDataStore", {
    meals: types.optional(types.array(Meal), []),
    meal: types.maybeNull(types.reference(Meal)),
    residentStore: types.optional(ResidentStore, { residents: {} }),
    billStore: types.optional(BillStore, { bills: {} }),
    guestStore: types.optional(GuestStore, { guests: {} }),
  })
  .views((self) => ({
    get attendeesCount() {
      const residentsAttending = Array.from(
        self.residentStore.residents.values(),
      ).filter((r) => r.attending).length;
      return self.guestStore.guests.size + residentsAttending;
    },
  }))
  .actions((self) => ({
    addResident(r) {
      self.residentStore.residents.put(r);
    },
    addGuest(g) {
      self.guestStore.guests.put(g);
    },
    loadDataAsync() {
      loadDataAsyncMock();
    },
  }));

function createStore(mealProps = {}, residents = [], guests = []) {
  const mealDefaults = { id: 1, ...mealProps };
  const store = TestDataStore.create({
    meals: [mealDefaults],
    meal: mealDefaults.id,
    residentStore: { residents: {} },
    guestStore: { guests: {} },
  });

  residents.forEach((r) => store.addResident(r));
  guests.forEach((g) => store.addGuest(g));

  return store;
}

describe("Meal model", () => {
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

  // ── max computed view ──

  describe("max", () => {
    it("returns null when extras is null", () => {
      const store = createStore({ extras: null });
      expect(store.meal.max).toBeNull();
    });

    it("returns extras + attendeesCount when extras is a number", () => {
      const store = createStore({ extras: 5 }, [
        { id: 10, meal_id: 1, name: "Alice", attending: true },
        { id: 11, meal_id: 1, name: "Bob", attending: false },
      ]);
      // attendeesCount = 1 resident attending + 0 guests = 1
      expect(store.meal.max).toBe(6);
    });

    it("returns extras + attendeesCount including guests", () => {
      const store = createStore(
        { extras: 3 },
        [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        [{ id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() }],
      );
      // attendeesCount = 1 resident + 1 guest = 2
      expect(store.meal.max).toBe(5);
    });

    it("returns 0 when extras is 0 and no attendees", () => {
      const store = createStore({ extras: 0 });
      expect(store.meal.max).toBe(0);
    });
  });

  // ── setExtras ──

  describe("setExtras", () => {
    it("sets extras to null when passed null", () => {
      const store = createStore({ extras: 5 });
      store.meal.setExtras(null);
      expect(store.meal.extras).toBeNull();
    });

    it("sets extras to a positive integer", () => {
      const store = createStore({ extras: null });
      store.meal.setExtras(10);
      expect(store.meal.extras).toBe(10);
    });

    it("sets extras to zero", () => {
      const store = createStore({ extras: 5 });
      store.meal.setExtras(0);
      expect(store.meal.extras).toBe(0);
    });

    it("ignores negative numbers", () => {
      const store = createStore({ extras: 5 });
      store.meal.setExtras(-3);
      // Negative numbers fail the >= 0 check, extras should remain unchanged
      expect(store.meal.extras).toBe(5);
    });

    it("ignores non-numeric values like strings", () => {
      const store = createStore({ extras: 5 });
      store.meal.setExtras("abc");
      // parseInt(Number("abc")) = parseInt(NaN) = NaN, which is not an integer
      expect(store.meal.extras).toBe(5);
    });

    it("handles numeric strings correctly", () => {
      const store = createStore({ extras: null });
      store.meal.setExtras("7");
      expect(store.meal.extras).toBe(7);
    });
  });

  // ── incrementExtras ──

  describe("incrementExtras", () => {
    it("increments extras by 1", () => {
      const store = createStore({ extras: 3 });
      store.meal.incrementExtras();
      expect(store.meal.extras).toBe(4);
    });

    it("does nothing when extras is null", () => {
      const store = createStore({ extras: null });
      store.meal.incrementExtras();
      expect(store.meal.extras).toBeNull();
    });

    it("increments from zero to 1", () => {
      const store = createStore({ extras: 0 });
      store.meal.incrementExtras();
      expect(store.meal.extras).toBe(1);
    });

    it("increments from negative to less negative", () => {
      const store = createStore({ extras: -2 });
      store.meal.incrementExtras();
      expect(store.meal.extras).toBe(-1);
    });
  });

  // ── decrementExtras ──

  describe("decrementExtras", () => {
    it("decrements extras by 1", () => {
      const store = createStore({ extras: 3 });
      store.meal.decrementExtras();
      expect(store.meal.extras).toBe(2);
    });

    it("does nothing when extras is null", () => {
      const store = createStore({ extras: null });
      store.meal.decrementExtras();
      expect(store.meal.extras).toBeNull();
    });

    it("decrements from 1 to 0", () => {
      const store = createStore({ extras: 1 });
      store.meal.decrementExtras();
      expect(store.meal.extras).toBe(0);
    });

    it("decrements from 0 to -1", () => {
      const store = createStore({ extras: 0 });
      store.meal.decrementExtras();
      expect(store.meal.extras).toBe(-1);
    });
  });

  // ── setExtras settle-refetch ──

  describe("setExtras settle-refetch", () => {
    it("refetches after a successful save and clears the pending flag", async () => {
      const store = createStore({ extras: 5 });

      store.meal.setExtras(3);
      expect(store.meal.extras).toBe(3); // optimistic write
      expect(store.meal.extrasPending).toBe(true);

      await new Promise((r) => setTimeout(r, 0));

      expect(store.meal.extrasPending).toBe(false);
      expect(loadDataAsyncMock).toHaveBeenCalledTimes(1);
    });

    it("keeps the optimistic value, shows the error, and refetches after a failed save", async () => {
      const store = createStore({ extras: 5 });
      axios.mockRejectedValueOnce({
        response: {
          data: {
            message: "Meal is open. A cap can only be set on a closed meal.",
          },
        },
      });

      store.meal.setExtras(3);
      expect(store.meal.extras).toBe(3); // optimistic write

      await new Promise((r) => setTimeout(r, 0));

      // No rollback: the refetch writes the server's truth instead.
      expect(store.meal.extras).toBe(3);
      expect(store.meal.extrasPending).toBe(false);
      expect(loadDataAsyncMock).toHaveBeenCalledTimes(1);
      expect(toastStore.toasts.length).toBe(1);
      expect(toastStore.toasts[0].type).toBe("error");
    });

    it("refetches after a failed clear (null) as well", async () => {
      const store = createStore({ extras: 5 });
      axios.mockRejectedValueOnce({
        response: { data: { message: "Nope." } },
      });

      store.meal.setExtras(null);
      expect(store.meal.extras).toBeNull(); // optimistic write

      await new Promise((r) => setTimeout(r, 0));

      expect(store.meal.extras).toBeNull();
      expect(store.meal.extrasPending).toBe(false);
      expect(loadDataAsyncMock).toHaveBeenCalledTimes(1);
      expect(toastStore.toasts.length).toBe(1);
    });

    it("ignores clicks while a save is in flight", async () => {
      const store = createStore({ extras: 5 });

      store.meal.setExtras(3);
      store.meal.setExtras(4); // ignored: request in flight

      expect(store.meal.extras).toBe(3);
      expect(axios).toHaveBeenCalledTimes(1);

      await new Promise((r) => setTimeout(r, 0));
      expect(store.meal.extrasPending).toBe(false);
    });

    it("does not mark pending or refetch for invalid input", async () => {
      const store = createStore({ extras: 5 });

      store.meal.setExtras("abc");

      expect(store.meal.extrasPending).toBe(false);
      expect(axios).not.toHaveBeenCalled();

      await new Promise((r) => setTimeout(r, 0));
      expect(loadDataAsyncMock).not.toHaveBeenCalled();
    });
  });

  // ── setExtras edge cases ──

  describe("setExtras edge cases", () => {
    it("empty string resolves to 0", () => {
      // parseInt(Number(""), 10) = 0; clearing via null requires explicit null argument
      const store = createStore({ extras: 5 });
      store.meal.setExtras("");
      expect(store.meal.extras).toBe(0);
    });

    it("truncates float strings to integer", () => {
      // UI sends string values; floats should be handled gracefully
      const store = createStore({ extras: null });
      store.meal.setExtras("3.7");
      expect(store.meal.extras).toBe(3);
    });

    it("handles string with whitespace", () => {
      const store = createStore({ extras: null });
      store.meal.setExtras(" 5 ");
      expect(store.meal.extras).toBe(5);
    });

    it("rejects Infinity", () => {
      const store = createStore({ extras: 5 });
      store.meal.setExtras(Infinity);
      // parseInt(Infinity, 10) = NaN, not an integer
      expect(store.meal.extras).toBe(5);
    });

    it("rejects NaN", () => {
      const store = createStore({ extras: 5 });
      store.meal.setExtras(NaN);
      expect(store.meal.extras).toBe(5);
    });
  });

  // ── decrementExtras boundary ──

  describe("decrementExtras boundary", () => {
    it("can go negative (reflects overcapacity when attendees exceed max)", () => {
      const store = createStore({ extras: 0 });
      store.meal.decrementExtras();
      expect(store.meal.extras).toBe(-1);
      store.meal.decrementExtras();
      expect(store.meal.extras).toBe(-2);
    });
  });
});
