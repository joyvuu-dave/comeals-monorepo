import { types, getRoot, Instance } from "mobx-state-tree";

import Resident from "./resident";
import {
  isValidAmountString,
  isZeroAmountString,
  sameAmount,
  toDisplayAmountString,
} from "../helpers/money";

// What a bill reads from the DataStore at the root of its tree. The store
// itself is still JavaScript (data_store.js), so this is the typed slice
// of it a bill depends on, and nothing more.
interface BillRoot {
  meal: { closed: boolean; reconciled: boolean } | null;
  saveBills(): void;
}

// A cook picked from the row's cook menu: a Resident node, or "" for the
// blank option.
type ResidentChoice = "" | Instance<typeof Resident>;

const Bill = types
  .model("Bill", {
    id: types.identifier,
    resident: types.maybeNull(types.reference(Resident)),
    // The wire value, a string ("12.34"): never a number, so nothing here
    // can add to it (ADR 0001). The helpers in ../helpers/money read it.
    amount: types.optional(types.string, ""),
    no_cost: types.optional(types.boolean, false),
  })
  // Volatile on purpose: per-session page state, not data. loadData
  // clears and makes every bill node again, which sets these again.
  .volatile(() => ({
    // The cook this row had when the meal was loaded, or null for a
    // blank row. The row's cook menu keeps offering this cook even after
    // someone picks another name in the row (unless another row picked
    // them), so a wrong pick can be undone for a cook no other row
    // offers: one who was retired after cooking (#91). The menu asks
    // before that pick (cooks_box.jsx). loadData sets it on every row it
    // makes, and the next load makes new rows.
    loadedCookId: null as number | null,
    // The row's base: what the server has for this row's cook, as far
    // as this page knows. loadData sets it to the values the row loaded
    // with, and building a bills save moves it to the values the save
    // sends. A bills save is the difference between the rows and their
    // bases (helpers/bill_edits.ts), so a row nobody edited is never
    // sent and can never write over the ledger. A row that differs from
    // its base holds an edit the server may not have yet (`unsent`).
    baseCookId: null as number | null,
    baseAmount: "",
    baseNoCost: false,
  }))
  // Two views blocks: MobX-State-Tree types `self` inside a block without
  // the views that block defines, so a view another view reads goes first.
  .views((self) => ({
    get resident_id(): number | "" {
      return self.resident && self.resident.id ? self.resident.id : "";
    },
    // The DataStore at the root of the tree.
    get root(): BillRoot {
      return getRoot<BillRoot>(self);
    },
  }))
  .views((self) => ({
    get amountIsValid() {
      return isValidAmountString(self.amount);
    },
    // The row differs from its base: another cook, another amount, or
    // another no_cost. While a row is unsent, the page does not build the
    // rows again from the server, because that would drop the edit
    // (#136). A row with no cook now and none at its base is never
    // unsent: a save sends only rows with a cook, so a number typed there
    // is never sent.
    get unsent() {
      const cookId = self.resident_id === "" ? null : self.resident_id;
      if (cookId === null && self.baseCookId === null) return false;
      return (
        cookId !== self.baseCookId ||
        !sameAmount(self.amount, self.baseAmount) ||
        self.no_cost !== self.baseNoCost
      );
    },
    // The cook had the chance to enter a cost — the meal closed over a
    // deliberate Yes — and hasn't yet. Shows as the word "pending" in
    // the UI. Ends at reconciliation: a reconciled blank is settled
    // history, not pending anything.
    get costPending() {
      const store = self.root;
      return (
        !!store.meal &&
        store.meal.closed &&
        !store.meal.reconciled &&
        self.resident_id !== "" &&
        self.no_cost === false &&
        isZeroAmountString(self.amount)
      );
    },
  }))
  .actions((self) => ({
    // loadData calls this once on each row it makes.
    rememberLoadedCook() {
      self.loadedCookId = self.resident_id === "" ? null : self.resident_id;
    },
    // Make what the row shows its base. loadData calls this on each row
    // it makes (the server has those values), and building a bills save
    // calls it on every row (the server will have them once that save
    // is stored).
    setBaseToShown() {
      self.baseCookId = self.resident_id === "" ? null : self.resident_id;
      self.baseAmount = self.amount;
      self.baseNoCost = self.no_cost;
    },
    setResident(val: ResidentChoice) {
      if (val === "") {
        self.resident = null;
        self.root.saveBills();
        return null;
      } else {
        self.resident = val;
        self.root.saveBills();
        return self.resident;
      }
    },
    // A keystroke that breaks the whole-cents grammar does not land: the
    // amount keeps its previous value and nothing is saved.
    setAmount(val: string) {
      if (!isValidAmountString(val)) {
        return self.amount;
      }
      self.amount = val;
      if (!isZeroAmountString(val)) {
        self.no_cost = false;
      }
      self.root.saveBills();
      return val;
    },
    // Pad the display when the user leaves the field: "1" shows as
    // "1.00", and a typed zero shows as blank (zero means "not filled
    // in yet"). The number does not change, so the row is no more unsent
    // than it was, and nothing needs to be saved.
    normalizeAmountDisplay() {
      if (isValidAmountString(self.amount)) {
        self.amount = toDisplayAmountString(self.amount);
      }
    },
    toggleNoCost() {
      const val = !self.no_cost;
      self.no_cost = val;
      if (val) {
        self.amount = "";
      }
      self.root.saveBills();
      return val;
    },
  }));

export default Bill;
