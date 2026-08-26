import { describe, it, expect, beforeEach, vi } from "vitest";

// Mock external modules before importing stores
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { createDataStore, stubAction } from "../helpers/create_data_store.js";

// The real DataStore, with saveBills stubbed: these tests assert WHEN
// the bill actions ask the store to save, not what the save pipeline
// does with it (data_store.test.js covers that). The stub also keeps
// the debounce timer out of these tests.
let saveBillsSpy;
function createStore(opts = {}) {
  const store = createDataStore(opts);
  saveBillsSpy = stubAction(store, "saveBills");
  window.Comeals.socketId = "test";
  return store;
}

describe("Bill model", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    window.Comeals = {
      socketId: "test",
      pusher: null,
      mealChannel: null,
      calendarChannel: null,
    };
  });

  // ── resident_id computed view ──

  describe("resident_id", () => {
    it("returns the resident id when a resident is assigned", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1", resident: 10, amount: "25.00" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.resident_id).toBe(10);
    });

    it("returns empty string when resident is null", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "25.00" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.resident_id).toBe("");
    });
  });

  // ── amountIsValid view ──

  describe("amountIsValid", () => {
    it("returns true for a valid positive number string", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "25.50" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });

    it("returns true for empty string (Number('') === 0)", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });

    it("returns true for zero", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "0" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });

    it("returns false for negative number", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "-5" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });

    it("returns false for NaN string", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "abc" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });

    it("returns true for a decimal number", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "12.99" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });
  });

  // ── amountIsValid grammar boundaries (issue #29: whole cents, 0–9999.99) ──

  describe("amountIsValid boundary cases", () => {
    it("rejects amounts over 9999.99 (they would overflow the DB column)", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "10000" }],
      });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });

    it("accepts the largest whole-cent amount", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "9999.99" }],
      });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });

    it("accepts very small positive decimals", () => {
      const store = createStore({ bills: [{ id: "bill-1", amount: "0.01" }] });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });

    it("accepts a single decimal digit", () => {
      const store = createStore({ bills: [{ id: "bill-1", amount: "12.5" }] });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(true);
    });

    it("rejects sub-cent amounts", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "12.345" }],
      });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });

    it("rejects scientific notation (the number input allows typing it)", () => {
      const store = createStore({ bills: [{ id: "bill-1", amount: "1e3" }] });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });

    it("rejects whitespace-only strings", () => {
      const store = createStore({ bills: [{ id: "bill-1", amount: "   " }] });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });

    it("rejects amounts with non-numeric suffixes", () => {
      const store = createStore({ bills: [{ id: "bill-1", amount: "25abc" }] });
      const bill = store.bills.get("bill-1");
      expect(bill.amountIsValid).toBe(false);
    });
  });

  // ── setResident action ──

  describe("setResident", () => {
    it("sets resident reference by id", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setResident(10);
      expect(bill.resident_id).toBe(10);
      expect(bill.resident.name).toBe("Alice");
    });

    it("clears resident when passed empty string", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1", resident: 10 }],
      });

      const bill = store.bills.get("bill-1");
      const result = bill.setResident("");
      expect(result).toBeNull();
      expect(bill.resident).toBeNull();
      expect(bill.resident_id).toBe("");
    });

    it("returns null when clearing, returns resident ref when setting", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1" }],
      });

      const bill = store.bills.get("bill-1");

      const setResult = bill.setResident(10);
      expect(setResult).toBeTruthy();
      expect(setResult.id).toBe(10);

      const clearResult = bill.setResident("");
      expect(clearResult).toBeNull();
    });

    it("triggers saveBills", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setResident(10);
      expect(saveBillsSpy).toHaveBeenCalledTimes(1);
    });
  });

  // ── setAmount action ──

  describe("setAmount", () => {
    it("sets amount to a string value", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      const result = bill.setAmount("42.50");
      expect(result).toBe("42.50");
      expect(bill.amount).toBe("42.50");
    });

    it("sets amount to empty string", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "25.00" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("");
      expect(bill.amount).toBe("");
    });

    it("triggers saveBills", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("10.00");
      expect(saveBillsSpy).toHaveBeenCalledTimes(1);
    });

    // Issue #29: input that breaks the whole-cents grammar does not land —
    // the amount keeps its previous value and nothing is saved.
    it("refuses a third decimal digit", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "12.34" }],
      });

      const bill = store.bills.get("bill-1");
      const result = bill.setAmount("12.345");
      expect(result).toBe("12.34");
      expect(bill.amount).toBe("12.34");
      expect(saveBillsSpy).not.toHaveBeenCalled();
    });

    it("refuses an amount over 9999.99", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "9999" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("99990");
      expect(bill.amount).toBe("9999");
      expect(saveBillsSpy).not.toHaveBeenCalled();
    });

    it("refuses scientific notation and non-numeric input", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "5" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("1e3");
      bill.setAmount("abc");
      bill.setAmount("-5");
      expect(bill.amount).toBe("5");
      expect(saveBillsSpy).not.toHaveBeenCalled();
    });
  });

  // ── touched flag (issue #29: only touched rows carry values on save) ──

  describe("touched", () => {
    it("starts false", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "25.00" }],
      });

      expect(store.bills.get("bill-1").touched).toBe(false);
    });

    it("is set by setAmount", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("10.00");
      expect(bill.touched).toBe(true);
    });

    it("is not set by a refused setAmount", () => {
      const store = createStore({
        bills: [{ id: "bill-1", amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("12.345");
      expect(bill.touched).toBe(false);
    });

    it("is set by toggleNoCost", () => {
      const store = createStore({
        bills: [{ id: "bill-1", no_cost: false }],
      });

      const bill = store.bills.get("bill-1");
      bill.toggleNoCost();
      expect(bill.touched).toBe(true);
    });

    it("is set by setResident", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setResident(10);
      expect(bill.touched).toBe(true);
    });
  });

  // ── toggleNoCost action ──

  describe("toggleNoCost", () => {
    it("toggles no_cost from false to true", () => {
      const store = createStore({
        bills: [{ id: "bill-1", no_cost: false }],
      });

      const bill = store.bills.get("bill-1");
      const result = bill.toggleNoCost();
      expect(result).toBe(true);
      expect(bill.no_cost).toBe(true);
    });

    it("toggles no_cost from true to false", () => {
      const store = createStore({
        bills: [{ id: "bill-1", no_cost: true }],
      });

      const bill = store.bills.get("bill-1");
      const result = bill.toggleNoCost();
      expect(result).toBe(false);
      expect(bill.no_cost).toBe(false);
    });

    it("triggers saveBills", () => {
      const store = createStore({
        bills: [{ id: "bill-1", no_cost: false }],
      });

      const bill = store.bills.get("bill-1");
      bill.toggleNoCost();
      expect(saveBillsSpy).toHaveBeenCalledTimes(1);
    });
  });

  // ── BUG-7: no_cost / amount contradictory state ──

  describe("no_cost auto-clear", () => {
    it("clears no_cost when a positive amount is entered (Regression test for BUG-7)", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1", resident: 10, no_cost: true, amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.no_cost).toBe(true);

      bill.setAmount("25.00");
      expect(bill.no_cost).toBe(false);
    });

    it("preserves no_cost when amount is cleared to empty", () => {
      const store = createStore({
        bills: [{ id: "bill-1", no_cost: true, amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("");
      expect(bill.no_cost).toBe(true);
    });

    it("preserves no_cost when amount is set to zero", () => {
      const store = createStore({
        bills: [{ id: "bill-1", no_cost: true, amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      bill.setAmount("0");
      expect(bill.no_cost).toBe(true);
    });

    it("clears amount when no_cost is toggled on", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [
          { id: "bill-1", resident: 10, no_cost: false, amount: "25.00" },
        ],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.amount).toBe("25.00");

      bill.toggleNoCost();
      expect(bill.no_cost).toBe(true);
      expect(bill.amount).toBe("");
    });

    it("does not clear amount when no_cost is toggled off", () => {
      const store = createStore({
        residents: [{ id: 10, meal_id: 1, name: "Alice" }],
        bills: [{ id: "bill-1", resident: 10, no_cost: true, amount: "" }],
      });

      const bill = store.bills.get("bill-1");
      expect(bill.no_cost).toBe(true);

      // Toggle off: no_cost true -> false, should not touch amount
      bill.toggleNoCost();
      expect(bill.no_cost).toBe(false);
      expect(bill.amount).toBe("");
    });
  });
});
