import { types, getRoot, Instance } from "mobx-state-tree";

import Resident from "./resident";
import {
  isValidAmountString,
  isZeroAmountString,
  toDisplayAmountString,
} from "../helpers/money";

// What a bill reads from the DataStore at the root of its tree. The store
// itself is still JavaScript (data_store.js), so this is the typed slice
// of it a bill depends on, and nothing more.
interface BillRoot {
  meal: { closed: boolean; reconciled: boolean } | null;
  saveBills(): void;
}

// A cook picked from the sign-up list: a Resident node, or "" for the
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
  // `touched` is volatile on purpose: it is per-session UI state, not data.
  // submitBills only sends amount/no_cost for touched rows, so a row the
  // user never edited can never overwrite the ledger. loadData clears and
  // recreates every bill node, which resets touched to false.
  .volatile(() => ({
    touched: false,
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
    setResident(val: ResidentChoice) {
      self.touched = true;
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
      self.touched = true;
      if (!isZeroAmountString(val)) {
        self.no_cost = false;
      }
      self.root.saveBills();
      return val;
    },
    // Pad the display when the user leaves the field: "1" shows as
    // "1.00", and a typed zero shows as blank (zero means "not filled
    // in yet"). The number does not change, so `touched` stays as it is
    // and nothing needs to be saved.
    normalizeAmountDisplay() {
      if (isValidAmountString(self.amount)) {
        self.amount = toDisplayAmountString(self.amount);
      }
    },
    toggleNoCost() {
      const val = !self.no_cost;
      self.no_cost = val;
      self.touched = true;
      if (val) {
        self.amount = "";
      }
      self.root.saveBills();
      return val;
    },
  }));

export default Bill;
