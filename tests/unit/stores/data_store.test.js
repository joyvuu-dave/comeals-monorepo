import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// Mock external modules before importing stores
vi.mock("axios", () => {
  const mockAxios = vi.fn(() => Promise.resolve({ status: 200 }));
  mockAxios.get = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
  mockAxios.interceptors = {
    response: { use: vi.fn(), eject: vi.fn() },
    request: { use: vi.fn() },
  };
  return { default: mockAxios };
});

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => {
      const cookies = {
        token: "test-token",
        community_id: "test-community-id",
        // Fixture community is Pacific. Timezone-sensitive assertions (event
        // date conversion, etc.) read this via getCommunityTimezone() — the
        // helpers themselves work for any IANA tz; see helpers.test.js.
        timezone: "America/Los_Angeles",
      };
      return cookies[name];
    }),
    remove: vi.fn(),
    set: vi.fn(),
  },
}));

vi.mock("pusher-js", () => {
  class MockPusher {
    constructor() {
      this.connection = {
        bind: vi.fn(),
        socket_id: "test-socket",
      };
      this.subscribe = vi.fn(() => ({ bind: vi.fn(), name: "test-channel" }));
      this.unsubscribe = vi.fn();
    }
  }
  return { default: MockPusher };
});

vi.mock("localforage", () => ({
  default: {
    getItem: vi.fn(() => Promise.resolve(null)),
    setItem: vi.fn(() => Promise.resolve()),
    removeItem: vi.fn(() => Promise.resolve()),
  },
}));

vi.mock("uuid", () => {
  let counter = 0;
  return {
    v4: vi.fn(() => "test-uuid-" + ++counter),
  };
});

import { unprotect, isAlive } from "mobx-state-tree";
import { runInAction } from "mobx";
import { DataStore } from "../../../app/frontend/src/stores/data_store.js";
import localforage from "localforage";
import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import {
  communityNow,
  SAVE_DEBOUNCE_MS,
} from "../../../app/frontend/src/helpers/helpers.js";

function createDataStore(opts = {}) {
  const { mealProps = {}, residents = [], guests = [], bills = [] } = opts;

  const mealDefaults = { id: 1, ...mealProps };

  // DataStore.afterCreate sets up Pusher. We need navigator.onLine available.
  const store = DataStore.create({
    meals: [mealDefaults],
    meal: mealDefaults.id,
    residentStore: { residents: {} },
    billStore: { bills: {} },
    guestStore: { guests: {} },
  });

  // Temporarily unprotect the tree so we can populate sub-stores for testing
  unprotect(store);
  runInAction(() => {
    residents.forEach((r) => store.residentStore.residents.put(r));
    guests.forEach((g) => store.guestStore.guests.put(g));
    bills.forEach((b) => store.billStore.bills.put(b));
  });

  return store;
}

describe("DataStore", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Set up window/navigator stubs for afterCreate
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    window.alert = vi.fn();
  });

  // ── attendeesCount ──

  describe("attendeesCount", () => {
    it("counts attending residents plus guests", () => {
      const store = createDataStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true },
          { id: 11, meal_id: 1, name: "Bob", attending: true },
          { id: 12, meal_id: 1, name: "Charlie", attending: false },
        ],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
          { id: 101, meal_id: 1, resident_id: 11, created_at: Date.now() },
        ],
      });

      // 2 attending residents + 2 guests = 4
      expect(store.attendeesCount).toBe(4);
    });

    it("returns 0 when no one is attending and no guests", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });

      expect(store.attendeesCount).toBe(0);
    });

    it("counts only guests when no residents are attending", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
        ],
      });

      expect(store.attendeesCount).toBe(1);
    });

    it("counts only attending residents when no guests", () => {
      const store = createDataStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true },
          { id: 11, meal_id: 1, name: "Bob", attending: true },
        ],
      });

      expect(store.attendeesCount).toBe(2);
    });
  });

  // ── vegetarianCount ──

  describe("vegetarianCount", () => {
    it("counts vegetarian attending residents plus vegetarian guests", () => {
      const store = createDataStore({
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            vegetarian: true,
          },
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: true,
            vegetarian: false,
          },
          {
            id: 12,
            meal_id: 1,
            name: "Charlie",
            attending: false,
            vegetarian: true,
          },
        ],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: Date.now(),
            vegetarian: true,
          },
          {
            id: 101,
            meal_id: 1,
            resident_id: 11,
            created_at: Date.now(),
            vegetarian: false,
          },
        ],
      });

      // Alice is veg + attending, Charlie is veg but NOT attending, guest 100 is veg
      expect(store.vegetarianCount).toBe(2);
    });

    it("returns 0 when no vegetarians", () => {
      const store = createDataStore({
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

      expect(store.vegetarianCount).toBe(0);
    });

    it("does not count non-attending vegetarian residents", () => {
      const store = createDataStore({
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

      expect(store.vegetarianCount).toBe(0);
    });
  });

  // ── lateCount ──

  describe("lateCount", () => {
    it("counts residents who are late", () => {
      const store = createDataStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: true },
          { id: 11, meal_id: 1, name: "Bob", attending: true, late: false },
          {
            id: 12,
            meal_id: 1,
            name: "Charlie",
            attending: true,
            late: true,
          },
        ],
      });

      expect(store.lateCount).toBe(2);
    });

    it("returns 0 when no one is late", () => {
      const store = createDataStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: true, late: false },
        ],
      });

      expect(store.lateCount).toBe(0);
    });

    it("returns 0 when no residents", () => {
      const store = createDataStore();
      expect(store.lateCount).toBe(0);
    });

    it("excludes non-attending residents with late:true", () => {
      // lateCount filters by attending && late, matching the vegetarianCount pattern
      const store = createDataStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice", attending: false, late: true },
          { id: 11, meal_id: 1, name: "Bob", attending: true, late: true },
        ],
      });
      expect(store.lateCount).toBe(1);
    });

    it("matches vegetarianCount pattern for non-attending residents", () => {
      // Both views filter by attending before checking their respective flag
      const store = createDataStore({
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            late: true,
            vegetarian: true,
          },
        ],
      });
      expect(store.vegetarianCount).toBe(0);
      expect(store.lateCount).toBe(0);
    });
  });

  // ── extras ──

  describe("extras", () => {
    it("returns 'n/a' when meal is open", () => {
      const store = createDataStore({
        mealProps: { closed: false, extras: 5 },
      });

      expect(store.extras).toBe("n/a");
    });

    it("returns numeric difference when meal is closed and max is a number", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: 5 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      // max = extras + attendeesCount = 5 + 1 = 6
      // extras view = max - attendeesCount = 6 - 1 = 5
      expect(store.extras).toBe(5);
    });

    it("returns empty string when meal is closed and max is null", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: null },
      });

      expect(store.extras).toBe("");
    });

    it("returns 0 when closed and all spots taken", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: 0 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
        guests: [
          { id: 100, meal_id: 1, resident_id: 10, created_at: Date.now() },
        ],
      });

      // max = 0 + 2 = 2, extras = 2 - 2 = 0
      expect(store.extras).toBe(0);
    });

    it("returns negative when over capacity", () => {
      // This can happen if extras was set before people were added
      const store = createDataStore({
        mealProps: { closed: true, extras: -1 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      // max = -1 + 1 = 0, extras = 0 - 1 = -1
      expect(store.extras).toBe(-1);
    });
  });

  // ── canAdd ──

  describe("canAdd", () => {
    it("returns true when meal is open", () => {
      const store = createDataStore({
        mealProps: { closed: false },
      });

      expect(store.canAdd).toBe(true);
    });

    it("returns false when meal is closed and no max set", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: null },
      });

      // extras view returns "" when closed and max is null
      expect(store.extras).toBe("");
      expect(store.canAdd).toBe(false);
    });

    it("returns true when meal is closed and extras >= 1", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: 3 },
      });

      expect(store.canAdd).toBe(true);
    });

    it("returns false when meal is closed and extras is 0", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: 0 },
      });

      // max = 0 + 0 = 0, extras view = 0 - 0 = 0
      // canAdd: closed=true, extras === 0 (number, not ""), extras < 1
      expect(store.canAdd).toBe(false);
    });

    it("returns false when meal is closed and extras is negative", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: -1 },
      });

      expect(store.canAdd).toBe(false);
    });
  });

  // ── loadData transformation ──

  describe("loadData", () => {
    it("displays wire amounts losslessly (0 becomes blank, others zero-pad to two decimals)", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "Pasta night",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: 2,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [
          { id: "b1", resident_id: 10, amount: "25.5", no_cost: false },
          { id: "b2", resident_id: null, amount: "0", no_cost: false },
        ],
      };

      store.loadData(data);

      const bills = Array.from(store.bills.values());
      // Should have at least 3 bills (2 from data + 1 blank to reach min of 3)
      expect(bills.length).toBeGreaterThanOrEqual(3);

      // Rails drops trailing zeros ("25.5" for $25.50); the display pads
      // them back with string edits — never through a float
      const billWithAmount = bills.find((b) => b.amount === "25.50");
      expect(billWithAmount).toBeTruthy();

      // Bill with amount 0 should have empty string
      const billWithZero = bills.find(
        (b) => b.amount === "" && b.resident === null,
      );
      expect(billWithZero).toBeTruthy();
    });

    it("sorts residents alphabetically by name", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 12,
            meal_id: 1,
            name: "Charlie",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [],
      };

      store.loadData(data);

      // Residents should be sorted: Alice, Bob, Charlie
      const names = Array.from(store.residents.values()).map((r) => r.name);
      expect(names).toEqual(["Alice", "Bob", "Charlie"]);
    });

    it("creates blank bills to reach minimum of 3", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [{ id: "b1", resident_id: null, amount: "10", no_cost: false }],
      };

      store.loadData(data);

      // 1 bill from data + 2 blanks = 3
      expect(store.bills.size).toBe(3);
    });

    it("does not create blank bills when 3 or more exist", () => {
      const store = createDataStore({
        residents: [
          { id: 10, meal_id: 1, name: "Alice" },
          { id: 11, meal_id: 1, name: "Bob" },
          { id: 12, meal_id: 1, name: "Charlie" },
        ],
      });

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 12,
            meal_id: 1,
            name: "Charlie",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [
          { id: "b1", resident_id: 10, amount: "10", no_cost: false },
          { id: "b2", resident_id: 11, amount: "20", no_cost: false },
          { id: "b3", resident_id: 12, amount: "30", no_cost: false },
          { id: "b4", resident_id: null, amount: "5", no_cost: false },
        ],
      };

      store.loadData(data);

      // 4 bills, no blanks needed
      expect(store.bills.size).toBe(4);
    });

    it("sets meal properties from data", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "Taco Tuesday",
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        reconciled: true,
        max: null,
        next_id: 2,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [],
      };

      store.loadData(data);

      expect(store.meal.description).toBe("Taco Tuesday");
      expect(store.meal.closed).toBe(true);
      expect(store.meal.reconciled).toBe(true);
      expect(store.meal.nextId).toBe(2);
      expect(store.meal.prevId).toBeNull();
    });

    it("sets extras based on max minus attendees when max is provided", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        reconciled: false,
        max: 10,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 12,
            meal_id: 1,
            name: "Charlie",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [
          {
            id: 100,
            meal_id: 1,
            resident_id: 10,
            created_at: "2023-06-15T17:00:00Z",
            vegetarian: false,
          },
        ],
        bills: [],
      };

      store.loadData(data);

      // max=10, attending=2, guests=1 => extras = 10 - 3 = 7
      expect(store.meal.extras).toBe(7);
    });

    it("sets extras to null when max is null", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [],
      };

      store.loadData(data);

      expect(store.meal.extras).toBeNull();
    });

    it("sets mealLoading to false after loading", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [],
      };

      store.loadData(data);
      expect(store.mealLoading).toBe(false);
    });

    it("renames resident_id to resident in bill data", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [{ id: "b1", resident_id: 10, amount: "15", no_cost: false }],
      };

      store.loadData(data);

      const bills = Array.from(store.bills.values());
      const aliceBill = bills.find((b) => b.resident !== null);
      expect(aliceBill).toBeTruthy();
      expect(aliceBill.resident.id).toBe(10);
    });

    it("loads guest data", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [
          {
            id: 200,
            meal_id: 1,
            resident_id: 10,
            created_at: "2023-06-15T17:00:00Z",
            vegetarian: true,
            name: null,
          },
        ],
        bills: [],
      };

      store.loadData(data);

      expect(store.guests.size).toBe(1);
      const guest = store.guests.get("200");
      expect(guest.vegetarian).toBe(true);
      expect(guest.resident_id).toBe(10);
    });
  });

  // ── Dead tree / navigation race conditions ──

  describe("navigation race conditions", () => {
    function makeMealData(id, residentOverrides = {}) {
      return {
        id,
        date: "2023-06-15",
        description: `Meal ${id}`,
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: id + 1,
        prev_id: id - 1,
        residents: [
          {
            id: 10,
            meal_id: id,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
            ...residentOverrides,
          },
        ],
        guests: [],
        bills: [],
      };
    }

    it("loadData kills old resident nodes and creates live replacements", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      // Capture a reference to the old resident node
      const oldResident = store.residents.get("10");
      expect(isAlive(oldResident)).toBe(true);

      // Load new data (simulates navigating to a different meal)
      store.loadData(makeMealData(1, { attending: false }));

      // Old reference is dead
      expect(isAlive(oldResident)).toBe(false);

      // New resident is alive with updated data
      const newResident = store.residents.get("10");
      expect(isAlive(newResident)).toBe(true);
      expect(newResident.attending).toBe(false);
    });

    it("successive loadData calls replace nodes each time", () => {
      const store = createDataStore();

      store.loadData(makeMealData(1, { attending: true }));
      const ref1 = store.residents.get("10");
      expect(isAlive(ref1)).toBe(true);

      store.loadData(makeMealData(1, { attending: false }));
      expect(isAlive(ref1)).toBe(false);

      const ref2 = store.residents.get("10");
      expect(isAlive(ref2)).toBe(true);
      expect(ref2.attending).toBe(false);

      store.loadData(makeMealData(1, { late: true }));
      expect(isAlive(ref2)).toBe(false);

      const ref3 = store.residents.get("10");
      expect(isAlive(ref3)).toBe(true);
      expect(ref3.late).toBe(true);
    });

    it("loadDataAsync skips stale responses from a previous meal", async () => {
      const store = createDataStore({
        mealProps: { id: 1 },
      });

      // Set up a second meal so we can switch to it
      unprotect(store);
      runInAction(() => {
        store.meals.push({ id: 2 });
      });

      // Load initial data for meal 1
      store.loadData(makeMealData(1, { attending: true }));
      expect(store.residents.get("10").attending).toBe(true);

      // Simulate: loadDataAsync fires a request for meal 1
      // but user navigates to meal 2 before response arrives
      const meal1Response = {
        status: 200,
        data: makeMealData(1, { attending: false, late: true }),
      };
      axios.get.mockResolvedValueOnce(meal1Response);
      localforage.setItem.mockResolvedValueOnce();

      // Switch to meal 2 and load its data
      runInAction(() => {
        store.meal = 2;
      });
      store.loadData(makeMealData(2, { attending: false }));
      expect(store.meal.id).toBe(2);
      expect(store.meal.description).toBe("Meal 2");

      // Now trigger loadDataAsync (which will get the stale meal 1 response)
      store.loadDataAsync();

      // Wait for the axios + localforage promise chain to resolve
      await vi.waitFor(() => {
        expect(localforage.setItem).toHaveBeenCalled();
      });

      // Flush microtasks
      await new Promise((r) => setTimeout(r, 0));

      // State should still show meal 2 data — the stale meal 1 response was skipped
      expect(store.meal.id).toBe(2);
      expect(store.meal.description).toBe("Meal 2");
    });

    it("loadMonth does not clobber meal Pusher subscription", async () => {
      const store = createDataStore({ mealProps: { id: 1 } });

      // Override subscribe to return identifiable channel objects
      window.Comeals.pusher.subscribe = vi.fn((name) => ({
        bind: vi.fn(),
        name: name,
      }));
      window.Comeals.pusher.unsubscribe = vi.fn();

      const mealData = {
        id: 1,
        date: "2023-06-15",
        description: "Meal",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [],
      };
      store.loadData(mealData);
      expect(window.Comeals.mealChannel.name).toBe("meal-1");

      const calendarData = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      };
      store.loadMonth(calendarData);

      // After loading calendar data, meal subscription must still be intact
      expect(window.Comeals.mealChannel.name).toBe("meal-1");
      expect(window.Comeals.calendarChannel.name).toMatch(/^community-/);
    });

    it("switchMeals skips localforage callback if user already navigated away", async () => {
      const store = createDataStore({
        mealProps: { id: 1 },
      });

      // Add meals 2 and 3 to the array
      unprotect(store);
      runInAction(() => {
        store.meals.push({ id: 2 });
        store.meals.push({ id: 3 });
      });

      // Load initial data for meal 1
      store.loadData(makeMealData(1));

      // Set up localforage to return cached data for meal 2
      const meal2Data = makeMealData(2, { attending: true });
      localforage.getItem.mockResolvedValueOnce(meal2Data);

      // switchMeals to meal 2 starts the async localforage lookup
      store.switchMeals(2);

      // Before localforage resolves, user navigates to meal 3. switchMeals
      // pruned the pre-pushed stub for meal 3 (issue #38), so recreate it
      // the way switchMeals would.
      runInAction(() => {
        store.meals.push({ id: 3 });
        store.meal = 3;
      });
      store.loadData(makeMealData(3, { late: true }));

      // Now let localforage resolve (for the stale meal 2 request)
      await new Promise((r) => setTimeout(r, 0));

      // State should still show meal 3 data — the stale meal 2 callback was skipped
      expect(store.meal.id).toBe(3);
      expect(store.meal.description).toBe("Meal 3");
      expect(store.residents.get("10").late).toBe(true);
    });

    function makeCalendarData(month, events = [], year = 2023) {
      return {
        id: "test-community-id",
        year,
        month,
        meals: [],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events,
      };
    }

    it("loadMonthAsync drops a stale response from a previous month", async () => {
      const store = createDataStore();

      // July's fetch hangs; August's fetch resolves right away.
      let resolveJuly;
      const julyResponse = {
        status: 200,
        data: makeCalendarData(7, [{ id: 1, title: "July event" }]),
      };
      const augustResponse = {
        status: 200,
        data: makeCalendarData(8, [{ id: 2, title: "August event" }]),
      };
      axios.get
        .mockImplementationOnce(
          () =>
            new Promise((resolve) => {
              resolveJuly = resolve;
            }),
        )
        .mockResolvedValueOnce(augustResponse);

      // Navigate to July: the fetch starts but does not resolve
      unprotect(store);
      runInAction(() => {
        store.currentDate = "2023-07-01";
      });
      store.loadMonthAsync();

      // Navigate to August before July's response arrives
      runInAction(() => {
        store.currentDate = "2023-08-01";
      });
      store.loadMonthAsync();
      await new Promise((r) => setTimeout(r, 0));

      // August rendered
      expect(store.calendarEvents.length).toBe(1);
      expect(store.calendarEvents[0].title).toBe("August event");

      // July's late response lands: dropped entirely — not rendered, not cached
      resolveJuly(julyResponse);
      await new Promise((r) => setTimeout(r, 0));

      expect(store.calendarEvents.length).toBe(1);
      expect(store.calendarEvents[0].title).toBe("August event");
      expect(localforage.setItem).not.toHaveBeenCalledWith(
        expect.anything(),
        julyResponse.data,
      );
    });

    it("switchMonths skips a stale IndexedDB read if user already navigated away", async () => {
      const store = createDataStore();

      // Year 2024 so the module-level monthCache, which survives across
      // tests, holds no keys from the loadMonthAsync test above.
      const julyKey = "community-test-community-id-calendar-2024-7";
      const julyCached = makeCalendarData(
        7,
        [{ id: 1, title: "July event" }],
        2024,
      );
      const augustResponse = {
        status: 200,
        data: makeCalendarData(8, [{ id: 2, title: "August event" }], 2024),
      };

      // The July IndexedDB read hangs until we resolve it by hand.
      // (Adjacent-month prefetch also reads the July key; keep every
      // resolver so we can pick the first — the switchMonths read.)
      const julyReads = [];
      localforage.getItem.mockImplementation((key) => {
        if (key === julyKey) {
          return new Promise((resolve) => {
            julyReads.push(resolve);
          });
        }
        return Promise.resolve(null);
      });
      axios.get.mockImplementation((url) => {
        if (url.includes("/calendar/2024-08-01")) {
          return Promise.resolve(augustResponse);
        }
        if (url.includes("/calendar/2024-07-01")) {
          return Promise.resolve({ status: 200, data: julyCached });
        }
        return Promise.resolve({ status: 200, data: makeCalendarData(1) });
      });

      // Navigate to July: the IndexedDB read starts but does not resolve
      store.switchMonths("2024-07-01");

      // Navigate to August before the July read resolves
      store.switchMonths("2024-08-01");
      await new Promise((r) => setTimeout(r, 0));
      expect(store.calendarEvents[0].title).toBe("August event");

      const fetchCount = axios.get.mock.calls.length;

      // The stale July read resolves: no render, no revalidation fetch
      julyReads[0](julyCached);
      await new Promise((r) => setTimeout(r, 0));

      expect(store.calendarEvents.length).toBe(1);
      expect(store.calendarEvents[0].title).toBe("August event");
      expect(axios.get.mock.calls.length).toBe(fetchCount);

      // But the read did warm the in-memory cache: navigating back to July
      // renders synchronously from monthCache, no IndexedDB wait.
      store.switchMonths("2024-07-01");
      expect(store.calendarEvents[0].title).toBe("July event");
    });
  });

  // ── Route teardown and loading flags (issue #38) ──

  describe("route teardown (issue #38)", () => {
    function mealData(id) {
      return {
        id,
        date: "2023-06-15",
        description: `Meal ${id}`,
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: id + 1,
        prev_id: id - 1,
        residents: [],
        guests: [],
        bills: [],
      };
    }

    function calendarData() {
      return {
        id: "test-community-id",
        year: 2023,
        month: 6,
        meals: [],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      };
    }

    it("a month load cannot end the meal load", () => {
      const store = createDataStore();

      store.goToMeal(1);
      expect(store.mealLoading).toBe(true);

      // A stray calendar event lands mid-meal-load. With the old shared
      // flag this woke the prev/next arrows while nextId/prevId were
      // still null — one click away from /meals/null/edit.
      store.loadMonth(calendarData());
      expect(store.monthLoading).toBe(false);
      expect(store.mealLoading).toBe(true);

      store.loadData(mealData(1));
      expect(store.mealLoading).toBe(false);
    });

    it("teardownMealPage unsubscribes the meal channel, nulls the meal, and prunes the nodes", () => {
      const store = createDataStore();
      window.Comeals.pusher.subscribe = vi.fn((name) => ({
        bind: vi.fn(),
        name,
      }));
      window.Comeals.pusher.unsubscribe = vi.fn();

      store.loadData(mealData(1));
      expect(window.Comeals.mealChannel.name).toBe("meal-1");
      const oldNode = store.meals.find((m) => m.id === 1);

      store.teardownMealPage();

      expect(window.Comeals.pusher.unsubscribe).toHaveBeenCalledWith("meal-1");
      expect(window.Comeals.mealChannel).toBeNull();
      expect(store.meal).toBeNull();
      expect(store.meals.length).toBe(0);
      expect(isAlive(oldNode)).toBe(false);
    });

    it("teardownMealPage clears the meal-scoped collections", () => {
      // Rows left behind after the meal is nulled crashed the meal page
      // on re-entry (production, 2026-07-22): the first render showed the
      // stale rows before goToMeal ran, and a row read
      // store.meal.reconciled on the null meal.
      const store = createDataStore();
      const data = mealData(1);
      data.residents = [
        {
          id: 10,
          meal_id: 1,
          name: "Alice",
          attending: true,
          attending_at: null,
          late: false,
          vegetarian: false,
          can_cook: true,
          active: true,
        },
      ];
      data.guests = [
        {
          id: 100,
          meal_id: 1,
          resident_id: 10,
          created_at: "2023-06-15T10:00:00Z",
        },
      ];
      data.bills = [
        { id: "b1", resident_id: 10, amount: "25.50", no_cost: false },
      ];
      store.loadData(data);

      expect(store.residents.size).toBe(1);
      expect(store.guests.size).toBe(1);
      expect(store.bills.size).toBe(3); // 1 from data + 2 blank rows

      store.teardownMealPage();

      expect(store.meal).toBeNull();
      expect(store.bills.size).toBe(0);
      expect(store.residents.size).toBe(0);
      expect(store.guests.size).toBe(0);
    });

    it("teardownMealPage keeps a node holding unsaved menu text", () => {
      const store = createDataStore();
      const node = store.meals[0];
      runInAction(() => {
        node.descriptionDirty = true;
      });

      store.teardownMealPage();

      expect(store.meal).toBeNull();
      expect(isAlive(node)).toBe(true);
      expect(store.meals.length).toBe(1);
    });

    it("loadDataAsync is a no-op after the meal page is torn down", () => {
      const store = createDataStore();
      store.teardownMealPage();
      axios.get.mockClear();

      expect(() => store.loadDataAsync()).not.toThrow();
      expect(axios.get).not.toHaveBeenCalled();
    });

    it("teardownCalendarPage unsubscribes the calendar and adjacent-month channels", () => {
      const store = createDataStore();
      window.Comeals.pusher.subscribe = vi.fn((name) => ({
        bind: vi.fn(),
        name,
      }));
      window.Comeals.pusher.unsubscribe = vi.fn();

      store.loadMonth(calendarData());
      const subscribed = window.Comeals.pusher.subscribe.mock.calls.map(
        (call) => call[0],
      );
      expect(window.Comeals.calendarChannel).not.toBeNull();
      // One current-month channel plus two adjacent months
      expect(subscribed.length).toBe(3);

      store.teardownCalendarPage();

      subscribed.forEach((name) => {
        expect(window.Comeals.pusher.unsubscribe).toHaveBeenCalledWith(name);
      });
      expect(window.Comeals.calendarChannel).toBeNull();
    });

    it("switchMeals prunes the meal nodes it leaves behind", () => {
      const store = createDataStore();
      store.loadData(mealData(1));
      const oldNode = store.meals.find((m) => m.id === 1);

      store.switchMeals(2);

      expect(store.meal.id).toBe(2);
      expect(store.meals.length).toBe(1);
      expect(isAlive(oldNode)).toBe(false);
    });

    it("switchMeals keeps a left-behind node with unsaved menu text", () => {
      const store = createDataStore();
      const node = store.meals[0];
      runInAction(() => {
        node.descriptionDirty = true;
      });

      store.switchMeals(2);

      expect(store.meal.id).toBe(2);
      expect(isAlive(node)).toBe(true);
      expect(store.meals.map((m) => m.id).sort()).toEqual([1, 2]);
    });
  });

  // ── extras view return types ──

  describe("extras view type consistency", () => {
    it("returns string 'n/a' when meal is open", () => {
      const store = createDataStore({
        mealProps: { closed: false, extras: 5 },
      });
      expect(store.extras).toBe("n/a");
      expect(typeof store.extras).toBe("string");
    });

    it("returns a number when meal is closed with max set", () => {
      const store = createDataStore({ mealProps: { closed: true, extras: 3 } });
      expect(typeof store.extras).toBe("number");
    });

    it("returns empty string when meal is closed with null max", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: null },
      });
      expect(store.extras).toBe("");
      expect(typeof store.extras).toBe("string");
    });
  });

  // ── canAdd boundary conditions ──

  describe("canAdd boundary conditions", () => {
    it("returns true when closed and extras is exactly 1 (boundary)", () => {
      // Boundary: extras=1 is the minimum value that allows adding
      const store = createDataStore({ mealProps: { closed: true, extras: 1 } });
      expect(store.canAdd).toBe(true);
    });

    it("returns false when closed and extras is exactly 0 (boundary)", () => {
      const store = createDataStore({ mealProps: { closed: true, extras: 0 } });
      expect(store.canAdd).toBe(false);
    });

    it("handles the transition from extras=1 to 0 after adding a resident", () => {
      // After someone joins, extras decrements — canAdd should flip from true to false
      const store = createDataStore({
        mealProps: { closed: true, extras: 1 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });
      expect(store.canAdd).toBe(true);

      const alice = store.residentStore.residents.get("10");
      alice.toggleAttending();
      expect(store.meal.extras).toBe(0);
      expect(store.canAdd).toBe(false);
    });
  });

  // ── BUG-1: closed_at null handling ──

  describe("closed_at null handling", () => {
    it("preserves null closed_at instead of creating epoch Date (Regression test for BUG-1)", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: true,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [],
      };

      store.loadData(data);
      expect(store.meal.closed_at).toBeNull();
    });

    it("preserves a valid closed_at Date", () => {
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [],
      };

      store.loadData(data);
      expect(store.meal.closed_at).toBeInstanceOf(Date);
      expect(store.meal.closed_at.getTime()).toBe(
        new Date("2023-06-15T18:00:00Z").getTime(),
      );
    });
  });

  // ── BUG-2: setIsOnline parameter handling ──

  describe("setIsOnline", () => {
    it("uses provided value instead of navigator.onLine (Regression test for BUG-2)", () => {
      // navigator.onLine is true from beforeEach
      const store = createDataStore();
      expect(store.isOnline).toBe(true);

      store.setIsOnline(false);
      expect(store.isOnline).toBe(false);

      store.setIsOnline(true);
      expect(store.isOnline).toBe(true);
    });
  });

  // ── BUG-3: submitBills toast behavior on warning ──

  describe("submitBills warning toast", () => {
    it("shows single info toast instead of warning+success (Regression test for BUG-3)", async () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "bill-1", resident: 10, amount: "25.00" }],
      });

      toastStore.clearAll();

      // Mock axios to reject with a warning response
      axios.mockRejectedValueOnce({
        response: {
          status: 400,
          data: {
            message: "Warning: third cooks should not be added.",
            type: "warning",
          },
        },
      });

      // Mock the loadDataAsync axios.get call with valid meal data
      axios.get.mockResolvedValueOnce({
        status: 200,
        data: {
          id: 1,
          date: "2023-06-15",
          description: "",
          closed: false,
          closed_at: null,
          reconciled: false,
          max: null,
          next_id: null,
          prev_id: null,
          residents: [
            {
              id: 10,
              meal_id: 1,
              name: "Alice",
              attending: false,
              attending_at: null,
              late: false,
              vegetarian: false,
              can_cook: true,
              active: true,
            },
          ],
          guests: [],
          bills: [
            { id: "bill-1", resident_id: 10, amount: "25.00", no_cost: false },
          ],
        },
      });

      store.submitBills();

      // Wait for the catch handler to fire and verify final toast state
      await vi.waitFor(() => {
        expect(toastStore.toasts).toHaveLength(1);
        expect(toastStore.toasts[0].type).toBe("info");
        expect(toastStore.toasts[0].message).toContain("Cooks saved.");
      });
    });
  });

  // ── BUG-4: loadMonth with missing event arrays ──

  describe("loadMonth missing arrays", () => {
    it("handles missing event arrays without crashing (Regression test for BUG-4)", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore();

      const data = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [
          {
            title: "Test",
            start: "2023-06-15T18:00:00",
            end: "2023-06-15T19:00:00",
          },
        ],
        // All other arrays omitted
      };

      expect(() => store.loadMonth(data)).not.toThrow();
      expect(store.calendarEvents.length).toBe(1);
      expect(store.monthLoading).toBe(false);
      spy.mockRestore();
    });

    it("handles all arrays missing", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore();

      const data = { id: 1, year: 2023, month: 6 };

      expect(() => store.loadMonth(data)).not.toThrow();
      expect(store.calendarEvents.length).toBe(0);
      spy.mockRestore();
    });
  });

  // ── BUG-6: dangling bill reference ──

  describe("loadData bill reference integrity", () => {
    it("does not crash when bill references non-existent resident (Regression test for BUG-6)", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore();

      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [
          { id: "b1", resident_id: 10, amount: "15", no_cost: false },
          { id: "b2", resident_id: 999, amount: "20", no_cost: false },
        ],
      };

      // loadData should not throw
      expect(() => store.loadData(data)).not.toThrow();

      // Valid bill with resident 10 should be loadable and accessible
      const bills = Array.from(store.bills.values());
      const validBill = bills.find(
        (b) => b.resident !== null && b.resident.id === 10,
      );
      expect(validBill).toBeTruthy();
      expect(validBill.amount).toBe("15.00");
      spy.mockRestore();
    });
  });

  // ── Hardening: critical path edge cases ──

  describe("loadData edge cases", () => {
    it("handles completely empty data (no residents, guests, or bills)", () => {
      const store = createDataStore();
      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [],
        guests: [],
        bills: [],
      };

      store.loadData(data);
      expect(store.residents.size).toBe(0);
      expect(store.guests.size).toBe(0);
      expect(store.bills.size).toBe(3); // 3 blank bills created
      expect(store.attendeesCount).toBe(0);
      expect(store.meal.extras).toBeNull();
    });

    it("handles max=0 (capacity set to exactly the current attendees)", () => {
      const store = createDataStore();
      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        reconciled: false,
        max: 2,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: true,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [],
      };

      store.loadData(data);
      expect(store.meal.extras).toBe(0); // max=2, attendees=2
      expect(store.canAdd).toBe(false);
    });

    it("handles bill with amount zero correctly (displays as empty string)", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });
      const data = {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [{ id: "b1", resident_id: 10, amount: "0", no_cost: false }],
      };

      store.loadData(data);
      const bill = Array.from(store.bills.values()).find(
        (b) => b.resident !== null,
      );
      expect(bill.amount).toBe("");
    });
  });

  // The close gate is gone: forcing a number before the shopping
  // happened bred fake $1 costs. The close button asks about blank
  // costs (cooksMissingCost below) and closes on a deliberate Yes.
  describe("toggleClosed with blank costs", () => {
    it("closes even when a cook's cost is blank", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "bill-1", resident: 10, amount: "", no_cost: false }],
      });

      toastStore.clearAll();
      store.toggleClosed();

      expect(store.meal.closed).toBe(true);
      expect(toastStore.toasts.length).toBe(0);
    });

    it("closes when cook has no_cost flag set", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "bill-1", resident: 10, amount: "", no_cost: true }],
      });

      store.toggleClosed();

      expect(store.meal.closed).toBe(true);
    });

    it("closes when cook has amount filled in", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [
          { id: "bill-1", resident: 10, amount: "25.00", no_cost: false },
        ],
      });

      store.toggleClosed();

      expect(store.meal.closed).toBe(true);
    });
  });

  // The close button's question works off this list: no names, no
  // question; one name, call them out; more, stay generic.
  describe("cooksMissingCost", () => {
    it("is empty when every assigned cook entered a cost or no_cost", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", can_cook: true },
          { id: 11, meal_id: 1, name: "Bob", can_cook: true },
        ],
        bills: [
          { id: "bill-1", resident: 10, amount: "25.00", no_cost: false },
          { id: "bill-2", resident: 11, amount: "", no_cost: true },
        ],
      });

      expect(store.cooksMissingCost).toEqual([]);
    });

    it("names the one cook whose cost is blank", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", can_cook: true },
          { id: 11, meal_id: 1, name: "Bob", can_cook: true },
        ],
        bills: [
          { id: "bill-1", resident: 10, amount: "25.00", no_cost: false },
          { id: "bill-2", resident: 11, amount: "", no_cost: false },
        ],
      });

      expect(store.cooksMissingCost).toEqual(["Bob"]);
    });

    it("names every cook whose cost is blank", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", can_cook: true },
          { id: 11, meal_id: 1, name: "Bob", can_cook: true },
        ],
        bills: [
          { id: "bill-1", resident: 10, amount: "", no_cost: false },
          { id: "bill-2", resident: 11, amount: "", no_cost: false },
        ],
      });

      expect(store.cooksMissingCost).toEqual(["Alice", "Bob"]);
    });

    it("ignores rows with no cook assigned", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        bills: [{ id: "bill-1", amount: "", no_cost: false }],
      });

      expect(store.cooksMissingCost).toEqual([]);
    });

    it("uses the plain resident name, not the unit-prefixed list name", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "102 - Alice",
            short_name: "Alice",
            can_cook: true,
          },
        ],
        bills: [{ id: "bill-1", resident: 10, amount: "", no_cost: false }],
      });

      expect(store.cooksMissingCost).toEqual(["Alice"]);
    });

    // Issue #29 (Q1): zero means "not filled in yet". A typed "0" and a
    // reloaded "0.00" count as missing, the same as an empty string.
    it('counts a typed "0" and a reloaded "0.00" as missing', () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [
          { id: 10, meal_id: 1, name: "Alice", can_cook: true },
          { id: 11, meal_id: 1, name: "Bob", can_cook: true },
        ],
        bills: [
          { id: "bill-1", resident: 10, amount: "0", no_cost: false },
          { id: "bill-2", resident: 11, amount: "0.00", no_cost: false },
        ],
      });

      expect(store.cooksMissingCost).toEqual(["Alice", "Bob"]);
    });
  });

  // "pending" = the cook had the chance to enter a cost (the meal
  // closed) and hasn't yet. It ends at reconciliation.
  describe("bill costPending", () => {
    function storeWith({ mealProps, amount = "", no_cost = false }) {
      return createDataStore({
        mealProps,
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "bill-1", resident: 10, amount, no_cost }],
      });
    }

    function bill(store) {
      return Array.from(store.bills.values())[0];
    }

    it("is pending when the meal is closed and the cost is blank", () => {
      const store = storeWith({ mealProps: { closed: true } });
      expect(bill(store).costPending).toBe(true);
    });

    it("is not pending while the meal is still open", () => {
      const store = storeWith({ mealProps: { closed: false } });
      expect(bill(store).costPending).toBe(false);
    });

    it("is not pending once the meal is reconciled", () => {
      const store = storeWith({
        mealProps: { closed: true, reconciled: true },
      });
      expect(bill(store).costPending).toBe(false);
    });

    it("is not pending when a cost is entered", () => {
      const store = storeWith({
        mealProps: { closed: true },
        amount: "25.00",
      });
      expect(bill(store).costPending).toBe(false);
    });

    it("is not pending when no_cost is set", () => {
      const store = storeWith({ mealProps: { closed: true }, no_cost: true });
      expect(bill(store).costPending).toBe(false);
    });

    it("is not pending on a blank row with no cook assigned", () => {
      const store = createDataStore({
        mealProps: { closed: true },
        bills: [{ id: "bill-1", amount: "", no_cost: false }],
      });
      expect(bill(store).costPending).toBe(false);
    });

    it('treats a stored "0.00" the same as blank', () => {
      const store = storeWith({ mealProps: { closed: true }, amount: "0.00" });
      expect(bill(store).costPending).toBe(true);
    });
  });

  // ── Issue #29: only touched rows carry values to the server ──

  describe("submitBills only-edited-rows", () => {
    function mealDataWithBills(bills) {
      return {
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 10,
            meal_id: 1,
            name: "Alice",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills,
      };
    }

    function billsPatchCalls() {
      return axios.mock.calls.filter(
        ([config]) =>
          config &&
          config.method === "patch" &&
          config.url === "/api/v1/meals/1/bills",
      );
    }

    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("sends resident_id only for rows the user did not touch", () => {
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(
        mealDataWithBills([
          { id: "b1", resident_id: 10, amount: "12.34", no_cost: false },
          { id: "b2", resident_id: 11, amount: "", no_cost: false },
        ]),
      );

      const bobsBill = Array.from(store.bills.values()).find(
        (b) => b.resident && b.resident.id === 11,
      );
      bobsBill.setAmount("5.00"); // triggers the debounced saveBills
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);

      const calls = billsPatchCalls();
      expect(calls.length).toBe(1);
      const payload = calls[0][0].data;
      expect(payload.bills).toContainEqual({ resident_id: 10 });
      expect(payload.bills).toContainEqual({
        resident_id: 11,
        amount: "5.00",
        no_cost: false,
      });
    });

    it("never sends a stored amount the user did not type back to the server", () => {
      // A legacy sub-cent amount (data older than the whole-cents CHECK)
      // displays exactly as stored and must never leave the client — this
      // is the write-back that used to silently rewrite the ledger.
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(
        mealDataWithBills([
          { id: "b1", resident_id: 10, amount: "12.345", no_cost: false },
          { id: "b2", resident_id: 11, amount: "", no_cost: false },
        ]),
      );

      const alicesBill = Array.from(store.bills.values()).find(
        (b) => b.resident && b.resident.id === 10,
      );
      expect(alicesBill.amount).toBe("12.345"); // exact wire string, no float

      const bobsBill = Array.from(store.bills.values()).find(
        (b) => b.resident && b.resident.id === 11,
      );
      bobsBill.setAmount("5.00");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);

      const payload = billsPatchCalls()[0][0].data;
      expect(payload.bills).toContainEqual({ resident_id: 10 });
      expect(
        payload.bills.find((b) => b.resident_id === 10),
      ).not.toHaveProperty("amount");
    });

    it("blocks the save when a touched row is invalid", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "b1", resident: 10, amount: "", no_cost: false }],
      });

      // setAmount refuses invalid input, so force the state directly to
      // exercise submitBills' second-layer gate (paste paths, refactors).
      const bill = store.bills.get("b1");
      runInAction(() => {
        bill.amount = "1e3";
        bill.touched = true;
      });

      store.submitBills();

      expect(store.editBillsMode).toBe(true);
      expect(billsPatchCalls().length).toBe(0);
    });

    it("does not let an untouched invalid legacy row block the save", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "b1", resident: 10, amount: "12.345", no_cost: false }],
      });

      store.submitBills();

      const calls = billsPatchCalls();
      expect(calls.length).toBe(1);
      expect(calls[0][0].data.bills).toEqual([{ resident_id: 10 }]);
    });
  });

  // ── Issue #30: debounce, single-flight, reconcile with the server ──

  describe("bill save pipeline", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    function storeWithCookBill() {
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData({
        id: 1,
        date: "2023-06-15",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: null,
        prev_id: null,
        residents: [
          {
            id: 11,
            meal_id: 1,
            name: "Bob",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: true,
          },
        ],
        guests: [],
        bills: [{ id: "b1", resident_id: 11, amount: "", no_cost: false }],
      });
      return store;
    }

    function bobsBill(store) {
      return Array.from(store.bills.values()).find(
        (b) => b.resident && b.resident.id === 11,
      );
    }

    function billsPatchCalls(mealId = 1) {
      return axios.mock.calls.filter(
        ([config]) =>
          config &&
          config.method === "patch" &&
          config.url === `/api/v1/meals/${mealId}/bills`,
      );
    }

    it("waits out the debounce after the last edit and sends one request with the final value", () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS - 200);
      bill.setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS - 1);
      expect(billsPatchCalls().length).toBe(0);

      vi.advanceTimersByTime(1);
      const calls = billsPatchCalls();
      expect(calls.length).toBe(1);
      expect(calls[0][0].data.bills).toContainEqual({
        resident_id: 11,
        amount: "50",
        no_cost: false,
      });
    });

    it("keeps one request in flight and resends the latest state when it settles", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      let resolveFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          }),
      );

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      expect(billsPatchCalls().length).toBe(1);

      // Edit while the first request is in flight: no second request yet,
      // so this client's writes can never arrive out of order.
      bill.setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      expect(billsPatchCalls().length).toBe(1);

      // The first request settles; the queued save sends the latest state.
      resolveFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      const calls = billsPatchCalls();
      expect(calls.length).toBe(2);
      expect(calls[1][0].data.bills).toContainEqual({
        resident_id: 11,
        amount: "50",
        no_cost: false,
      });
    });

    it("applies the persisted bills from the ack when the user has not typed since", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      // The server answers with what it stored (here: a different value,
      // as if another client's write won the lock first).
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 11, amount: "12.34", no_cost: false }],
        },
      });

      bill.setAmount("5.50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0);

      expect(bill.amount).toBe("12.34");
      expect(bill.touched).toBe(false);
    });

    // Regression from issue #30's fix. Typing "1", pausing past the
    // debounce, then typing "0" used to fail: the ack rewrote the field
    // to "1.00" under the cursor, so the next keystroke made "1.000" —
    // three decimals, which the whole-cents grammar refuses. The "0" was
    // swallowed. When the server agrees with the screen, the ack must
    // not reformat what the user is still typing.
    it("keeps the typed string when the ack differs only in formatting, so typing can continue", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      // Rails drops trailing zeros: the server stored 1.00, echoes "1.0".
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 11, amount: "1.0", no_cost: false }],
        },
      });

      bill.setAmount("1");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0);

      // Same number: keep the user's string. The row is still in sync
      // with the server, so it needs no resend.
      expect(bill.amount).toBe("1");
      expect(bill.touched).toBe(false);

      // The slow "0" keystroke lands: "1" then "0" makes "10".
      expect(bill.setAmount("10")).toBe("10");
      expect(bill.amount).toBe("10");
    });

    // The counterpart of the ack no-reformat rule: the field pads itself
    // when the user leaves it, so "1" still ends up shown as "1.00".
    it("pads the display on blur without marking the row for a resend", () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("1");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // save fires; row settles
      bill.touched = false;

      bill.normalizeAmountDisplay(); // what the input's onBlur calls
      expect(bill.amount).toBe("1.00");
      expect(bill.touched).toBe(false);

      // A typed zero means "not filled in yet" and shows as blank — the
      // same mapping loadData uses, so blur and reload agree.
      bill.setAmount("0");
      bill.normalizeAmountDisplay();
      expect(bill.amount).toBe("");
    });

    it("ignores the ack when the user typed after the request was sent", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      let resolveFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          }),
      );

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);

      // A newer keystroke while the request is in flight.
      bill.setAmount("50");

      resolveFirst({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 11, amount: "5.0", no_cost: false }],
        },
      });
      await vi.advanceTimersByTimeAsync(0);

      // Applying the ack here would erase the newer keystroke.
      expect(bill.amount).toBe("50");
      expect(bill.touched).toBe(true);

      // The debounced save then sends the newer value.
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      const calls = billsPatchCalls();
      expect(calls.length).toBe(2);
      expect(calls[1][0].data.bills).toContainEqual({
        resident_id: 11,
        amount: "50",
        no_cost: false,
      });
    });

    it("flushes a pending save immediately on demand (blur) and consumes the timer", () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("5");
      store.flushPendingBillsSave(); // what the inputs' onBlur calls

      const calls = billsPatchCalls();
      expect(calls.length).toBe(1);
      expect(calls[0][0].data.bills).toContainEqual({
        resident_id: 11,
        amount: "5",
        no_cost: false,
      });

      // The flush consumed the timer — nothing more fires later.
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      expect(billsPatchCalls().length).toBe(1);
    });

    it("does nothing on flush when no save is pending", () => {
      const store = storeWithCookBill();

      store.flushPendingBillsSave();

      expect(billsPatchCalls().length).toBe(0);
    });

    it("flushes a pending debounced save before switching meals", () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("5");
      // Navigate away before the debounce fires. The save must go to the
      // meal the edit was typed on.
      store.switchMeals(2);

      const calls = billsPatchCalls(1);
      expect(calls.length).toBe(1);
      expect(calls[0][0].data.bills).toContainEqual({
        resident_id: 11,
        amount: "5",
        no_cost: false,
      });

      // The flush consumed the timer — nothing more fires later.
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      expect(billsPatchCalls(1).length).toBe(1);
      expect(billsPatchCalls(2).length).toBe(0);
    });

    // The client that knows, invalidates (issue #37): bill saves send
    // socketId, so the sender gets no Pusher echo and the cached meal
    // payload keeps the old bills until evicted.
    it("evicts the meal's cached payload when the save succeeds", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0);

      expect(localforage.removeItem).toHaveBeenCalledWith("1");
    });

    it("evicts the meal's cached payload when the server saves with a warning", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      // A warning response still persisted the bills (e.g. third cook).
      axios.mockRejectedValueOnce({
        response: { data: { type: "warning", message: "Third cook." } },
      });

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0);

      expect(localforage.removeItem).toHaveBeenCalledWith("1");
    });

    it("does not evict when the save fails outright", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      // The server saved nothing, so the cached payload still matches it.
      axios.mockRejectedValueOnce({
        response: { data: { message: "Server error." } },
      });

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0);

      expect(localforage.removeItem).not.toHaveBeenCalled();
    });

    it("does not resend a queued save after the user switches meals", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      let resolveFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          }),
      );

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // request 1 in flight
      bill.setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // queued behind request 1

      store.switchMeals(2); // leave the meal
      resolveFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      // The queued edit's rows are gone — resending would write another
      // meal's bill rows into meal 2.
      expect(billsPatchCalls(1).length).toBe(1);
      expect(billsPatchCalls(2).length).toBe(0);
    });
  });

  describe("toggleClosed settle-refetch", () => {
    it("refetches on success instead of stamping closed_at from the client clock", async () => {
      const store = createDataStore({
        mealProps: { closed: false, closed_at: null },
      });

      store.toggleClosed();

      expect(store.meal.closed).toBe(true); // optimistic write
      expect(store.closedPending).toBe(true);

      await new Promise((r) => setTimeout(r, 0));

      expect(store.closedPending).toBe(false);
      // closed_at stays null until loadData writes the server's value
      expect(store.meal.closed_at).toBeNull();
      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");
    });

    it("keeps the optimistic value, shows the error, and refetches after a failure", async () => {
      const store = createDataStore({
        mealProps: { closed: false },
      });
      axios.mockRejectedValueOnce({
        response: { data: { message: "Server error." } },
      });

      toastStore.clearAll();
      store.toggleClosed();

      expect(store.meal.closed).toBe(true); // optimistic write

      await new Promise((r) => setTimeout(r, 0));

      // No blind flip back: the refetch writes the server's truth instead.
      expect(store.meal.closed).toBe(true);
      expect(store.closedPending).toBe(false);
      expect(toastStore.toasts.length).toBe(1);
      expect(toastStore.toasts[0].type).toBe("error");
      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");
    });

    it("ignores a second click while the request is in flight", async () => {
      const store = createDataStore({
        mealProps: { closed: false },
      });

      let resolvePatch;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolvePatch = resolve;
          }),
      );

      store.toggleClosed();
      store.toggleClosed(); // ignored: request in flight

      expect(axios).toHaveBeenCalledTimes(1);
      expect(store.meal.closed).toBe(true);

      resolvePatch({ status: 200 });
      await new Promise((r) => setTimeout(r, 0));

      expect(store.closedPending).toBe(false);
    });
  });

  describe("loadMonth edge cases", () => {
    it("handles empty arrays (valid but no events)", () => {
      const store = createDataStore();
      const data = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      };

      store.loadMonth(data);
      expect(store.calendarEvents.length).toBe(0);
      expect(store.monthLoading).toBe(false);
    });

    it("rejects string data (error response from API)", () => {
      const spy = vi.spyOn(console, "error").mockImplementation(() => {});
      const store = createDataStore();
      var result = store.loadMonth("error: unauthorized");
      expect(result).toBe(true);
      expect(store.monthLoading).toBe(false);
      spy.mockRestore();
    });

    it("converts event dates to fake-local Dates in the community timezone", () => {
      const store = createDataStore();
      const data = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [
          {
            title: "Dinner",
            start: "2023-06-15T18:30:00",
            end: "2023-06-15T19:30:00",
          },
        ],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      };

      store.loadMonth(data);
      var event = store.calendarEvents[0];
      expect(event.start).toBeInstanceOf(Date);
      expect(event.end).toBeInstanceOf(Date);
      expect(event.title).toBe("Dinner");
    });

    it("converts offset date strings to correct community-tz dates", () => {
      const store = createDataStore();
      // Fixture community is Pacific (set in top-level beforeEach).
      // 4 PM Pacific (-07:00) to 6 PM Pacific (-07:00) on June 15
      const data = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [
          {
            title: "Reservation",
            start: "2023-06-15T16:00:00.000-07:00",
            end: "2023-06-15T18:00:00.000-07:00",
          },
        ],
        guest_room_reservations: [],
        events: [],
      };

      store.loadMonth(data);
      var event = store.calendarEvents[0];
      expect(event.start.getDate()).toBe(15);
      expect(event.start.getHours()).toBe(16);
      expect(event.end.getDate()).toBe(15);
      expect(event.end.getHours()).toBe(18);
    });

    it("converts UTC (Z) date strings to correct community-tz dates", () => {
      const store = createDataStore();
      // 2023-06-16T01:00:00Z = June 15 6 PM Pacific (PDT)
      // 2023-06-16T03:00:00Z = June 15 8 PM Pacific (PDT)
      const data = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [
          {
            title: "Late Dinner",
            start: "2023-06-16T01:00:00Z",
            end: "2023-06-16T03:00:00Z",
          },
        ],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      };

      store.loadMonth(data);
      var event = store.calendarEvents[0];
      expect(event.start.getDate()).toBe(15);
      expect(event.start.getHours()).toBe(18);
      expect(event.end.getDate()).toBe(15);
      expect(event.end.getHours()).toBe(20);
    });
  });

  // The client that knows, invalidates (issue #37): the reservation and
  // event modals call this for the affected month(s), because months
  // beyond the current one and its neighbors have no Pusher channel to
  // evict their cache.
  describe("invalidateMonthForDate", () => {
    it("evicts the month's cache entry for a picker Date", () => {
      const store = createDataStore();

      store.invalidateMonthForDate(new Date(2026, 8, 15)); // Sep 15, 2026

      expect(localforage.removeItem).toHaveBeenCalledWith(
        "community-test-community-id-calendar-2026-9",
      );
    });

    it("resolves an offset wire string to the community month, not the UTC month", () => {
      const store = createDataStore();

      // 2026-10-01 02:00 UTC is 2026-09-30 19:00 in America/Los_Angeles.
      store.invalidateMonthForDate("2026-10-01T02:00:00.000Z");

      expect(localforage.removeItem).toHaveBeenCalledWith(
        "community-test-community-id-calendar-2026-9",
      );
    });

    it("reads a naive wire string as a community-timezone date", () => {
      const store = createDataStore();

      store.invalidateMonthForDate("2026-10-05");

      expect(localforage.removeItem).toHaveBeenCalledWith(
        "community-test-community-id-calendar-2026-10",
      );
    });

    it("ignores null and unparseable dates", () => {
      const store = createDataStore();

      store.invalidateMonthForDate(null);
      store.invalidateMonthForDate("not-a-date");

      expect(localforage.removeItem).not.toHaveBeenCalled();
    });
  });

  describe("Pusher reconnect recovery", () => {
    // The mock Pusher's connection.bind is a vi.fn(); pull out the
    // state_change handler afterCreate registered so tests can drive
    // connection transitions directly.
    function stateChangeHandler() {
      const call = window.Comeals.pusher.connection.bind.mock.calls.find(
        ([event]) => event === "state_change",
      );
      return call[1];
    }

    afterEach(async () => {
      // Restore the default cookie fixture for tests that override it.
      const Cookie = (await import("js-cookie")).default;
      Cookie.get.mockImplementation(
        (name) =>
          ({
            token: "test-token",
            community_id: "test-community-id",
            timezone: "America/Los_Angeles",
          })[name],
      );
    });

    it("does not refetch on the first connection at page load", () => {
      createDataStore();
      const handler = stateChangeHandler();
      axios.get.mockClear();

      handler({ previous: "connecting", current: "connected" });

      expect(axios.get).not.toHaveBeenCalled();
    });

    // Regression: the handler required previous === "unavailable", but
    // pusher-js only reaches "unavailable" after ~10s. A shorter drop
    // reconnects as connecting → connected, and events broadcast during
    // the gap were silently lost (Pusher does not replay them).
    it("refetches after a short blip that never reached unavailable", () => {
      createDataStore();
      const handler = stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load
      axios.get.mockClear();

      handler({ previous: "connected", current: "connecting" });
      handler({ previous: "connecting", current: "connected" });

      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");
      expect(axios.get).toHaveBeenCalledWith(
        expect.stringContaining("/calendar/"),
      );
    });

    it("still refetches after a long gap through unavailable", () => {
      createDataStore();
      const handler = stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load
      axios.get.mockClear();

      handler({ previous: "unavailable", current: "connected" });

      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");
    });

    // A blip on the login page must not fire an unauthenticated fetch —
    // the 401 would raise the "you've been signed out" banner for a
    // person who is not signed in. Same guard as the `online` handler.
    it("skips the refetch when the community_id cookie is gone", async () => {
      const Cookie = (await import("js-cookie")).default;
      createDataStore();
      const handler = stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load
      Cookie.get.mockImplementation((name) =>
        name === "timezone" ? "America/Los_Angeles" : undefined,
      );
      axios.get.mockClear();

      handler({ previous: "unavailable", current: "connected" });

      expect(axios.get).not.toHaveBeenCalled();
    });
  });

  describe("communityToday", () => {
    function stateChangeHandler() {
      const call = window.Comeals.pusher.connection.bind.mock.calls.find(
        ([event]) => event === "state_change",
      );
      return call[1];
    }

    afterEach(() => {
      vi.useRealTimers();
    });

    it("initializes to today's date in the community timezone", () => {
      const store = createDataStore();
      expect(store.communityToday).toBe(communityNow().format("YYYY-MM-DD"));
    });

    // Regression (#36): "today" was read straight from the clock during
    // render, which is not observable — an idle tab (a wall-mounted
    // tablet) kept showing yesterday's date, highlight, and dimming after
    // midnight. The store now owns "today" and rolls it over on a timer.
    it("rolls over at community midnight and schedules the next rollover", () => {
      vi.useFakeTimers();
      // 23:59 Pacific daylight time — one minute before midnight.
      vi.setSystemTime(new Date("2026-07-08T23:59:00-07:00"));
      const store = createDataStore();
      expect(store.communityToday).toBe("2026-07-08");

      vi.advanceTimersByTime(5 * 60 * 1000);
      expect(store.communityToday).toBe("2026-07-09");

      // The timer reschedules itself, so the following midnight works too.
      vi.advanceTimersByTime(24 * 60 * 60 * 1000);
      expect(store.communityToday).toBe("2026-07-10");
    });

    // DST: the night the clocks fall back is 25 hours long. The timer
    // must target the next community midnight, not "now plus 24 hours" —
    // a naive 24-hour timer would fire an hour early, write the same
    // day, and then land a full day behind at the next midnight.
    // America/Los_Angeles leaves DST on Nov 1, 2026 at 2am.
    it("targets community midnight across the fall-back DST night", () => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2026-10-31T23:59:00-07:00")); // PDT
      const store = createDataStore();
      expect(store.communityToday).toBe("2026-10-31");

      // Midnight itself comes before the 2am transition, so the first
      // rollover is a normal one.
      vi.advanceTimersByTime(5 * 60 * 1000);
      expect(store.communityToday).toBe("2026-11-01");

      // Nov 1 lasts 25 hours: a full 24 hours later it is 11pm PST,
      // still Nov 1.
      vi.advanceTimersByTime(24 * 60 * 60 * 1000);
      expect(store.communityToday).toBe("2026-11-01");

      // The 25th hour crosses the real community midnight. A timer set
      // for "+24 hours" would have fired at 11pm and rescheduled for
      // 11pm the next day, leaving this assertion a day behind.
      vi.advanceTimersByTime(60 * 60 * 1000);
      expect(store.communityToday).toBe("2026-11-02");
    });

    // Background tabs throttle timers, so a laptop asleep past midnight
    // can wake with the rollover timer unfired. The Pusher reconnect is
    // the wake-up signal: it recomputes "today" alongside its refetch.
    it("recomputes on Pusher reconnect when the timer never fired", () => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2026-07-08T23:59:00-07:00"));
      const store = createDataStore();
      const handler = stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load

      // Move the clock past midnight WITHOUT running timers — the
      // throttled-tab case.
      vi.setSystemTime(new Date("2026-07-09T07:30:00-07:00"));
      expect(store.communityToday).toBe("2026-07-08");

      handler({ previous: "connected", current: "connecting" });
      handler({ previous: "connecting", current: "connected" });

      expect(store.communityToday).toBe("2026-07-09");
    });
  });

  describe("logout", () => {
    // Regression: logout() used to rely on the global axios interceptor to
    // attach the bearer token, but cookies were cleared synchronously before
    // the interceptor's microtask ran. The DELETE dispatched with no auth,
    // the server 401'd, and legacy Key rows were never destroyed. The fix
    // reads the cookie synchronously and passes the header explicitly.
    it("sends DELETE /api/v1/sessions/current with an Authorization header before clearing cookies", async () => {
      const Cookie = (await import("js-cookie")).default;
      axios.delete = vi.fn(() => Promise.resolve({ status: 200 }));

      const store = createDataStore();
      store.logout();

      expect(axios.delete).toHaveBeenCalledTimes(1);
      const [url, config] = axios.delete.mock.calls[0];
      expect(url).toBe("/api/v1/sessions/current");
      expect(config).toEqual({
        headers: { Authorization: "Bearer test-token" },
      });
      expect(Cookie.remove).toHaveBeenCalledWith("token", { path: "/" });
    });

    it("skips the server call when no token cookie is present", async () => {
      const Cookie = (await import("js-cookie")).default;
      // Target `token` specifically — createDataStore also reads `timezone`
      // now (via getCommunityTimezone), so a blanket `mockImplementationOnce`
      // would consume against the wrong key.
      Cookie.get.mockImplementation((name) =>
        name === "token"
          ? undefined
          : name === "community_id"
            ? "test-community-id"
            : name === "timezone"
              ? "America/Los_Angeles"
              : undefined,
      );
      axios.delete = vi.fn(() => Promise.resolve({ status: 200 }));

      const store = createDataStore();
      store.logout();

      expect(axios.delete).not.toHaveBeenCalled();
      expect(Cookie.remove).toHaveBeenCalledWith("token", { path: "/" });
    });
  });

  // ── description dirty state (issue #35) ──

  describe("description dirty state", () => {
    function mealPayload(overrides = {}) {
      return Object.assign(
        {
          id: 1,
          date: "2023-06-15",
          description: "server text",
          closed: false,
          closed_at: null,
          reconciled: false,
          max: null,
          next_id: null,
          prev_id: null,
          residents: [],
          guests: [],
          bills: [],
        },
        overrides,
      );
    }

    it("loadData leaves the description alone while it has unsaved typing", async () => {
      const store = createDataStore();
      axios.mockRejectedValueOnce({ request: {} });

      store.setDescription("typed text");
      await new Promise((r) => setTimeout(r, 0));
      expect(store.meal.descriptionDirty).toBe(true);

      store.loadData(mealPayload());

      expect(store.meal.description).toBe("typed text");
    });

    it("loadData writes the description again once the text is saved", async () => {
      const store = createDataStore();

      store.setDescription("typed text");
      await new Promise((r) => setTimeout(r, 0));
      expect(store.meal.descriptionDirty).toBe(false);

      store.loadData(mealPayload());

      expect(store.meal.description).toBe("server text");
    });

    it("retryDirtyDescriptions resends a dirty meal, even one no longer on screen", async () => {
      const store = createDataStore();
      axios.mockRejectedValueOnce({ request: {} });

      store.setDescription("typed text");
      await new Promise((r) => setTimeout(r, 0));

      // The user moved on to another meal; the unsaved text stays behind
      // on meal 1's node.
      runInAction(() => {
        store.addMeal({ id: 2 });
        store.meal = 2;
      });

      axios.mockClear();
      store.retryDirtyDescriptions();

      expect(axios).toHaveBeenCalledTimes(1);
      expect(axios.mock.calls[0][0].url).toBe("/api/v1/meals/1/description");
      expect(axios.mock.calls[0][0].data.description).toBe("typed text");

      await new Promise((r) => setTimeout(r, 0));
      const mealOne = store.meals.find((m) => m.id === 1);
      expect(mealOne.descriptionDirty).toBe(false);
    });

    it("retryDirtyDescriptions sends nothing when no text is unsaved", () => {
      const store = createDataStore();

      store.retryDirtyDescriptions();

      expect(axios).not.toHaveBeenCalled();
    });
  });
});
