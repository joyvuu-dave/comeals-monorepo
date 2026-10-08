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
import toastStore from "../../../app/frontend/src/stores/toast_store";
import { SAVE_DEBOUNCE_MS } from "../../../app/frontend/src/helpers/helpers.js";
// The server's real answer for GET /meals/42/cooks, written by
// rake test:generate_fixtures from MealFormSerializer.
import mealFixture from "../../fixtures/meal.json";
// The exact words of server answers the meal page compares, among other
// things (docs/adr/0001-typescript-at-the-api-boundary.md).
import contract from "../../fixtures/api_contract.json";

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
        "These cooks have a bill but are not in the residents list, so the page does not show their bills:",
        [999],
      );
      spy.mockRestore();
    });

    // A bills save names only the cooks it changes (#135), and no row
    // names cook 999, so a save of Alice's cost is sent and cannot touch
    // cook 999's bill (#91).
    it("sends a save of another cook's cost, and it never names the cook the page cannot show", () => {
      const spy = vi.spyOn(console, "warn").mockImplementation(() => {});
      toastStore.clearAll();
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(mealWithHiddenCook(), "server");

      billFor(store, 10).setAmount("16");
      store.submitBills();

      expect(billsPatches()).toHaveLength(1);
      expect(billsPatches()[0][0].data.edits).toEqual([
        {
          op: "change",
          resident_id: 10,
          from: { amount: "15.00", no_cost: false },
          to: { amount: "16", no_cost: false },
        },
      ]);
      expect(toastStore.toasts).toEqual([]);
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

  // ── Issue #29: only edited rows carry values to the server ──

  // A save is the difference between the rows and their bases (#135),
  // so a row nobody changed is never sent (issue #29).
  describe("submitBills only-edited-rows", () => {
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

    it("sends only the cook whose cost changed", () => {
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(
        mealPayload({
          residents: [residentRow(10, "Alice"), residentRow(11, "Bob")],
          bills: [
            { resident_id: 10, amount: "12.34", no_cost: false },
            { resident_id: 11, amount: "0.0", no_cost: false },
          ],
        }),
        "server",
      );

      billFor(store, 11).setAmount("5.00"); // triggers the debounced saveBills
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);

      const calls = billsPatchCalls();
      expect(calls.length).toBe(1);
      expect(calls[0][0].data.edits).toEqual([
        {
          op: "change",
          resident_id: 11,
          from: { amount: "", no_cost: false },
          to: { amount: "5.00", no_cost: false },
        },
      ]);
    });

    // A legacy sub-cent amount (data older than the whole-cents CHECK)
    // displays exactly as stored and must never leave the client: that
    // is the write-back that used to silently rewrite the ledger. Its
    // text breaks the whole-cents grammar, and it still must not block a
    // save of another cook.
    it("never sends a stored amount nobody changed, and an amount like that does not block the save", () => {
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(
        mealPayload({
          residents: [residentRow(10, "Alice"), residentRow(11, "Bob")],
          bills: [
            { resident_id: 10, amount: "12.345", no_cost: false },
            { resident_id: 11, amount: "0.0", no_cost: false },
          ],
        }),
        "server",
      );
      expect(billFor(store, 10).amount).toBe("12.345"); // exact wire string, no float

      billFor(store, 11).setAmount("5.00");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);

      expect(billsPatchCalls()).toHaveLength(1);
      expect(
        billsPatchCalls()[0][0].data.edits.map((edit) => edit.resident_id),
      ).toEqual([11]);
    });

    it("blocks the save when a changed row's amount is not whole cents", () => {
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
      // The row as loadData leaves it: the server has its bill, so
      // leaving the meal has no edit to send.
      store.bills.get("b1").setBaseToShown();
      store.teardownMealPage();

      expect(() => store.submitBills()).not.toThrow();
      expect(
        axios.mock.calls.filter(([c]) => c && c.method === "patch").length,
      ).toBe(0);
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

    // A change of one cook's amount, as a save sends it.
    function change(residentId, from, to) {
      return {
        op: "change",
        resident_id: residentId,
        from: { amount: from, no_cost: false },
        to: { amount: to, no_cost: false },
      };
    }

    // The amounts each bills save for a meal sent, oldest first: one list
    // per save.
    function amountsSent(mealId = 1) {
      return billsPatchCalls(mealId).map(([config]) =>
        config.data.edits.map((edit) => edit.to.amount),
      );
    }

    // The URL of every bills save, in the order they were sent.
    function billsPatchUrls() {
      return axios.mock.calls
        .filter(([config]) => config && config.method === "patch")
        .map(([config]) => config.url);
    }

    // The server's answer for a meal after meal 1, on the next day. Bob
    // cooks it too, for $7.
    function laterMealPayload(id) {
      return mealPayload({
        id,
        date: `2023-06-${15 + id - 1}`,
        residents: [residentRow(11, "Bob", { meal_id: id })],
        bills: [{ resident_id: 11, amount: "7.0", no_cost: false }],
      });
    }

    // Answer every meal fetch with that meal's payload: meal 1 as
    // storeWithCookBill loaded it, any other meal from laterMealPayload.
    function answerMealFetches() {
      axios.get.mockImplementation((url) => {
        const id = Number(url.match(/meals\/(\d+)\/cooks/)[1]);
        return Promise.resolve({
          status: 200,
          data:
            id === 1
              ? mealPayload({
                  residents: [residentRow(11, "Bob")],
                  bills: [{ resident_id: 11, amount: "0.0", no_cost: false }],
                })
              : laterMealPayload(id),
        });
      });
    }

    // Bob's $5 save is sent, and the server does not answer it until
    // the test says so. Then $50 is typed, and its save waits for that
    // answer. Returns the function that answers the first save.
    function queueAnEditBehindASave(store) {
      let resolveFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          }),
      );
      bobsBill(store).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // request 1 in flight
      bobsBill(store).setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits for request 1
      return (response) => resolveFirst(response);
    }

    // The words a person sees when a save for meal 1 (Thu, Jun 15th)
    // fails after they left that meal (#107).
    const MEAL_1_SETTLED =
      "The cooks and costs you entered for Thu, Jun 15th were not saved, because that meal has already been settled.";
    const MEAL_1_NOT_SAVED =
      "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.";
    // The words when the second try of the save for meal 1 got no answer
    // from the app (no answer, or a 5xx page with no message) after the
    // person left it, so it may have been written (#137).
    const MEAL_1_MAYBE =
      "The cooks and costs you entered for Thu, Jun 15th may not have been saved. Please open that meal and check them.";
    // The words a person sees when the second try of a save for the meal
    // on screen got no answer from the app (no answer, or a 5xx page with
    // no message), so it may have been written.
    const MAYBE_NOT_SAVED =
      "Your cooks and costs may not have been saved. Check them when the meal shows again.";

    // The server's exact answer to a write to a settled meal
    // (reconciled_rejection in app/controllers/api/v1/meals_controller.rb).
    // Only these words tell that refusal apart from the other 400s. They
    // are read from the contract file, which
    // spec/requests/api/v1/update_bills_spec.rb checks against the
    // server.
    const SETTLED_WORDS = contract.messages.reconciled_rejection;

    // The words of a stale 409: Bob's $0 changed on the server after the
    // page loaded the meal (#135).
    const STALE_WORDS =
      "Nothing was saved, because this meal changed after you loaded it: Bob's cost changed. Check the cooks and costs, then enter your change again.";

    // The ways a bills save can fail, with the words the person sees
    // for each: when the save is for the meal on screen, and when the
    // save is for meal 1 and the person has left it. Last, how many
    // times the save is sent: a failure that may not be final is sent
    // once more, and the words show only when that fails too (decision
    // 7 of #135).
    const SAVE_FAILURES = [
      [
        "the server refuses it because the meal was settled (400)",
        { response: { status: 400, data: { message: SETTLED_WORDS } } },
        SETTLED_WORDS,
        MEAL_1_SETTLED,
        1,
      ],
      [
        "the server refuses it for another reason (400)",
        {
          response: {
            status: 400,
            data: { message: "Invalid cook assignment." },
          },
        },
        "Invalid cook assignment.",
        MEAL_1_NOT_SAVED,
        1,
      ],
      [
        "the server refuses it because the bills changed after the page loaded the meal (409, stale)",
        {
          response: {
            status: 409,
            data: { message: STALE_WORDS, type: "stale", bills: [] },
          },
        },
        STALE_WORDS,
        MEAL_1_NOT_SAVED,
        1,
      ],
      [
        "the server refuses it because another write changed the meal at the same time (409)",
        {
          response: {
            status: 409,
            data: {
              message:
                "Someone else was changing this meal at the same time. Nothing was saved. Try again.",
            },
          },
        },
        "Someone else was changing this meal at the same time. Nothing was saved. Try again.",
        MEAL_1_NOT_SAVED,
        2,
      ],
      [
        "the server fails with its 500 page",
        {
          response: {
            status: 500,
            data: "<!doctype html><html><head><title>We're sorry, but something went wrong (500)</title></head></html>",
          },
        },
        MAYBE_NOT_SAVED,
        MEAL_1_MAYBE,
        2,
      ],
      [
        "the server never answers (no network)",
        { request: {} },
        MAYBE_NOT_SAVED,
        MEAL_1_MAYBE,
        2,
      ],
      [
        "the request is never sent",
        new Error("Network Error"),
        MAYBE_NOT_SAVED,
        MEAL_1_MAYBE,
        2,
      ],
    ];
    // Shorter names for the rows the tests below use one at a time. The
    // tests about which meals the message names use final failures, so
    // each failure is one request.
    const SETTLED = SAVE_FAILURES[0][1];
    const STALE = SAVE_FAILURES[2][1];
    const NO_NETWORK = SAVE_FAILURES[5][1];

    // The next `tries` bills saves fail with this error.
    function failNextSaves(error, tries) {
      for (let i = 0; i < tries; i += 1) axios.mockRejectedValueOnce(error);
    }

    // The two warnings the server can give when it saves the cooks
    // (ThirdCookWarning). The answer is a 400, so axios rejects with it.
    const THIRD_COOK_ADDED =
      "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.";
    const THIRD_COOK_SWITCHED =
      "Warning: third cook should not be switched when there are other meals in the rotation without at least two cooks.";
    function savedWithWarning(message) {
      return { response: { status: 400, data: { type: "warning", message } } };
    }

    // The messages on screen, as [type, words].
    function toastsOnScreen() {
      return toastStore.toasts.map((t) => [t.type, t.message]);
    }

    // The words when the saves for meals 1 and 2 (Thu and Fri) were not
    // saved.
    const MEALS_1_AND_2_NOT_SAVED =
      "The cooks and costs you entered for Thu, Jun 15th and Fri, Jun 16th were not saved. Please open those meals and enter them again.";

    // The person leaves meal 1 with $50 waiting behind the $5 save,
    // types $8 on meal 2, and leaves meal 2 for meal 3 before the $5
    // save is answered. Then the $5 save works, and the server answers
    // meal 1's $50 save and meal 2's $8 save with these errors.
    async function leaveMeals1And2(store, meal1Error, meal2Error) {
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);
      axios.mockRejectedValueOnce(meal1Error);
      axios.mockRejectedValueOnce(meal2Error);

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      bobsBill(store).setAmount("8");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits for meal 1's save
      store.switchMeals(3);
      await vi.advanceTimersByTimeAsync(0);
      toastStore.clearAll();
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      expect(billsPatchUrls()).toEqual([
        "/api/v1/meals/1/bills",
        "/api/v1/meals/1/bills",
        "/api/v1/meals/2/bills",
      ]);
    }

    // The person opens meal `mealId`, types `amount` as Bob's cost, and
    // leaves for meal `nextMealId` while that save waits for the server.
    // Returns the save's resolve and reject.
    async function leaveWithASaveInFlight(store, mealId, amount, nextMealId) {
      let answer;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve, reject) => {
            answer = { resolve, reject };
          }),
      );
      store.switchMeals(mealId);
      await vi.advanceTimersByTimeAsync(0); // the meal's rows load
      bobsBill(store).setAmount(amount);
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // its save is in flight
      store.switchMeals(nextMealId);
      await vi.advanceTimersByTimeAsync(0);
      return answer;
    }

    // The person opens meal `mealId` and types `amount` as Bob's cost,
    // and the server saves it.
    async function saveOnScreen(store, mealId, amount) {
      store.switchMeals(mealId);
      await vi.advanceTimersByTimeAsync(0); // the meal's rows load
      bobsBill(store).setAmount(amount);
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0); // the server saves it
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
      expect(flushed[0][0].data.edits).toEqual([change(11, "", "99.00")]);

      // The old rows left with meal 1, so nothing remains that could be
      // edited — or sent — against meal 2 while it loads. A probe on
      // 2026-07-22 showed a keystroke in this window sending meal 1's
      // cook list to meal 2, which the server then took as the complete
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
      expect(calls[0][0].data.edits).toEqual([change(11, "", "50")]);
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

      // The first request settles; the queued save sends what changed
      // since the first was built.
      resolveFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      const calls = billsPatchCalls();
      expect(calls.length).toBe(2);
      expect(calls[1][0].data.edits).toEqual([change(11, "5", "50")]);
    });

    // The answer holds every bill the meal has. The check looks only at
    // the cooks the save named (bills_save.test.js has the rest), so a
    // cook the page does not show is fine: no message, and no fetch.
    it("takes an answer that also holds a cook who is not on screen", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);
      toastStore.clearAll();
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [
            { resident_id: 99, amount: "7.00", no_cost: false },
            { resident_id: 11, amount: "5.5", no_cost: false },
          ],
        },
      });

      bill.setAmount("5.50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      axios.get.mockClear();
      await vi.advanceTimersByTimeAsync(0);

      expect(bill.amount).toBe("5.50");
      expect(bill.unsent).toBe(false);
      expect(toastStore.toasts).toEqual([]);
      expect(axios.get).not.toHaveBeenCalled();
    });

    // Regression from issue #30's fix. Typing "1", pausing past the
    // debounce, then typing "0" used to fail: the answer rewrote the
    // field to "1.00" under the cursor, so the next keystroke made
    // "1.000" — three decimals, which the whole-cents grammar refuses.
    // The "0" was swallowed. The answer changes no row now (#135), so
    // the typed string stays.
    it("keeps the typed string when the answer differs only in formatting, so typing can continue", async () => {
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

      // Same number: keep the user's string. The row is still what the
      // server has, so it needs no resend.
      expect(bill.amount).toBe("1");
      expect(bill.unsent).toBe(false);

      // The slow "0" keystroke lands: "1" then "0" makes "10".
      expect(bill.setAmount("10")).toBe("10");
      expect(bill.amount).toBe("10");
    });

    // The counterpart of the rule above: the field pads itself when the
    // user leaves it, so "1" still ends up shown as "1.00", and the
    // padding is not an edit to send.
    it("pads the display on blur without marking the row for a resend", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("1");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // the save is sent
      await vi.advanceTimersByTimeAsync(0); // and answered

      bill.normalizeAmountDisplay(); // what the input's onBlur calls
      expect(bill.amount).toBe("1.00");
      expect(bill.unsent).toBe(false);
      store.flushPendingBillsSave();
      expect(billsPatchCalls().length).toBe(1);

      // A typed zero means "not filled in yet" and shows as blank — the
      // same mapping loadData uses, so blur and reload agree.
      bill.setAmount("0");
      bill.normalizeAmountDisplay();
      expect(bill.amount).toBe("");
    });

    it("keeps a cost typed after the request was sent, and sends it next as a change from what was sent", async () => {
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

      // The answer does not erase the newer keystroke.
      expect(bill.amount).toBe("50");
      expect(bill.unsent).toBe(true);

      // The debounced save then sends the newer value.
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      const calls = billsPatchCalls();
      expect(calls.length).toBe(2);
      expect(calls[1][0].data.edits).toEqual([change(11, "5", "50")]);
    });

    it("flushes a pending save immediately on demand (blur) and consumes the timer", () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      bill.setAmount("5");
      store.flushPendingBillsSave(); // what the inputs' onBlur calls

      const calls = billsPatchCalls();
      expect(calls.length).toBe(1);
      expect(calls[0][0].data.edits).toEqual([change(11, "", "5")]);

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

    // Issue #107. The queued save is built from meal 1's rows before the
    // switch clears them, and it goes to meal 1, never to meal 2. Its
    // answer is about meal 1, and it arrives while meal 2's rows are on
    // screen, so it must not change them.
    it("sends a queued save to its own meal after the user switches meals, and its answer does not change the new meal's rows", async () => {
      const store = storeWithCookBill();
      const bill = bobsBill(store);

      let resolveFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          }),
      );
      let resolveSecond;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveSecond = resolve;
          }),
      );
      answerMealFetches(); // Bob cooks meal 2 too, for $7

      bill.setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // request 1 in flight
      bill.setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // queued behind request 1

      store.switchMeals(2); // leave the meal
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      expect(bobsBill(store).amount).toBe("7.00");

      resolveFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      const calls = billsPatchCalls(1);
      expect(calls.length).toBe(2);
      expect(calls[1][0].data.edits).toEqual([change(11, "5", "50")]);
      expect(billsPatchCalls(2).length).toBe(0);

      // Meal 1's answer: the server stored $50 for Bob on meal 1.
      resolveSecond({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 11, amount: "50.0", no_cost: false }],
        },
      });
      await vi.advanceTimersByTimeAsync(0);

      expect(bobsBill(store).amount).toBe("7.00");
      expect(bobsBill(store).unsent).toBe(false);
      expect(billsPatchCalls(2).length).toBe(0);
    });

    // Issue #107: an edit typed while a save is in flight is sent to the
    // meal it was typed on, whichever way the person leaves that meal.
    // Before the fix it was never sent, so the server kept the old
    // amount and no message showed (issue #30's failure).
    it.each([
      [
        "its debounce fires, then the user switches meals",
        (store) => {
          vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
          store.switchMeals(2);
        },
      ],
      [
        "the field blurs, then the user switches meals",
        (store) => {
          store.flushPendingBillsSave();
          store.switchMeals(2);
        },
      ],
      ["the user leaves the meal page", (store) => store.teardownMealPage()],
    ])(
      "an edit made while a save is in flight still reaches its meal when %s",
      async (_label, leave) => {
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
        bill.setAmount("50"); // typed before request 1 is answered

        leave(store);
        resolveFirst({ status: 200, data: {} });
        await vi.advanceTimersByTimeAsync(0);

        const calls = billsPatchCalls(1);
        expect(calls.length).toBe(2);
        expect(calls[1][0].data.edits).toEqual([change(11, "5", "50")]);
        expect(billsPatchCalls(2).length).toBe(0);
      },
    );

    // An edit on the new meal can be waiting for the answer to a save
    // for the meal the person left. It was typed on the meal on screen,
    // so it goes there when that save is answered. Before #107's fix,
    // the answer to meal 1's save dropped it because the meal on screen
    // had changed.
    it("sends an edit typed on the new meal while the old meal's save is in flight to the new meal", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      let resolveFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          }),
      );

      bobsBill(store).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // meal 1's save in flight
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load

      bobsBill(store).setAmount("8");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits for meal 1's save
      expect(billsPatchCalls(2).length).toBe(0);

      resolveFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      expect(billsPatchUrls()).toEqual([
        "/api/v1/meals/1/bills",
        "/api/v1/meals/2/bills",
      ]);
      expect(billsPatchCalls(2)[0][0].data.edits).toEqual([
        change(11, "7.00", "8"),
      ]);
    });

    // The person leaves meal 1 with an edit waiting, types on meal 2
    // while meal 1's save still has no answer, and leaves meal 2 too.
    // Each waiting save goes to the meal it was typed on, one request at
    // a time, oldest first.
    it("sends the waiting saves of two meals left in a row one at a time, oldest first", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);
      let resolveSecond;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveSecond = resolve;
          }),
      );

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      bobsBill(store).setAmount("8");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits too
      store.switchMeals(3);
      await vi.advanceTimersByTimeAsync(0);
      expect(billsPatchUrls()).toEqual(["/api/v1/meals/1/bills"]);

      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);
      // Meal 1's waiting save is sent; meal 2's still waits.
      expect(billsPatchUrls()).toEqual([
        "/api/v1/meals/1/bills",
        "/api/v1/meals/1/bills",
      ]);
      expect(billsPatchCalls(1)[1][0].data.edits).toEqual([
        change(11, "5", "50"),
      ]);

      resolveSecond({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);
      expect(billsPatchUrls()).toEqual([
        "/api/v1/meals/1/bills",
        "/api/v1/meals/1/bills",
        "/api/v1/meals/2/bills",
      ]);
      expect(billsPatchCalls(2)[0][0].data.edits).toEqual([
        change(11, "7.00", "8"),
      ]);
      expect(billsPatchCalls(3).length).toBe(0);
    });

    // The person leaves meal 1 with $50 waiting behind the $5 save, and
    // comes back before either is answered. Meal 1's rows do not load
    // until both are answered (#136), so a cost typed after that is
    // sent after them. If a $60 save went before the $50 save, the
    // server would keep $50.
    it("loads a meal the person comes back to only once its saves are answered, so a newer edit is sent after them", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      store.switchMeals(1);
      await vi.advanceTimersByTimeAsync(0);
      expect(store.bills.size).toBe(0);

      // The $50 save is sent and works, then meal 1's rows load.
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);
      bobsBill(store).setAmount("60");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);

      expect(amountsSent(1)).toEqual([["5"], ["50"], ["60"]]);
      expect(billsPatchCalls(2).length).toBe(0);
    });

    // #91: the meal has a bill the page does not show. A save names only
    // the cooks it changes, so the save built when the person leaves the
    // meal is sent, and it never names that cook (#135).
    it("sends the save for the meal being left even when that meal has a bill the page does not show", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      const store = createDataStore({ mealProps: { closed: false } });
      answerMealFetches();
      toastStore.clearAll();
      store.loadData(
        mealPayload({
          residents: [residentRow(11, "Bob")],
          bills: [
            { resident_id: 11, amount: "0.0", no_cost: false },
            { resident_id: 999, amount: "40", no_cost: false },
          ],
        }),
        "server",
      );
      bobsBill(store).setAmount("50"); // in the wait before its save

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load

      expect(billsPatchUrls()).toEqual(["/api/v1/meals/1/bills"]);
      expect(billsPatchCalls(1)[0][0].data.edits).toEqual([
        change(11, "", "50"),
      ]);
      expect(toastsOnScreen()).toEqual([]);
      warn.mockRestore();
    });

    // The person is on meal 2 when the waiting save for meal 1 fails,
    // so the message names meal 1 by its day, the way the date box
    // shows it. It says the meal was settled when the server says so,
    // and otherwise asks the person to enter the costs again.
    it.each(SAVE_FAILURES)(
      "names the meal by its day when the waiting save for a meal the person left fails: %s",
      async (_label, error, _wordsOnScreen, wordsAfterLeaving, tries) => {
        const store = storeWithCookBill();
        answerMealFetches();
        const answerFirst = queueAnEditBehindASave(store);
        failNextSaves(error, tries);

        store.switchMeals(2);
        toastStore.clearAll();
        answerFirst({ status: 200, data: {} });
        await vi.advanceTimersByTimeAsync(0);

        expect(billsPatchCalls(1).length).toBe(1 + tries);
        expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
          ["error", wordsAfterLeaving],
        ]);
      },
    );

    // The rule is about the meal on screen, not about which save it
    // was: a save sent before the person left is named the same way
    // when it fails. Here the person is on the calendar.
    it("names the meal by its day when its save was sent before the person left the meal page, and then fails", async () => {
      const store = storeWithCookBill();
      let rejectFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectFirst = reject;
          }),
      );

      bobsBill(store).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      store.teardownMealPage();
      toastStore.clearAll();
      rejectFirst(STALE);
      await vi.advanceTimersByTimeAsync(0);

      expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
        ["error", MEAL_1_NOT_SAVED],
      ]);
    });

    // A save for a later meal fails the same way, named by its own day.
    it("names the later meal by its own day when its waiting save fails", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      const answerFirst = queueAnEditBehindASave(store);
      axios.mockRejectedValueOnce(SETTLED);

      store.teardownMealPage();
      toastStore.clearAll();
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      expect(billsPatchCalls(2).length).toBe(2);
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "The cooks and costs you entered for Fri, Jun 16th were not saved, because that meal has already been settled.",
      ]);
    });

    // When a second meal the person left fails while the message about
    // the first still shows, one message names both, so every meal that
    // was not saved is in one place. It uses the general words even
    // though one meal was settled: they are true of both meals.
    it("names every meal the person left in one message when a second fails while the first message still shows", async () => {
      const store = storeWithCookBill();
      await leaveMeals1And2(store, STALE, SETTLED);

      expect(toastsOnScreen()).toEqual([["error", MEALS_1_AND_2_NOT_SAVED]]);
    });

    // A meal that fails again while the message shows keeps its place
    // in it, so the meals stay in the order they first failed.
    it("keeps a meal's place in the message when it fails again", async () => {
      const store = storeWithCookBill();
      await leaveMeals1And2(store, STALE, STALE);

      const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
      meal1Save.reject(STALE);
      await vi.advanceTimersByTimeAsync(0);

      expect(billsPatchCalls(1).length).toBe(3);
      expect(toastsOnScreen()).toEqual([["error", MEALS_1_AND_2_NOT_SAVED]]);
    });

    // Once the server said a meal was settled, the message keeps saying
    // so when a later save for that meal fails for another reason. A
    // 409 or a lost network does not mean the meal is open again.
    it.each([
      ["was settled, then failed for another reason", SETTLED, STALE],
      ["failed, then was settled", STALE, SETTLED],
    ])(
      "says a meal the person left was settled when it %s",
      async (_label, firstError, secondError) => {
        const store = storeWithCookBill();
        answerMealFetches();
        const answerFirst = queueAnEditBehindASave(store);
        axios.mockRejectedValueOnce(firstError); // the $50 save
        store.switchMeals(2);
        await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
        toastStore.clearAll();
        answerFirst({ status: 200, data: {} });
        await vi.advanceTimersByTimeAsync(0);

        const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
        meal1Save.reject(secondError);
        await vi.advanceTimersByTimeAsync(0);

        expect(billsPatchCalls(1).length).toBe(3);
        expect(toastsOnScreen()).toEqual([["error", MEAL_1_SETTLED]]);
      },
    );

    // Meal 1 fails, then a save for meal 2 is in flight when the person
    // leaves meal 2 too. What happens to the message about meal 1 before
    // meal 2's save fails decides what the message then says.
    async function failMeal1ThenLeaveMeal2(store) {
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);
      axios.mockRejectedValueOnce(STALE); // meal 1's $50 save
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      toastStore.clearAll();
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        MEAL_1_NOT_SAVED,
      ]);

      let rejectMeal2;
      axios.mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectMeal2 = reject;
          }),
      );
      bobsBill(store).setAmount("8");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // meal 2's save in flight
      store.switchMeals(3);
      await vi.advanceTimersByTimeAsync(0);
      return rejectMeal2;
    }

    // One outage fails the waiting save for meal 1 and then, right after
    // it, the save for the meal on screen, meal 2. Each is sent twice
    // (decision 7 of #135), one after the other. The message still names
    // meal 1, and the words about meal 2 go on top of it (#137). Meal
    // 2's second try got no answer, so it may have been written, and
    // its words say so.
    it("still names a meal the person left when the save for the meal on screen fails right after it", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);
      failNextSaves(NO_NETWORK, 2); // meal 1's $50 save
      failNextSaves(NO_NETWORK, 2); // meal 2's $8 save
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      bobsBill(store).setAmount("8");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits for the $5 save
      toastStore.clearAll();
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      expect(billsPatchUrls()).toEqual([
        "/api/v1/meals/1/bills",
        "/api/v1/meals/1/bills",
        "/api/v1/meals/1/bills",
        "/api/v1/meals/2/bills",
        "/api/v1/meals/2/bills",
      ]);
      expect(toastsOnScreen()).toEqual([
        ["error", MAYBE_NOT_SAVED],
        ["error", MEAL_1_MAYBE],
      ]);
    });

    // Only the person can close the message: it is an error (#137).
    it("names only the new meal when the person closed the message about the first meal", async () => {
      const store = storeWithCookBill();
      const rejectMeal2 = await failMeal1ThenLeaveMeal2(store);

      toastStore.remove(toastStore.toasts[0].id);
      rejectMeal2(STALE);
      await vi.advanceTimersByTimeAsync(0);

      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "The cooks and costs you entered for Fri, Jun 16th were not saved. Please open that meal and enter them again.",
      ]);
    });

    // A save that works later does not change the message or close it
    // (see billsNotSaved in data_store_bills.ts). Here meals 1 and 2
    // were not saved, and the person opens meal 1 again and saves it.
    // The message still names both meals, and when meal 3 then fails,
    // it names all three.
    it("does not change the message when the person opens a meal it names again and a save for that meal works", async () => {
      const store = storeWithCookBill();
      await leaveMeals1And2(store, STALE, SETTLED);
      expect(toastsOnScreen()).toEqual([["error", MEALS_1_AND_2_NOT_SAVED]]);

      await saveOnScreen(store, 1, "50");
      expect(billsPatchCalls(1).length).toBe(3);
      expect(toastsOnScreen()).toEqual([["error", MEALS_1_AND_2_NOT_SAVED]]);

      const meal3Save = await leaveWithASaveInFlight(store, 3, "9", 2);
      meal3Save.reject(STALE);
      await vi.advanceTimersByTimeAsync(0);

      expect(toastsOnScreen()).toEqual([
        [
          "error",
          "The cooks and costs you entered for Thu, Jun 15th and Fri, Jun 16th and Sat, Jun 17th were not saved. Please open those meals and enter them again.",
        ],
      ]);
    });

    // The $5 save fails after the person left, while the $50 save for
    // the same meal waits behind it. The message shows as soon as the
    // $5 save fails, and it stays when the $50 save works.
    it("names the meal when a save for it fails after the person left, and keeps the message when a newer save for that meal works", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      let rejectFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectFirst = reject;
          }),
      );
      let resolveSecond;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveSecond = resolve;
          }),
      );
      bobsBill(store).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // the $5 save is in flight
      bobsBill(store).setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // the $50 save waits
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      toastStore.clearAll();

      rejectFirst(STALE);
      await vi.advanceTimersByTimeAsync(0); // the $50 save is sent
      expect(amountsSent(1)).toEqual([["5"], ["50"]]);
      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
      expect(console.error).toHaveBeenCalledWith(STALE.response.data.message);

      resolveSecond({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);
      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
    });

    // Meal 1 with two cooks, Bob and Carol, both at $0. The next two
    // tests show why a newer save for a meal that works cannot take the
    // meal off the message: the newer save may not hold the cost that
    // was lost.
    function storeWithTwoCooks() {
      const twoCooks = () =>
        mealPayload({
          residents: [residentRow(11, "Bob"), residentRow(12, "Carol")],
          bills: [
            { resident_id: 11, amount: "0.0", no_cost: false },
            { resident_id: 12, amount: "0.0", no_cost: false },
          ],
        });
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(twoCooks(), "server");
      axios.get.mockImplementation((url) => {
        const id = Number(url.match(/meals\/(\d+)\/cooks/)[1]);
        return Promise.resolve({
          status: 200,
          data: id === 1 ? twoCooks() : laterMealPayload(id),
        });
      });
      return store;
    }

    // Bob's $5 save fails after the person left meal 1. They come back,
    // and the rows load from the server, which never stored the $5, so
    // Bob shows $0. They type $10 for Carol, and that save works. It
    // names only Carol, so it does not hold Bob's $5, and the message
    // about meal 1 stays.
    it("names the meal when the newer save that works for it holds only another cook's cost", async () => {
      const store = storeWithTwoCooks();
      let rejectFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectFirst = reject;
          }),
      );

      billFor(store, 11).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // Bob's $5 is in flight
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0);
      toastStore.clearAll();
      rejectFirst(STALE);
      await vi.advanceTimersByTimeAsync(0);
      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);

      store.switchMeals(1);
      await vi.advanceTimersByTimeAsync(0); // meal 1's rows load again
      expect(billFor(store, 11).amount).toBe("");
      billFor(store, 12).setAmount("10");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      await vi.advanceTimersByTimeAsync(0); // Carol's save is sent and works

      expect(billsPatchCalls(1)[1][0].data.edits).toEqual([
        change(12, "", "10"),
      ]);
      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
    });

    // A push on the meal's channel while Bob's $5 save is in flight does
    // not load the rows again (#136), so Bob's row keeps its $5. The
    // person types $10 for Carol and leaves. The save made on leaving is
    // built on the $5 save, so it sends only Carol's $10 (#135). The $5
    // save is refused, and nothing sends it again: saves are never
    // joined (decision 7 of #135). The $10 save works, and the message
    // about meal 1 still shows (see billsNotSaved in
    // data_store_bills.ts).
    it("keeps a cost in flight on its row when a push comes, and the save made on leaving sends only what changed after it", async () => {
      const store = storeWithTwoCooks();
      let rejectFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectFirst = reject;
          }),
      );

      billFor(store, 11).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // Bob's $5 is in flight
      store.loadDataAsync(); // what a push on the meal's channel does
      await vi.advanceTimersByTimeAsync(0);
      expect(billFor(store, 11).amount).toBe("5");
      billFor(store, 12).setAmount("10");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits for the $5 save
      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0);
      toastStore.clearAll();

      rejectFirst(STALE);
      await vi.advanceTimersByTimeAsync(0); // the save made on leaving works

      expect(billsPatchCalls(1)[1][0].data.edits).toEqual([
        change(12, "", "10"),
      ]);
      expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
    });

    // A save that comes back with a warning was saved, and like any save
    // that works, it does not take its meal off the message. The warning
    // shows on top of it.
    it("does not take a meal off the message when a later save for that meal is saved with a warning", async () => {
      const store = storeWithCookBill();
      await leaveMeals1And2(store, STALE, SETTLED);

      const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
      meal1Save.reject(savedWithWarning(THIRD_COOK_ADDED));
      await vi.advanceTimersByTimeAsync(0);

      expect(toastsOnScreen()).toEqual([
        ["info", `Cooks saved for Thu, Jun 15th. ${THIRD_COOK_ADDED}`],
        ["error", MEALS_1_AND_2_NOT_SAVED],
      ]);
    });

    // Two saves for meal 1 fail after the person left it: the $5 save
    // in flight, then the $50 save waiting behind it. The message names
    // meal 1 once.
    it("names a meal once when two of its saves fail", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      let rejectFirst;
      axios.mockImplementationOnce(
        () =>
          new Promise((_resolve, reject) => {
            rejectFirst = reject;
          }),
      );
      axios.mockRejectedValueOnce(STALE); // the $50 save
      bobsBill(store).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // the $5 save is in flight
      bobsBill(store).setAmount("50");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // the $50 save waits

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      toastStore.clearAll();
      rejectFirst(STALE);
      await vi.advanceTimersByTimeAsync(0);

      expect(amountsSent(1)).toEqual([["5"], ["50"]]);
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        MEAL_1_NOT_SAVED,
      ]);
    });

    // The server saved the cooks but warned about the rotation. The
    // warning is about meal 1, so it names meal 1.
    it("names the meal by its day when the waiting save for a meal the person left is saved with a warning", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);
      axios.mockRejectedValueOnce({
        response: {
          status: 400,
          data: {
            type: "warning",
            message:
              "Warning: third cooks should not be added until all meals in the rotation have at least two cooks.",
          },
        },
      });

      store.switchMeals(2);
      toastStore.clearAll();
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
        [
          "info",
          "Cooks saved for Thu, Jun 15th. Warning: third cooks should not be added until all meals in the rotation have at least two cooks.",
        ],
      ]);
    });

    // Issue #136. A failed save for a meal the person left changed
    // nothing on the meal on screen, so that meal is not fetched again.
    // A fetch rebuilds the rows from the server's answer, and that would
    // wipe a cost the person is still typing.
    it("does not fetch the meal on screen again when a save for a meal the person left fails, so a cost being typed there is kept", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      const answerFirst = queueAnEditBehindASave(store);
      axios.mockRejectedValueOnce(STALE); // meal 1's $50 save

      store.switchMeals(2);
      await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
      expect(bobsBill(store).amount).toBe("7.00");
      bobsBill(store).setAmount("8"); // the debounce has not passed yet

      axios.get.mockClear();
      answerFirst({ status: 200, data: {} });
      await vi.advanceTimersByTimeAsync(0);

      expect(billsPatchCalls(1).length).toBe(2);
      expect(bobsBill(store).amount).toBe("8");
      expect(axios.get).not.toHaveBeenCalled();

      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      expect(billsPatchCalls(2)[0][0].data.edits).toEqual([
        change(11, "7.00", "8"),
      ]);
    });

    // The other half of the rule above: a failed save for the meal on
    // screen means the rows may show what the server did not store, so
    // that meal is fetched again, frozen until it arrives.
    it("fetches the meal on screen again when its own save fails", async () => {
      const store = storeWithCookBill();
      answerMealFetches();
      axios.mockRejectedValueOnce(SETTLED); // 400, settled
      bobsBill(store).setAmount("5");
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
      axios.get.mockClear();
      await vi.advanceTimersByTimeAsync(0);

      expect(axios.get).toHaveBeenCalledTimes(1);
      expect(bobsBill(store).amount).toBe("");
      expect(bobsBill(store).unsent).toBe(false);
      expect(store.mealLoading).toBe(false);
    });

    // A message about a save for the meal still on screen does not name
    // the meal: the person can see which meal it is about.
    it.each(SAVE_FAILURES)(
      "shows words with no meal day when a save for the meal on screen fails: %s",
      async (_label, error, wordsOnScreen, _wordsAfterLeaving, tries) => {
        const store = storeWithCookBill();
        answerMealFetches();
        toastStore.clearAll();
        failNextSaves(error, tries);

        bobsBill(store).setAmount("5");
        vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
        await vi.advanceTimersByTimeAsync(0);

        expect(billsPatchCalls().length).toBe(tries);
        expect(toastStore.toasts.map((t) => [t.type, t.message])).toEqual([
          ["error", wordsOnScreen],
        ]);
      },
    );

    // #137: messages stack up, so a later message never takes the place
    // of the "not saved" message, which may be the only sign that a
    // meal's costs were lost.
    describe("when the message about a meal not saved shows (#137)", () => {
      // What the server answers a meal write that lost a race for the
      // meal's lock (MealsController#conflict_rejection).
      const MEAL_CONFLICT =
        "Someone else was changing this meal at the same time. Nothing was saved. Try again.";

      // The person left meal 1 with $50 waiting behind the $5 save, and
      // is on meal 2. The $5 save works and the $50 save is refused, so
      // the message names meal 1.
      async function meal1NotSaved(store) {
        answerMealFetches();
        const answerFirst = queueAnEditBehindASave(store);
        axios.mockRejectedValueOnce(STALE); // meal 1's $50 save
        store.switchMeals(2);
        await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
        toastStore.clearAll();
        answerFirst({ status: 200, data: {} });
        await vi.advanceTimersByTimeAsync(0);
        expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
      }

      // The test the issue asks for.
      it("still names the meal after a sign-up on the meal on screen fails", async () => {
        const store = storeWithCookBill();
        await meal1NotSaved(store);

        axios.mockRejectedValueOnce({
          response: { status: 409, data: { message: MEAL_CONFLICT } },
        });
        store.residents.get("11").toggleAttending();
        await vi.advanceTimersByTimeAsync(0);

        expect(toastsOnScreen()).toEqual([
          ["error", MEAL_CONFLICT],
          ["error", MEAL_1_NOT_SAVED],
        ]);
      });

      // The message is still on screen under the newer one, so a meal
      // that fails next joins it, and the joined message goes on top.
      it("adds the next meal that fails to it, even under a newer message, and puts it on top", async () => {
        const store = storeWithCookBill();
        await meal1NotSaved(store);
        axios.mockRejectedValueOnce({
          response: { status: 409, data: { message: MEAL_CONFLICT } },
        });
        store.residents.get("11").toggleAttending();
        await vi.advanceTimersByTimeAsync(0);

        const meal2Save = await leaveWithASaveInFlight(store, 2, "8", 3);
        meal2Save.reject(STALE);
        await vi.advanceTimersByTimeAsync(0);

        expect(toastsOnScreen()).toEqual([
          ["error", MEALS_1_AND_2_NOT_SAVED],
          ["error", MEAL_CONFLICT],
        ]);
      });

      // The person tapped "Show 1 more message" to see every message.
      // The message about meals not saved grows, and every message
      // still shows.
      it("keeps every message showing when it grows after the person showed them all", async () => {
        const store = storeWithCookBill();
        await meal1NotSaved(store);
        ["Error A", "Error B", "Error C"].forEach((words) =>
          toastStore.show(words, "error"),
        );
        toastStore.showAll();

        const meal2Save = await leaveWithASaveInFlight(store, 2, "8", 3);
        meal2Save.reject(STALE);
        await vi.advanceTimersByTimeAsync(0);

        expect(toastsOnScreen()[0]).toEqual(["error", MEALS_1_AND_2_NOT_SAVED]);
        expect(toastStore.shown).toHaveLength(4);
      });

      // A save that worked with a warning is news too. It shows on top,
      // and the message about meal 1 stays under it.
      it.each([THIRD_COOK_ADDED, THIRD_COOK_SWITCHED])(
        "shows a warning about a meal the person left on top of it: %s",
        async (warning) => {
          const store = storeWithCookBill();
          await leaveMeals1And2(store, STALE, savedWithWarning(warning));

          expect(toastsOnScreen()).toEqual([
            ["info", `Cooks saved for Fri, Jun 16th. ${warning}`],
            ["error", MEAL_1_NOT_SAVED],
          ]);
        },
      );

      it("shows a warning about the meal on screen on top of it", async () => {
        const store = storeWithCookBill();
        await meal1NotSaved(store);

        axios.mockRejectedValueOnce(savedWithWarning(THIRD_COOK_ADDED));
        bobsBill(store).setAmount("8");
        vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
        await vi.advanceTimersByTimeAsync(0);

        expect(billsPatchCalls(2).length).toBe(1);
        expect(toastsOnScreen()).toEqual([
          ["info", `Cooks saved. ${THIRD_COOK_ADDED}`],
          ["error", MEAL_1_NOT_SAVED],
        ]);
      });

      // A failed save of the meal on screen gets the words it gets on
      // its own, in its own message: the person can see which meal it
      // is about. After no answer from the app those words say the
      // costs may not have been saved, which "were not saved" could not
      // say (#135).
      it.each(SAVE_FAILURES)(
        "shows a failed save of the meal on screen in its own message: %s",
        async (_label, error, wordsOnScreen, _wordsAfterLeaving, tries) => {
          const store = storeWithCookBill();
          await meal1NotSaved(store);

          failNextSaves(error, tries);
          bobsBill(store).setAmount("8");
          vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
          await vi.advanceTimersByTimeAsync(0);

          expect(billsPatchCalls(2).length).toBe(tries);
          expect(toastsOnScreen()).toEqual([
            ["error", wordsOnScreen],
            ["error", MEAL_1_NOT_SAVED],
          ]);
        },
      );
    });

    // #137, decision 7 of #135. When the second try of a save got no
    // answer from the app, that try may have been written, so "were not
    // saved" could be false. Those meals get their own message, which
    // says the costs may not have been saved and asks the person to
    // check them. Meals that were surely not saved keep the "were not
    // saved" message. The two kinds are never in one sentence.
    describe("when a save for a meal the person left may have been written", () => {
      const MEAL_2_MAYBE =
        "The cooks and costs you entered for Fri, Jun 16th may not have been saved. Please open that meal and check them.";
      const MEALS_1_AND_2_MAYBE =
        "The cooks and costs you entered for Thu, Jun 15th and Fri, Jun 16th may not have been saved. Please open those meals and check them.";
      const MEAL_2_NOT_SAVED =
        "The cooks and costs you entered for Fri, Jun 16th were not saved. Please open that meal and enter them again.";
      // Both tries of a save got no answer.
      const NO_ANSWER = [NO_NETWORK, NO_NETWORK];

      // The stack is one object for the whole app.
      beforeEach(() => {
        toastStore.clearAll();
      });

      // Each try of a save fails with the next of these errors. With no
      // errors, the save works.
      function answerTries(errors) {
        if (errors.length === 0) {
          axios.mockResolvedValueOnce({ status: 200, data: {} });
        }
        errors.forEach((error) => axios.mockRejectedValueOnce(error));
      }

      // The person leaves meal 1 with $50 waiting behind the $5 save,
      // types $8 on meal 2, and leaves meal 2 for meal 3. Then the $5
      // save works, and the tries of the saves for meals 1 and 2 are
      // answered with these errors.
      async function leaveMeals1And2Failing(store, meal1Errors, meal2Errors) {
        answerMealFetches();
        const answerFirst = queueAnEditBehindASave(store);
        answerTries(meal1Errors);
        answerTries(meal2Errors);
        store.switchMeals(2);
        await vi.advanceTimersByTimeAsync(0); // meal 2's rows load
        bobsBill(store).setAmount("8");
        vi.advanceTimersByTime(SAVE_DEBOUNCE_MS); // waits for meal 1's save
        store.switchMeals(3);
        await vi.advanceTimersByTimeAsync(0);
        toastStore.clearAll();
        answerFirst({ status: 200, data: {} });
        await vi.advanceTimersByTimeAsync(0);
        expect(billsPatchCalls(1).length).toBe(
          1 + Math.max(1, meal1Errors.length),
        );
        expect(billsPatchCalls(2).length).toBe(Math.max(1, meal2Errors.length));
      }

      it("names every such meal in one message", async () => {
        const store = storeWithCookBill();
        await leaveMeals1And2Failing(store, NO_ANSWER, NO_ANSWER);

        expect(toastsOnScreen()).toEqual([["error", MEALS_1_AND_2_MAYBE]]);
      });

      it("keeps a meal's place in the message when a later save for it may have been written too", async () => {
        const store = storeWithCookBill();
        await leaveMeals1And2Failing(store, NO_ANSWER, NO_ANSWER);

        const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
        failNextSaves(NO_NETWORK, 1); // the second try
        meal1Save.reject(NO_NETWORK);
        await vi.advanceTimersByTimeAsync(0);

        expect(billsPatchCalls(1).length).toBe(5);
        expect(toastsOnScreen()).toEqual([["error", MEALS_1_AND_2_MAYBE]]);
      });

      it.each([
        [
          "meal 1 surely was not saved and meal 2 may have been",
          [STALE],
          NO_ANSWER,
          [
            ["error", MEAL_2_MAYBE],
            ["error", MEAL_1_NOT_SAVED],
          ],
        ],
        [
          "meal 1 may have been saved and meal 2 surely was not",
          NO_ANSWER,
          [STALE],
          [
            ["error", MEAL_2_NOT_SAVED],
            ["error", MEAL_1_MAYBE],
          ],
        ],
      ])(
        "keeps the two kinds in two messages when %s",
        async (_label, meal1Errors, meal2Errors, messages) => {
          const store = storeWithCookBill();
          await leaveMeals1And2Failing(store, meal1Errors, meal2Errors);

          expect(toastsOnScreen()).toEqual(messages);
        },
      );

      // A meal is named in one of the two messages, never in both. "Were
      // not saved" asks for more: the person enters the costs again,
      // which takes in checking them.
      it("moves a meal to the were-not-saved message when a later save for it surely was not saved", async () => {
        const store = storeWithCookBill();
        await leaveMeals1And2Failing(store, NO_ANSWER, NO_ANSWER);

        const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
        meal1Save.reject(STALE);
        await vi.advanceTimersByTimeAsync(0);

        expect(toastsOnScreen()).toEqual([
          ["error", MEAL_1_NOT_SAVED],
          ["error", MEAL_2_MAYBE],
        ]);
      });

      it("takes the may-not-have-been-saved message away when its only meal moves", async () => {
        const store = storeWithCookBill();
        await leaveMeals1And2Failing(store, NO_ANSWER, []);
        expect(toastsOnScreen()).toEqual([["error", MEAL_1_MAYBE]]);

        const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
        meal1Save.reject(STALE);
        await vi.advanceTimersByTimeAsync(0);

        expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
      });

      it("keeps a meal in the were-not-saved message when a later save for it may have been written", async () => {
        const store = storeWithCookBill();
        await leaveMeals1And2Failing(store, [STALE], []);
        expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);

        const meal1Save = await leaveWithASaveInFlight(store, 1, "60", 3);
        failNextSaves(NO_NETWORK, 1); // the second try
        meal1Save.reject(NO_NETWORK);
        await vi.advanceTimersByTimeAsync(0);

        expect(billsPatchCalls(1).length).toBe(4);
        expect(toastsOnScreen()).toEqual([["error", MEAL_1_NOT_SAVED]]);
      });

      it("names only the new meal when the person closed the message about the first", async () => {
        const store = storeWithCookBill();
        await leaveMeals1And2Failing(store, NO_ANSWER, []);
        toastStore.remove(toastStore.toasts[0].id);

        const meal2Save = await leaveWithASaveInFlight(store, 2, "9", 3);
        failNextSaves(NO_NETWORK, 1); // the second try
        meal2Save.reject(NO_NETWORK);
        await vi.advanceTimersByTimeAsync(0);

        expect(toastsOnScreen()).toEqual([["error", MEAL_2_MAYBE]]);
      });

      // The meal's own message says "Check them when the meal shows
      // again", which is about the meal on screen. Once the person
      // leaves the meal, the message names it.
      describe("when the person leaves the meal its own message is about", () => {
        // Bob's $5 save for meal 1, on screen, gets no answer twice.
        async function maybeNotSavedOnScreen(store) {
          answerMealFetches();
          failNextSaves(NO_NETWORK, 2);
          bobsBill(store).setAmount("5");
          vi.advanceTimersByTime(SAVE_DEBOUNCE_MS);
          await vi.advanceTimersByTimeAsync(0);
          expect(toastsOnScreen()[0]).toEqual(["error", MAYBE_NOT_SAVED]);
        }

        it.each([
          ["for another meal", (store) => store.switchMeals(2)],
          ["for the calendar", (store) => store.teardownMealPage()],
        ])(
          "puts the message that names the meal in its place, when the person leaves %s",
          async (_label, leave) => {
            const store = storeWithCookBill();
            await maybeNotSavedOnScreen(store);

            leave(store);
            await vi.advanceTimersByTimeAsync(0);

            expect(toastsOnScreen()).toEqual([["error", MEAL_1_MAYBE]]);
          },
        );

        it("adds the meal to the message that names other meals", async () => {
          const store = storeWithCookBill();
          await leaveMeals1And2Failing(store, [], NO_ANSWER);
          expect(toastsOnScreen()).toEqual([["error", MEAL_2_MAYBE]]);
          store.switchMeals(1);
          await vi.advanceTimersByTimeAsync(0); // meal 1's rows load
          await maybeNotSavedOnScreen(store);
          expect(toastsOnScreen()).toEqual([
            ["error", MAYBE_NOT_SAVED],
            ["error", MEAL_2_MAYBE],
          ]);

          store.switchMeals(3);
          await vi.advanceTimersByTimeAsync(0);

          expect(toastsOnScreen()).toEqual([
            [
              "error",
              "The cooks and costs you entered for Fri, Jun 16th and Thu, Jun 15th may not have been saved. Please open those meals and check them.",
            ],
          ]);
        });

        it("names nothing when the person closed the message before leaving", async () => {
          const store = storeWithCookBill();
          await maybeNotSavedOnScreen(store);
          toastStore.remove(toastStore.toasts[0].id);

          store.switchMeals(2);
          await vi.advanceTimersByTimeAsync(0);

          expect(toastsOnScreen()).toEqual([]);
        });

        it("names the meal once, when the person leaves the next meal too", async () => {
          const store = storeWithCookBill();
          await maybeNotSavedOnScreen(store);
          store.switchMeals(2);
          await vi.advanceTimersByTimeAsync(0);

          store.switchMeals(3);
          await vi.advanceTimersByTimeAsync(0);

          expect(toastsOnScreen()).toEqual([["error", MEAL_1_MAYBE]]);
        });
      });
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
