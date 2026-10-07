import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// Mock external modules before importing stores
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import { isAlive } from "mobx-state-tree";
import { createDataStore, stage } from "../helpers/create_data_store.js";

// The full wire shape /meals/:id/cooks returns, every field at its
// blank default. Tests override only what they exercise, so a wire
// format change is one edit here instead of two dozen literals. The
// server never sends a null next_id or prev_id: the first and the last
// meal point at themselves (MealFormSerializer).
function mealPayload(overrides = {}) {
  const id = overrides.id ?? 1;
  return {
    id,
    date: "2023-06-15",
    description: "",
    closed: false,
    closed_at: null,
    reconciled: false,
    max: null,
    next_id: id,
    prev_id: id,
    residents: [],
    guests: [],
    bills: [],
    ...overrides,
  };
}

// One resident row as /meals/:id/cooks sends it.
function residentRow(id, name, overrides = {}) {
  return {
    id,
    meal_id: 1,
    name,
    short_name: name,
    attending: false,
    attending_at: null,
    late: false,
    vegetarian: false,
    can_cook: true,
    active: true,
    ...overrides,
  };
}

// The bill rows the store shows, by who cooks. A padding row has no cook.
function billFor(store, residentId) {
  return Array.from(store.bills.values()).find(
    (b) => b.resident !== null && b.resident.id === residentId,
  );
}
function blankRows(store) {
  return Array.from(store.bills.values()).filter((b) => b.resident === null);
}

import { prefetchMonth } from "../../../app/frontend/src/stores/month_fetch.js";
import * as monthCache from "../../../app/frontend/src/stores/month_cache.js";
import { pusherClient } from "../../../app/frontend/src/helpers/pusher_client.js";
import * as idbKeyval from "idb-keyval";
import axios from "axios";
import Cookie from "js-cookie";
import { cookies } from "../mocks/js_cookie.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { SAVE_DEBOUNCE_MS } from "../../../app/frontend/src/helpers/helpers.js";
// The server's real answer for GET /meals/42/cooks, written by
// rake test:generate_fixtures from MealFormSerializer.
import mealFixture from "../../fixtures/meal.json";

// Replace the Pusher client's subscribe and unsubscribe for one test, so
// it can see the channel names. pusherClient is module state that lives
// for the whole file, so these are spies the top-level afterEach puts
// back, not plain assignments that would stay for every later test.
function stubPusherChannels() {
  vi.spyOn(pusherClient, "subscribe").mockImplementation((name) => ({
    bind: vi.fn(),
    name,
  }));
  vi.spyOn(pusherClient, "unsubscribe").mockImplementation(() => {});
}

describe("DataStore", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // startPusher refuses to connect without a key (the staging build
    // relies on that), so the Pusher tests need one. Locally the repo's
    // untracked .env provides it; CI has no .env, so without this stub
    // the mock Pusher never connects there and every test that reaches
    // into the mock instance fails.
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    vi.stubEnv("VITE_PUSHER_CLUSTER", "us2");
    // Set up window/navigator stubs for afterCreate
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    window.alert = vi.fn();
    // The month cache is module state: without this, a month one test
    // loaded would still be cached for the next one.
    monthCache.clear();
  });

  // A test that replaces a shared mock's behavior (mockImplementation,
  // mockRejectedValue, a Once that was never used) must not hand it to
  // the tests after it. clearAllMocks above wipes only recorded calls;
  // mockReset also puts back the default each mock file defines.
  afterEach(() => {
    [axios, axios.get, axios.delete, idbKeyval.get, idbKeyval.set].forEach(
      (mock) => mock.mockReset(),
    );
    [pusherClient.subscribe, pusherClient.unsubscribe].forEach((fn) => {
      if (vi.isMockFunction(fn)) fn.mockRestore();
    });
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
  });

  // ── extras ──

  describe("extras", () => {
    it("returns 'n/a' when meal is open", () => {
      const store = createDataStore({
        mealProps: { closed: false, extras: 5 },
      });

      expect(store.extras).toBe("n/a");
      expect(typeof store.extras).toBe("string");
    });

    it("returns numeric difference when meal is closed and max is a number", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: 5 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: true }],
      });

      // max = extras + attendeesCount = 5 + 1 = 6
      // extras view = max - attendeesCount = 6 - 1 = 5
      expect(store.extras).toBe(5);
      expect(typeof store.extras).toBe("number");
    });

    it("returns empty string when meal is closed and max is null", () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: null },
      });

      expect(store.extras).toBe("");
      expect(typeof store.extras).toBe("string");
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

  describe("with no meal on screen", () => {
    it("the views answer blank, n/a, and false instead of throwing", () => {
      const store = createDataStore({ mealProps: { description: "Soup" } });
      expect(store.description).toBe("Soup");
      stage(store, () => {
        store.meal = null;
      });

      expect(store.description).toBe("");
      expect(store.extras).toBe("n/a");
      expect(store.canAdd).toBe(false);
    });
  });

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

    it("returns true when closed and extras is exactly 1 (boundary)", () => {
      // Boundary: extras=1 is the minimum value that allows adding
      const store = createDataStore({ mealProps: { closed: true, extras: 1 } });
      expect(store.canAdd).toBe(true);
    });

    it("flips from true to false when the last extra seat is taken", async () => {
      const store = createDataStore({
        mealProps: { closed: true, extras: 1 },
        residents: [{ id: 10, meal_id: 1, name: "Alice", attending: false }],
      });
      expect(store.canAdd).toBe(true);
      toastStore.clearAll();
      // What POST /meals/1/residents/10 answers (MealResidentSerializer).
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          id: 500,
          meal_id: 1,
          resident_id: 10,
          late: false,
          vegetarian: false,
          created_at: "2023-06-15T17:00:00Z",
        },
      });

      const alice = store.residents.get("10");
      alice.toggleAttending();
      expect(store.meal.extras).toBe(0);
      expect(store.canAdd).toBe(false);

      // The server saved it: the seat stays taken.
      await vi.waitFor(() => {
        expect(alice.attending_at).toEqual(new Date("2023-06-15T17:00:00Z"));
      });
      expect(alice.attending).toBe(true);
      expect(store.meal.extras).toBe(0);
      expect(store.canAdd).toBe(false);
      expect(toastStore.toasts).toEqual([]);
    });
  });

  // ── loadData transformation ──

  describe("loadData", () => {
    it("loads the server's real meal answer", () => {
      const store = createDataStore({ mealProps: { id: 42 } });

      store.loadData(mealFixture, "server");

      expect(store.meal.description).toBe("Pasta night with garlic bread");
      expect(store.meal.nextId).toBe(43);
      expect(store.meal.prevId).toBe(41);
      expect(store.meal.extras).toBeNull();
      expect(store.meal.closed_at).toBeNull();
      const date = store.meal.date;
      expect([date.getFullYear(), date.getMonth(), date.getDate()]).toEqual([
        2026, 0, 15,
      ]);
      expect(Array.from(store.residents.values()).map((r) => r.name)).toEqual([
        "A - Jane Smith",
        "B - Bob Johnson",
        "C - Alice Williams",
      ]);
      expect(store.residents.get("1").attending_at).toEqual(
        new Date("2026-01-14T18:30:00.000-08:00"),
      );
      expect(store.guests.size).toBe(1);
      expect(billFor(store, 1).amount).toBe("25.50");
      expect(blankRows(store)).toHaveLength(2);
      expect(store.attendeesCount).toBe(3);
      expect(store.mealLoading).toBe(false);
    });

    it("displays wire amounts losslessly (0 becomes blank, others zero-pad to two decimals)", () => {
      const store = createDataStore({ mealProps: { closed: false } });

      store.loadData(
        mealPayload({
          description: "Pasta night",
          next_id: 2,
          residents: [
            residentRow(10, "Alice", { attending: true }),
            residentRow(11, "Bob"),
          ],
          bills: [
            { resident_id: 10, amount: "25.5", no_cost: false },
            { resident_id: 11, amount: "0", no_cost: false },
          ],
        }),
        "server",
      );

      // Two cooks plus one blank row, to show three.
      expect(store.bills.size).toBe(3);
      expect(blankRows(store)).toHaveLength(1);
      // Rails drops trailing zeros ("25.5" for $25.50); the display pads
      // them back with string edits, never through a float.
      expect(billFor(store, 10).amount).toBe("25.50");
      // Zero means "not filled in yet", so it shows blank.
      expect(billFor(store, 11).amount).toBe("");
    });

    it("sorts residents alphabetically by name", () => {
      const store = createDataStore();

      const data = mealPayload({
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
      });

      store.loadData(data, "server");

      // Residents should be sorted: Alice, Bob, Charlie
      const names = Array.from(store.residents.values()).map((r) => r.name);
      expect(names).toEqual(["Alice", "Bob", "Charlie"]);
    });

    it("creates blank bills to reach minimum of 3", () => {
      const store = createDataStore();

      const data = mealPayload({
        residents: [residentRow(10, "Alice")],
        bills: [{ resident_id: 10, amount: "10", no_cost: false }],
      });

      store.loadData(data, "server");

      // 1 bill from data + 2 blanks = 3
      expect(store.bills.size).toBe(3);
      expect(billFor(store, 10).amount).toBe("10.00");
      expect(blankRows(store).map((b) => b.amount)).toEqual(["", ""]);
    });

    it("does not create blank bills when 3 or more exist", () => {
      const store = createDataStore();

      const data = mealPayload({
        residents: [
          residentRow(10, "Alice"),
          residentRow(11, "Bob"),
          residentRow(12, "Charlie"),
          residentRow(13, "Dana"),
        ],
        bills: [
          { resident_id: 10, amount: "10", no_cost: false },
          { resident_id: 11, amount: "20", no_cost: false },
          { resident_id: 12, amount: "30", no_cost: false },
          { resident_id: 13, amount: "5", no_cost: false },
        ],
      });

      store.loadData(data, "server");

      // 4 bills, no blanks needed
      expect(store.bills.size).toBe(4);
      expect(blankRows(store)).toHaveLength(0);
    });

    it("sets meal properties from data", () => {
      const store = createDataStore();

      // The first meal: the server points prev_id at the meal itself.
      const data = mealPayload({
        description: "Taco Tuesday",
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        reconciled: true,
        next_id: 2,
        prev_id: 1,
      });

      store.loadData(data, "server");

      expect(store.meal.description).toBe("Taco Tuesday");
      expect(store.meal.closed).toBe(true);
      expect(store.meal.reconciled).toBe(true);
      expect(store.meal.nextId).toBe(2);
      expect(store.meal.prevId).toBe(1);
    });

    it("sets extras based on max minus attendees when max is provided", () => {
      const store = createDataStore();

      const data = mealPayload({
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        max: 10,
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
      });

      store.loadData(data, "server");

      // max=10, attending=2, guests=1 => extras = 10 - 3 = 7
      expect(store.meal.extras).toBe(7);
    });

    it("sets extras to null when max is null", () => {
      const store = createDataStore();

      const data = mealPayload({
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
      });

      store.loadData(data, "server");

      expect(store.meal.extras).toBeNull();
    });

    it("sets mealLoading to false after loading", () => {
      const store = createDataStore();

      const data = mealPayload();

      store.loadData(data, "server");
      expect(store.mealLoading).toBe(false);
    });

    it("renames resident_id to resident in bill data", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });

      const data = mealPayload({
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
        bills: [{ resident_id: 10, amount: "15", no_cost: false }],
      });

      store.loadData(data, "server");

      const bills = Array.from(store.bills.values());
      const aliceBill = bills.find((b) => b.resident !== null);
      expect(aliceBill).toBeTruthy();
      expect(aliceBill.resident.id).toBe(10);
    });

    it("loads guest data", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });

      const data = mealPayload({
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
          },
        ],
      });

      store.loadData(data, "server");

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
        // The first meal points at itself (MealFormSerializer).
        prev_id: Math.max(id - 1, 1),
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
      store.loadData(makeMealData(1, { attending: false }), "server");

      // Old reference is dead
      expect(isAlive(oldResident)).toBe(false);

      // New resident is alive with updated data
      const newResident = store.residents.get("10");
      expect(isAlive(newResident)).toBe(true);
      expect(newResident.attending).toBe(false);
    });

    it("successive loadData calls replace nodes each time", () => {
      const store = createDataStore();

      store.loadData(makeMealData(1, { attending: true }), "server");
      const ref1 = store.residents.get("10");
      expect(isAlive(ref1)).toBe(true);

      store.loadData(makeMealData(1, { attending: false }), "server");
      expect(isAlive(ref1)).toBe(false);

      const ref2 = store.residents.get("10");
      expect(isAlive(ref2)).toBe(true);
      expect(ref2.attending).toBe(false);

      store.loadData(makeMealData(1, { late: true }), "server");
      expect(isAlive(ref2)).toBe(false);

      const ref3 = store.residents.get("10");
      expect(isAlive(ref3)).toBe(true);
      expect(ref3.late).toBe(true);
    });

    it("loadDataAsync drops a meal-1 answer that lands after the switch to meal 2", async () => {
      const store = createDataStore({ mealProps: { id: 1 } });
      store.loadData(makeMealData(1, { attending: true }), "server");

      // A refetch of meal 1 goes out, and its answer is slow.
      let answerMeal1;
      axios.get.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            answerMeal1 = resolve;
          }),
      );
      store.loadDataAsync();
      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");

      // The person moves to meal 2 before it answers. Meal 2's IndexedDB
      // read has not finished either, so meal 2 has no data yet.
      idbKeyval.get.mockImplementationOnce(() => new Promise(() => {}));
      store.switchMeals(2);

      // Now meal 1's answer lands.
      const meal1 = makeMealData(1, { attending: false, late: true });
      answerMeal1({ status: 200, data: meal1 });
      await vi.waitFor(() => {
        expect(idbKeyval.set).toHaveBeenCalledWith("1", meal1);
      });
      await new Promise((r) => setTimeout(r, 0));

      // It is cached under meal 1, but it does not reach meal 2's screen.
      expect(store.meal.id).toBe(2);
      expect(store.meal.description).toBe("");
      expect(store.residents.size).toBe(0);
    });

    it("loadMonth does not clobber meal Pusher subscription", async () => {
      const store = createDataStore({ mealProps: { id: 1 } });

      stubPusherChannels();

      const mealData = mealPayload({
        description: "Meal",
      });
      store.loadData(mealData, "server");
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

    it("switchMeals skips the cache callback if user already navigated away", async () => {
      const store = createDataStore({
        mealProps: { id: 1 },
      });

      // Add meals 2 and 3 to the array
      stage(store, () => {
        store.meals.push({ id: 2 });
        store.meals.push({ id: 3 });
      });

      // Load initial data for meal 1
      store.loadData(makeMealData(1), "server");

      // Set up IndexedDB to return cached data for meal 2
      const meal2Data = makeMealData(2, { attending: true });
      idbKeyval.get.mockResolvedValueOnce(meal2Data);

      // switchMeals to meal 2 starts the async IndexedDB lookup
      store.switchMeals(2);

      // Before IndexedDB resolves, user navigates to meal 3. switchMeals
      // pruned the pre-pushed stub for meal 3 (issue #38), so recreate it
      // the way switchMeals would.
      stage(store, () => {
        store.meals.push({ id: 3 });
        store.meal = 3;
      });
      store.loadData(makeMealData(3, { late: true }), "server");

      // Now let IndexedDB resolve (for the stale meal 2 request)
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
      stage(store, () => {
        store.currentDate = "2023-07-01";
      });
      store.loadMonthAsync();

      // Navigate to August before July's response arrives
      stage(store, () => {
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
      expect(idbKeyval.set).not.toHaveBeenCalledWith(
        expect.anything(),
        julyResponse.data,
      );
    });

    it("switchMonths skips a stale IndexedDB read if user already navigated away", async () => {
      const store = createDataStore();

      // Year 2024 so no adjacent-month prefetch the loadMonthAsync test
      // above started (month_fetch keeps them as module state) can
      // answer for these months.
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
      idbKeyval.get.mockImplementation((key) => {
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
        // The first meal points at itself (MealFormSerializer).
        prev_id: Math.max(id - 1, 1),
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

      store.loadData(mealData(1), "server");
      expect(store.mealLoading).toBe(false);
    });

    it("teardownMealPage unsubscribes the meal channel, nulls the meal, and prunes the nodes", () => {
      const store = createDataStore();
      stubPusherChannels();

      store.loadData(mealData(1), "server");
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
      data.bills = [{ resident_id: 10, amount: "25.5", no_cost: false }];
      store.loadData(data, "server");

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
      stage(store, () => {
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
      stubPusherChannels();

      store.loadMonth(calendarData());
      // The residents channel is not the calendar page's: it stays for
      // the life of the store (live_updates.test.js).
      const subscribed = window.Comeals.pusher.subscribe.mock.calls
        .map((call) => call[0])
        .filter((name) => !name.endsWith("-residents"));
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
      store.loadData(mealData(1), "server");
      const oldNode = store.meals.find((m) => m.id === 1);

      store.switchMeals(2);

      expect(store.meal.id).toBe(2);
      expect(store.meals.length).toBe(1);
      expect(isAlive(oldNode)).toBe(false);
    });

    it("switchMeals clears the rows of the meal it leaves", () => {
      // Same rule as the teardownMealPage clear: rows belong to their
      // meal. Stale rows shown while the next meal loads were editable,
      // and a bill edit made in that window was sent to the NEW meal's
      // bills endpoint carrying the OLD meal's cook list.
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
      data.bills = [{ resident_id: 10, amount: "25.5", no_cost: false }];
      store.loadData(data, "server");

      store.switchMeals(2);

      expect(store.meal.id).toBe(2);
      expect(store.bills.size).toBe(0);
      expect(store.residents.size).toBe(0);
      expect(store.guests.size).toBe(0);
    });

    it("switchMeals keeps a left-behind node with unsaved menu text", () => {
      const store = createDataStore();
      const node = store.meals[0];
      stage(store, () => {
        node.descriptionDirty = true;
      });

      store.switchMeals(2);

      expect(store.meal.id).toBe(2);
      expect(isAlive(node)).toBe(true);
      expect(store.meals.map((m) => m.id).sort()).toEqual([1, 2]);
    });
  });

  // ── meal load retry (stuck loading) ──
  //
  // A failed FIRST load of a meal used to stay silent: mealLoading
  // never settled and the page said "loading..." forever. Now it
  // retries with a capped growing wait and shows an honest notice.
  // Background refetch failures (data already on screen) stay silent —
  // the reconnect and online handlers already cover them.

  describe("meal load retry (stuck loading)", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    function cooksCallsFor(mealId) {
      return axios.get.mock.calls.filter(
        ([url]) => url === `/api/v1/meals/${mealId}/cooks`,
      );
    }

    it("a failed first load enters the retry state and retries with growing waits", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });

      expect(store.mealLoading).toBe(true);
      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);

      expect(store.mealLoadFailed).toBe(true);
      expect(cooksCallsFor(1).length).toBe(1);

      // First retry after 2s, second 4s later.
      await vi.advanceTimersByTimeAsync(2000);
      expect(cooksCallsFor(1).length).toBe(2);
      await vi.advanceTimersByTimeAsync(3999);
      expect(cooksCallsFor(1).length).toBe(2);
      await vi.advanceTimersByTimeAsync(1);
      expect(cooksCallsFor(1).length).toBe(3);
    });

    it("the wait doubles and caps at 30 seconds, and never stops", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);

      // Waits: 2s, 4s, 8s, 16s, 30s (capped), 30s, ...
      const waits = [2000, 4000, 8000, 16000, 30000, 30000, 30000];
      let expected = 1;
      for (const wait of waits) {
        await vi.advanceTimersByTimeAsync(wait);
        expected += 1;
        expect(cooksCallsFor(1).length).toBe(expected);
      }
    });

    it("a background refetch failure stays silent", async () => {
      const store = createDataStore();
      store.loadData(mealPayload(), "server");
      expect(store.mealLoading).toBe(false);
      toastStore.clearAll();

      axios.get.mockRejectedValue({ request: {} });
      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);

      expect(toastStore.toasts).toEqual([]);
      expect(store.mealLoadFailed).toBe(false);
      await vi.advanceTimersByTimeAsync(60000);
      expect(cooksCallsFor(1).length).toBe(1);
    });

    it("a 404 shows not-found and never retries", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ response: { status: 404, data: {} } });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);

      expect(store.mealLoadNotFound).toBe(true);
      expect(store.mealLoadFailed).toBe(false);
      await vi.advanceTimersByTimeAsync(120000);
      expect(cooksCallsFor(1).length).toBe(1);
    });

    it("switching meals cancels the retry and clears the failure", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);
      expect(store.mealLoadFailed).toBe(true);

      axios.get.mockImplementation(() =>
        Promise.resolve({ status: 200, data: {} }),
      );
      const timersBefore = vi.getTimerCount();
      store.switchMeals(2);
      expect(store.mealLoadFailed).toBe(false);
      // The retry timer itself is cleared, not only ignored when it fires.
      expect(vi.getTimerCount()).toBe(timersBefore - 1);

      // The old meal's pending retry never fires.
      await vi.advanceTimersByTimeAsync(60000);
      expect(cooksCallsFor(1).length).toBe(1);
    });

    // A retry timer left running would fire into the meal once the
    // person comes back to it: an extra fetch, and mealRetryTimer set to
    // null while the new load's own timer is still pending.
    it("an old retry does not fire after going away and back to the meal", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });
      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);
      expect(store.mealLoadFailed).toBe(true); // meal 1's retry is due at 2s

      store.goToMeal(2);
      await vi.advanceTimersByTimeAsync(0);
      // Back to meal 1, whose new load hangs on a slow network.
      axios.get.mockImplementation((url) =>
        url === "/api/v1/meals/1/cooks"
          ? new Promise(() => {})
          : Promise.reject({ request: {} }),
      );
      store.goToMeal(1);
      await vi.advanceTimersByTimeAsync(0);
      expect(cooksCallsFor(1).length).toBe(2);

      await vi.advanceTimersByTimeAsync(2000);

      // The first try and the new load: nothing from the old timer.
      expect(cooksCallsFor(1).length).toBe(2);
    });

    it("teardownMealPage cancels the retry and clears the failure", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);
      expect(store.mealLoadFailed).toBe(true);

      const timersBefore = vi.getTimerCount();
      store.teardownMealPage();
      expect(store.mealLoadFailed).toBe(false);
      expect(vi.getTimerCount()).toBe(timersBefore - 1);

      await vi.advanceTimersByTimeAsync(60000);
      expect(cooksCallsFor(1).length).toBe(1);
    });

    it("a load that lands clears the failure and resets the backoff", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);
      await vi.advanceTimersByTimeAsync(2000); // retry #1 fails; wait is now 4s
      expect(cooksCallsFor(1).length).toBe(2);

      store.loadData(mealPayload(), "server");
      expect(store.mealLoadFailed).toBe(false);

      // A later failure starts the backoff from the base again.
      // goToMeal itself fires the load (cache miss → loadDataAsync).
      store.goToMeal(1);
      await vi.advanceTimersByTimeAsync(0);
      expect(store.mealLoadFailed).toBe(true);
      const callsBefore = cooksCallsFor(1).length;
      await vi.advanceTimersByTimeAsync(2000);
      expect(cooksCallsFor(1).length).toBe(callsBefore + 1);
    });

    it("retry-now fetches immediately and resets the backoff", async () => {
      const store = createDataStore();
      axios.get.mockRejectedValue({ request: {} });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);
      await vi.advanceTimersByTimeAsync(2000); // retry #1 fails; wait is now 4s
      expect(cooksCallsFor(1).length).toBe(2);

      store.retryMealLoadNow();
      await vi.advanceTimersByTimeAsync(0);
      expect(cooksCallsFor(1).length).toBe(3);

      // That manual try failed too; the next automatic one comes at
      // the base wait, not the doubled one.
      await vi.advanceTimersByTimeAsync(2000);
      expect(cooksCallsFor(1).length).toBe(4);
    });

    it("an error while processing a good response does not loop retries", async () => {
      const store = createDataStore();
      // The fetch succeeds but the payload is garbage: processing
      // throws. That is a bug to fix, not a network state to retry.
      axios.get.mockResolvedValue({ status: 200, data: {} });

      store.loadDataAsync();
      await vi.advanceTimersByTimeAsync(0);

      expect(store.mealLoadFailed).toBe(false);
      await vi.advanceTimersByTimeAsync(60000);
      expect(cooksCallsFor(1).length).toBe(1);
    });
  });

  // ── extras view return types ──

  // ── BUG-1: closed_at null handling ──

  describe("closed_at null handling", () => {
    it("preserves null closed_at instead of creating epoch Date (Regression test for BUG-1)", () => {
      const store = createDataStore();

      // An open meal: the server sends no closed_at. (A closed meal
      // always has one: CHECK meals_closed_at_matches_closed.)
      const data = mealPayload({ closed: false, closed_at: null });

      store.loadData(data, "server");
      expect(store.meal.closed_at).toBeNull();
    });

    it("preserves a valid closed_at Date", () => {
      const store = createDataStore();

      const data = mealPayload({
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
      });

      store.loadData(data, "server");
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
        data: mealPayload({
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
          bills: [{ resident_id: 10, amount: "25.0", no_cost: false }],
        }),
      });

      store.submitBills();

      // Wait for the catch handler to fire and verify final toast state
      // One info toast that carries the server's warning text.
      await vi.waitFor(() => {
        expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
          ["info", "Cooks saved. Warning: third cooks should not be added."],
        ]);
      });
    });

    it("says only that the cooks were saved when the warning has no text", async () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "bill-1", resident: 10, amount: "25.00" }],
      });
      toastStore.clearAll();
      axios.mockRejectedValueOnce({
        response: { status: 400, data: { message: "", type: "warning" } },
      });
      axios.get.mockResolvedValueOnce({ status: 200, data: mealPayload() });

      store.submitBills();

      await vi.waitFor(() => {
        expect(toastStore.toasts.map((t) => t.message)).toEqual([
          "Cooks saved.",
        ]);
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
      // The warning is the only sign the server sent a broken month.
      expect(spy).toHaveBeenCalledWith(
        "loadMonth: missing event arrays from API:",
        "bills, rotations, birthdays, common_house_reservations, guest_room_reservations, events",
      );
      spy.mockRestore();
    });

    it("handles all arrays missing", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore();

      const data = { id: 1, year: 2023, month: 6 };

      expect(() => store.loadMonth(data)).not.toThrow();
      expect(store.calendarEvents.length).toBe(0);
      expect(spy).toHaveBeenCalledWith(
        "loadMonth: missing event arrays from API:",
        "meals, bills, rotations, birthdays, common_house_reservations, guest_room_reservations, events",
      );
      spy.mockRestore();
    });

    it("does not warn when every array is there, even an empty one", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore();

      store.loadMonth({
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
      });

      expect(spy).not.toHaveBeenCalled();
      spy.mockRestore();
    });
  });

  // ── BUG-6 and #91: a bill whose cook is not in the residents list ──

  describe("loadData bill reference integrity", () => {
    const RELOAD_MESSAGE =
      "One cook's cost on this meal is not shown on this page, so nothing was saved. Please reload the page.";

    function billsPatches() {
      return axios.mock.calls.filter(
        ([config]) =>
          config &&
          config.method === "patch" &&
          config.url === "/api/v1/meals/1/bills",
      );
    }

    // Alice has a bill and is listed. Cook 999 has a bill but no row in
    // residents. The server lists every cook who has a bill
    // (MealFormSerializer), so this should never happen.
    function mealWithHiddenCook() {
      return mealPayload({
        residents: [residentRow(10, "Alice")],
        bills: [
          { resident_id: 10, amount: "15", no_cost: false },
          { resident_id: 999, amount: "40", no_cost: false },
        ],
      });
    }

    // The page cannot show the bill, because its row needs a resident to
    // point at. It keeps working, and shows three rows as always.
    it("keeps working when a bill's cook is not in the residents list (BUG-6)", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore();

      expect(() =>
        store.loadData(mealWithHiddenCook(), "server"),
      ).not.toThrow();

      expect(billFor(store, 10).amount).toBe("15.00");
      expect(store.bills.size).toBe(3);
      expect(blankRows(store)).toHaveLength(2);
      expect(spy).toHaveBeenCalledWith(
        "Bills will not save: these cooks have a bill but are not in the residents list:",
        [999],
      );
      spy.mockRestore();
    });

    // A bills save lists every cook, and the server deletes the bill of
    // a cook left out (BillsPayload#write_to). So a save from this page
    // would delete cook 999's bill. Nothing is sent, and the person is
    // told to reload (#91).
    it("refuses a save of another cook's cost: nothing is sent, and the toast says to reload", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      toastStore.clearAll();
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(mealWithHiddenCook(), "server");

      billFor(store, 10).setAmount("16");
      store.submitBills();

      expect(billsPatches()).toHaveLength(0);
      expect(store.billsSaveInFlight).toBe(false);
      expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
        ["error", RELOAD_MESSAGE],
      ]);
      spy.mockRestore();
    });

    // The reload brings the server's list, which names the retired cook
    // (inactive, did not eat). Saves go through again, and a save of
    // another cook's cost names both cooks, so the server keeps the
    // retired cook's bill.
    it("sends saves again once a reload lists every cook, naming the retired cook too", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(mealWithHiddenCook(), "server");

      store.loadData(
        mealPayload({
          residents: [
            residentRow(10, "Alice"),
            residentRow(999, "Carol", { active: false }),
          ],
          bills: mealWithHiddenCook().bills,
        }),
        "server",
      );
      billFor(store, 10).setAmount("16");
      store.submitBills();

      expect(billsPatches()).toHaveLength(1);
      expect(billsPatches()[0][0].data.bills).toEqual([
        { resident_id: 10, amount: "16", no_cost: false },
        { resident_id: 999 },
      ]);
      spy.mockRestore();
    });

    // billsIncomplete is about the bill rows on screen. Switching meals
    // clears those rows, so it clears the flag too.
    it("clears billsIncomplete when the page switches to another meal", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(mealWithHiddenCook(), "server");

      store.switchMeals(2);

      expect(store.billsIncomplete).toBe(false);
      spy.mockRestore();
    });
  });

  // ── Hardening: critical path edge cases ──

  describe("loadData edge cases", () => {
    it("handles completely empty data (no residents, guests, or bills)", () => {
      const store = createDataStore();
      const data = mealPayload();

      store.loadData(data, "server");
      expect(store.residents.size).toBe(0);
      expect(store.guests.size).toBe(0);
      expect(store.bills.size).toBe(3); // 3 blank bills created
      expect(store.attendeesCount).toBe(0);
      expect(store.meal.extras).toBeNull();
    });

    it("sets extras to 0 when max equals the number of attendees", () => {
      const store = createDataStore();
      const data = mealPayload({
        closed: true,
        closed_at: "2023-06-15T18:00:00Z",
        max: 2,
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
      });

      store.loadData(data, "server");
      expect(store.meal.extras).toBe(0); // max=2, attendees=2
      expect(store.canAdd).toBe(false);
    });

    // A closed meal with a cap of zero and nobody signed up is valid on
    // the server (max >= attendees). Zero is a cap, not "no cap".
    it("handles max=0 on a closed meal with no attendees", () => {
      const store = createDataStore();

      store.loadData(
        mealPayload({
          closed: true,
          closed_at: "2023-06-15T18:00:00Z",
          max: 0,
          residents: [residentRow(10, "Alice")],
        }),
        "server",
      );

      expect(store.meal.extras).toBe(0);
      expect(store.meal.max).toBe(0);
      expect(store.extras).toBe(0);
      expect(store.canAdd).toBe(false);
    });

    it("handles bill with amount zero correctly (displays as empty string)", () => {
      const store = createDataStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
      });
      const data = mealPayload({
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
        bills: [{ resident_id: 10, amount: "0", no_cost: false }],
      });

      store.loadData(data, "server");
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
        next_id: 1,
        prev_id: 1,
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
          { resident_id: 10, amount: "12.34", no_cost: false },
          { resident_id: 11, amount: "0.0", no_cost: false },
        ]),
        "server",
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
          { resident_id: 10, amount: "12.345", no_cost: false },
          { resident_id: 11, amount: "0.0", no_cost: false },
        ]),
        "server",
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
      stage(store, () => {
        bill.amount = "1e3";
        bill.touched = true;
      });

      store.submitBills();

      expect(billsPatchCalls().length).toBe(0);
    });

    it("submitBills is a no-op when no meal is loaded", () => {
      const store = createDataStore({
        mealProps: { closed: false },
        residents: [{ id: 10, meal_id: 1, name: "Alice", can_cook: true }],
        bills: [{ id: "b1", resident: 10, amount: "5.00", no_cost: false }],
      });
      store.teardownMealPage();

      expect(() => store.submitBills()).not.toThrow();
      expect(
        axios.mock.calls.filter(([c]) => c && c.method === "patch").length,
      ).toBe(0);
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
      store.loadData(
        mealPayload({
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
          bills: [{ resident_id: 11, amount: "0.0", no_cost: false }],
        }),
        "server",
      );
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

    it("an edit's debounced save cannot follow a meal switch onto the new meal", () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      // The user types, then switches meals before the debounce fires.
      bill.setAmount("99.00");
      store.switchMeals(2);

      // The switch flushed the edit to the meal it was typed on.
      const flushed = billsPatchCalls(1);
      expect(flushed.length).toBe(1);
      expect(flushed[0][0].data.bills).toContainEqual({
        resident_id: 11,
        amount: "99.00",
        no_cost: false,
      });

      // The old rows left with meal 1, so nothing remains that could be
      // edited — or sent — against meal 2 while it loads. A probe on
      // 2026-07-22 showed a keystroke in this window sending meal 1's
      // cook list to meal 2, which the server treats as the complete
      // list for meal 2.
      expect(store.bills.size).toBe(0);
      // The flush consumed the timer: nothing more fires later.
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS * 2);
      expect(billsPatchCalls(1).length).toBe(1);
      expect(billsPatchCalls(2).length).toBe(0);
    });

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

    it("ignores an ack row for a cook who is not on screen", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);
      toastStore.clearAll();
      // The unknown cook comes first: skipping it must not stop the rows
      // after it from being applied.
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [
            { resident_id: 99, amount: "7.00", no_cost: false },
            { resident_id: 11, amount: "12.34", no_cost: false },
          ],
        },
      });

      bill.setAmount("5.50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      axios.get.mockClear();
      await vi.advanceTimersByTimeAsync(0);

      expect(bill.amount).toBe("12.34");
      expect(bill.touched).toBe(false);
      // A clean ack: no error toast, and no refetch to repair it.
      expect(toastStore.toasts).toEqual([]);
      expect(axios.get).not.toHaveBeenCalled();
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
      stage(store, () => {
        bill.touched = false;
      });

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

    // The client that knows, invalidates (issue #37): bill saves send
    // socketId, so the sender gets no Pusher echo and the cached meal
    // payload keeps the old bills until evicted.
    it("evicts the meal's cached payload when the save succeeds", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0);

      expect(idbKeyval.del).toHaveBeenCalledWith("1");
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

      expect(idbKeyval.del).toHaveBeenCalledWith("1");
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

      expect(idbKeyval.del).not.toHaveBeenCalled();
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
    it("sends the new state to the meal's closed endpoint", () => {
      const store = createDataStore({ mealProps: { closed: false } });
      window.Comeals.socketId = "socket-1";

      store.toggleClosed();

      expect(axios).toHaveBeenCalledTimes(1);
      expect(axios).toHaveBeenCalledWith({
        method: "patch",
        url: "/api/v1/meals/1/closed",
        withCredentials: true,
        data: { closed: true, socket_id: "socket-1" },
      });
    });

    it("sends closed: false to reopen a closed meal", () => {
      const store = createDataStore({
        mealProps: {
          closed: true,
          closed_at: new Date("2023-06-15T18:00:00Z"),
        },
      });

      store.toggleClosed();

      expect(store.meal.closed).toBe(false); // optimistic write
      expect(axios.mock.calls[0][0].data.closed).toBe(false);
    });

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
      const store = createDataStore();
      stubPusherChannels();
      store.loadMonth({
        id: 1,
        year: 2023,
        month: 6,
        meals: [{ title: "Dinner", start: "2023-06-15T18:30:00" }],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      });
      const version = store.calendarEventsVersion;
      const subscribes = pusherClient.subscribe.mock.calls.length;
      const spy = vi.spyOn(console, "error").mockImplementation(() => {});
      stage(store, () => {
        store.monthLoading = true;
      });

      store.loadMonth("error: unauthorized");

      // The month already on screen stays, with no new channels for a
      // month that never loaded; only the loading state ends.
      expect(store.calendarEvents.map((e) => e.title)).toEqual(["Dinner"]);
      expect(store.calendarEventsVersion).toBe(version);
      expect(pusherClient.subscribe.mock.calls.length).toBe(subscribes);
      expect(store.monthLoading).toBe(false);
      expect(spy).toHaveBeenCalledWith(
        "Error loading month data.",
        "error: unauthorized",
      );
      spy.mockRestore();
    });

    it("reads naive times and dates as wall-clock values in the community timezone", () => {
      // A community east of UTC, far from any test machine: a naive
      // string read as a local or UTC instant and then moved into this
      // zone would land hours off.
      cookies.current.timezone = "Asia/Tokyo";
      const store = createDataStore();
      const data = {
        id: 1,
        year: 2023,
        month: 6,
        meals: [
          {
            title: "Dinner",
            start: "2023-06-15T18:30:00",
            end: "2023-06-15T19:45:00",
          },
        ],
        bills: [],
        rotations: [],
        // A birthday is a date with no time.
        birthdays: [{ title: "Ann", start: "2023-06-15", end: "2023-06-15" }],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [],
      };

      store.loadMonth(data);
      const [meal, birthday] = store.calendarEvents;
      const wallClock = (d) => [d.getDate(), d.getHours(), d.getMinutes()];

      expect(meal.title).toBe("Dinner");
      expect(wallClock(meal.start)).toEqual([15, 18, 30]);
      expect(wallClock(meal.end)).toEqual([15, 19, 45]);
      expect(birthday.title).toBe("Ann");
      expect(wallClock(birthday.start)).toEqual([15, 0, 0]);
      expect(wallClock(birthday.end)).toEqual([15, 0, 0]);
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

      expect(idbKeyval.del).toHaveBeenCalledWith(
        "community-test-community-id-calendar-2026-9",
      );
    });

    it("resolves an offset wire string to the community month, not the UTC month", () => {
      const store = createDataStore();

      // 2026-10-01 02:00 UTC is 2026-09-30 19:00 in America/Los_Angeles.
      store.invalidateMonthForDate("2026-10-01T02:00:00.000Z");

      expect(idbKeyval.del).toHaveBeenCalledWith(
        "community-test-community-id-calendar-2026-9",
      );
    });

    it("reads a naive wire string as a community-timezone date", () => {
      // The first of a month, in a community west of every test machine
      // (UTC-11): read as a UTC or local instant, it would be September
      // 30 there, and the wrong month would be evicted.
      cookies.current.timezone = "Pacific/Pago_Pago";
      const store = createDataStore();

      store.invalidateMonthForDate("2026-10-01");

      expect(idbKeyval.del).toHaveBeenCalledTimes(1);
      expect(idbKeyval.del).toHaveBeenCalledWith(
        "community-test-community-id-calendar-2026-10",
      );
    });

    it("ignores null and unparseable dates", () => {
      const store = createDataStore();

      store.invalidateMonthForDate(null);
      store.invalidateMonthForDate("not-a-date");

      expect(idbKeyval.del).not.toHaveBeenCalled();
    });
  });

  describe("Pusher reconnect recovery", () => {
    // The mock Pusher's connection.bind is a vi.fn(); pull out the
    // state_change handler afterCreate registered so tests can drive
    // connection transitions directly.
    async function stateChangeHandler() {
      // The store talks to the pusherClient facade; the real (mock)
      // Pusher arrives through a dynamic import a few microtasks after
      // createDataStore, and the facade then replays the queued
      // connection.bind calls onto it. Flush microtasks until the
      // state_change handler from THIS test's store has been bound
      // (clearAllMocks empties the calls list between tests).
      const Pusher = (await import("pusher-js")).default;
      function calls() {
        const instance = Pusher.instances[Pusher.instances.length - 1];
        if (!instance) return [];
        return instance.connection.bind.mock.calls.filter(
          ([event]) => event === "state_change",
        );
      }
      // Polled, not a fixed number of microtask turns: the dynamic import
      // takes more of them on a slow runner (see app_plumbing.test.js).
      await vi.waitFor(() => {
        if (calls().length === 0) throw new Error("handler not bound yet");
      });
      return calls()[calls().length - 1][1];
    }

    it("does not refetch on the first connection at page load", async () => {
      createDataStore();
      const handler = await stateChangeHandler();
      axios.get.mockClear();

      handler({ previous: "connecting", current: "connected" });

      expect(axios.get).not.toHaveBeenCalled();
    });

    // Regression: the handler required previous === "unavailable", but
    // pusher-js only reaches "unavailable" after ~10s. A shorter drop
    // reconnects as connecting → connected, and events broadcast during
    // the gap were silently lost (Pusher does not replay them).
    it("refetches after a short blip that never reached unavailable", async () => {
      createDataStore();
      const handler = await stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load
      axios.get.mockClear();

      handler({ previous: "connected", current: "connecting" });
      handler({ previous: "connecting", current: "connected" });

      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");
      expect(axios.get).toHaveBeenCalledWith(
        expect.stringContaining("/calendar/"),
      );
    });

    it("still refetches after a long gap through unavailable", async () => {
      createDataStore();
      const handler = await stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load
      axios.get.mockClear();

      handler({ previous: "unavailable", current: "connected" });

      expect(axios.get).toHaveBeenCalledWith("/api/v1/meals/1/cooks");
    });

    // A blip on the login page must not fire an unauthenticated fetch —
    // the 401 would raise the "you've been signed out" banner for a
    // person who is not signed in. Same guard as the `online` handler.
    it("skips the refetch when the community_id cookie is gone", async () => {
      createDataStore();
      const handler = await stateChangeHandler();
      handler({ previous: "connecting", current: "connected" }); // page load
      // Logged out in another tab. The setup file puts the cookie back
      // after the test.
      delete cookies.current.community_id;
      axios.get.mockClear();

      handler({ previous: "unavailable", current: "connected" });

      expect(axios.get).not.toHaveBeenCalled();
    });
  });

  describe("communityToday", () => {
    async function stateChangeHandler() {
      // The store talks to the pusherClient facade; the real (mock)
      // Pusher arrives through a dynamic import a few microtasks after
      // createDataStore, and the facade then replays the queued
      // connection.bind calls onto it. Flush microtasks until the
      // state_change handler from THIS test's store has been bound
      // (clearAllMocks empties the calls list between tests).
      const Pusher = (await import("pusher-js")).default;
      function calls() {
        const instance = Pusher.instances[Pusher.instances.length - 1];
        if (!instance) return [];
        return instance.connection.bind.mock.calls.filter(
          ([event]) => event === "state_change",
        );
      }
      // Polled, not a fixed number of microtask turns: the dynamic import
      // takes more of them on a slow runner (see app_plumbing.test.js).
      await vi.waitFor(() => {
        if (calls().length === 0) throw new Error("handler not bound yet");
      });
      return calls()[calls().length - 1][1];
    }

    afterEach(() => {
      vi.useRealTimers();
    });

    it("initializes to today's date in the community timezone", () => {
      vi.useFakeTimers();
      // 03:00 UTC on July 9 is still July 8 in Los Angeles.
      vi.setSystemTime(new Date("2026-07-09T03:00:00Z"));

      const store = createDataStore();

      expect(store.communityToday).toBe("2026-07-08");
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
    it("recomputes on Pusher reconnect when the timer never fired", async () => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date("2026-07-08T23:59:00-07:00"));
      const store = createDataStore();
      const handler = await stateChangeHandler();
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
    it("sends DELETE /api/v1/sessions/current with an Authorization header before clearing cookies", () => {
      const store = createDataStore();

      store.logout();

      // The cookie mock acts like the browser's cookie jar, so a token
      // read after the removes would find nothing and send no DELETE.
      expect(axios.delete).toHaveBeenCalledTimes(1);
      expect(axios.delete).toHaveBeenCalledWith("/api/v1/sessions/current", {
        headers: { Authorization: "Bearer test-token" },
      });
      ["token", "community_id", "resident_id", "username", "timezone"].forEach(
        (name) => {
          expect(Cookie.remove).toHaveBeenCalledWith(name, { path: "/" });
          expect(Cookie.get(name)).toBeUndefined();
        },
      );
    });

    it("skips the server call when no token cookie is present", () => {
      delete cookies.current.token;

      const store = createDataStore();
      store.logout();

      expect(axios.delete).not.toHaveBeenCalled();
      expect(Cookie.remove).toHaveBeenCalledWith("token", { path: "/" });
      expect(Cookie.get("community_id")).toBeUndefined();
    });
  });

  // ── description dirty state (issue #35) ──

  describe("description dirty state", () => {
    it("loadData leaves the description alone while it has unsaved typing", async () => {
      const store = createDataStore();
      axios.mockRejectedValueOnce({ request: {} });

      store.setDescriptionOn(store.meal, "typed text");
      await new Promise((r) => setTimeout(r, 0));
      expect(store.meal.descriptionDirty).toBe(true);

      store.loadData(mealPayload({ description: "server text" }), "server");

      expect(store.meal.description).toBe("typed text");
    });

    it("loadData writes the description again once the text is saved", async () => {
      const store = createDataStore();

      store.setDescriptionOn(store.meal, "typed text");
      await new Promise((r) => setTimeout(r, 0));
      expect(store.meal.descriptionDirty).toBe(false);

      store.loadData(mealPayload({ description: "server text" }), "server");

      expect(store.meal.description).toBe("server text");
    });

    it("retryDirtyDescriptions resends a dirty meal, even one no longer on screen", async () => {
      const store = createDataStore();
      axios.mockRejectedValueOnce({ request: {} });

      store.setDescriptionOn(store.meal, "typed text");
      await new Promise((r) => setTimeout(r, 0));

      // The user moved on to another meal; the unsaved text stays behind
      // on meal 1's node.
      stage(store, () => {
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

    // The menu box binds its callbacks to the meal node it rendered.
    // A debounced flush that fires after a meal switch must land on the
    // meal the text was typed on — it used to land on store.meal, which
    // silently replaced the NEW meal's menu (probe, 2026-07-22).

    it("noteMenuTyping keeps the typed-on node alive across a meal switch", () => {
      const store = createDataStore();
      const node = store.meal;

      store.noteMenuTyping(node);
      store.switchMeals(2);

      expect(isAlive(node)).toBe(true);
      expect(node.descriptionDirty).toBe(true);
    });

    it("a late flush saves to the meal it was typed on, not the current one", () => {
      const store = createDataStore();
      const node = store.meal;

      store.noteMenuTyping(node);
      store.switchMeals(2);
      store.setDescriptionOn(node, "Tacos");

      expect(node.description).toBe("Tacos");
      const descPatches = axios.mock.calls.filter(
        ([c]) => c && c.method === "patch" && c.url.includes("/description"),
      );
      expect(descPatches.length).toBe(1);
      expect(descPatches[0][0].url).toBe("/api/v1/meals/1/description");
    });

    it("a flush onto a dead node is a no-op", () => {
      const store = createDataStore();
      const node = store.meal;

      // Not dirty, so the switch prunes the node.
      store.switchMeals(2);
      expect(isAlive(node)).toBe(false);

      expect(() => store.setDescriptionOn(node, "Tacos")).not.toThrow();
      expect(
        axios.mock.calls.filter(
          ([c]) => c && c.method === "patch" && c.url.includes("/description"),
        ).length,
      ).toBe(0);
    });

    it("an ack for older text cannot clear a keystroke's protection", async () => {
      const store = createDataStore();
      let resolveSave;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveSave = resolve;
          }),
      );

      // A save is in flight; a newer keystroke arrives before its flush.
      store.setDescriptionOn(store.meal, "first");
      store.noteMenuTyping(store.meal);

      resolveSave({ status: 200 });
      await new Promise((r) => setTimeout(r, 0));

      expect(store.meal.descriptionDirty).toBe(true);
    });
  });

  describe("boot-time month prefetch (issue #44)", () => {
    // index.jsx calls prefetchMonth() before React mounts, so the
    // month download runs in parallel with the calendar chunk. These
    // tests pin the two dedupe rules that keep the mount-time load
    // from repeating the request. Months are unique per test because a
    // prefetch still in flight is module state (month_fetch.js) that
    // the next test could adopt.

    function monthPayload(year, month, title) {
      return {
        id: "test-community-id",
        year: year,
        month: month,
        meals: [],
        bills: [],
        rotations: [],
        birthdays: [],
        common_house_reservations: [],
        guest_room_reservations: [],
        events: [{ id: 1, title: title }],
      };
    }

    function monthCalls(fragment) {
      return axios.get.mock.calls.filter((c) => c[0].includes(fragment)).length;
    }

    it("goToMonth adopts an in-flight prefetch instead of duplicating the request", async () => {
      const store = createDataStore();

      // A prefetch whose response we control: it stays on the wire
      // until we resolve it, like a real slow network.
      let resolveFetch;
      axios.get.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFetch = resolve;
          }),
      );
      prefetchMonth("2030-03-15");
      await vi.waitFor(() => {
        expect(resolveFetch).toBeDefined();
      });
      expect(monthCalls("/calendar/2030-03")).toBe(1);

      // The calendar mounts while the prefetch is still in flight.
      store.goToMonth("2030-03-15");
      await new Promise((r) => setTimeout(r, 0));

      // No second request — the mount adopted the pending one.
      expect(monthCalls("/calendar/2030-03")).toBe(1);

      // When the prefetch lands, its data reaches the screen.
      resolveFetch({ status: 200, data: monthPayload(2030, 3, "adopted") });
      await vi.waitFor(() => {
        expect(store.calendarEvents.length).toBe(1);
        expect(store.calendarEvents[0].title).toBe("adopted");
      });
      expect(monthCalls("/calendar/2030-03")).toBe(1);
    });

    it("switchMonths skips revalidation for a month the prefetch fetched seconds ago", async () => {
      const store = createDataStore();

      axios.get.mockResolvedValueOnce({
        status: 200,
        data: monthPayload(2030, 5, "fresh"),
      });
      prefetchMonth("2030-05-15");
      await vi.waitFor(() => {
        expect(monthCalls("/calendar/2030-05")).toBe(1);
      });
      // Let the prefetch finish writing the cache.
      await new Promise((r) => setTimeout(r, 0));

      // The calendar mounts: instant render from cache, and no
      // revalidation fetch — the data is seconds old.
      store.goToMonth("2030-05-15");
      expect(store.calendarEvents.length).toBe(1);
      expect(store.calendarEvents[0].title).toBe("fresh");
      await new Promise((r) => setTimeout(r, 0));
      expect(monthCalls("/calendar/2030-05")).toBe(1);
    });

    it("a month cached longer ago still revalidates on switchMonths", async () => {
      const store = createDataStore();

      // Warm the cache WITHOUT marking it fresh, the state of any
      // month that was not just downloaded (e.g. warmed from
      // IndexedDB on a repeat visit).
      const key = monthCache.keyFor("test-community-id", "2030", "7");
      monthCache.set(key, monthPayload(2030, 7, "stale"));

      store.goToMonth("2030-07-15");
      expect(store.calendarEvents[0].title).toBe("stale");
      // The stale-while-revalidate fetch still fires.
      await vi.waitFor(() => {
        expect(monthCalls("/calendar/2030-07")).toBe(1);
      });
    });
  });
});
