import { types, getParent } from "mobx-state-tree";
import Resident from "./resident";
import { isValidAmountString, isZeroAmountString } from "../helpers/money";

const Bill = types
  .model("Bill", {
    id: types.identifier,
    resident: types.maybeNull(types.reference(Resident)),
    amount: "",
    no_cost: false,
  })
  // `touched` is volatile on purpose: it is per-session UI state, not data.
  // submitBills only sends amount/no_cost for touched rows, so a row the
  // user never edited can never overwrite the ledger. loadData clears and
  // recreates every bill node, which resets touched to false.
  .volatile(() => ({
    touched: false,
  }))
  .views((self) => ({
    get resident_id() {
      return self.resident && self.resident.id ? self.resident.id : "";
    },
    get amountIsValid() {
      return isValidAmountString(self.amount);
    },
    get form() {
      return getParent(self, 2);
    },
  }))
  .actions((self) => ({
    setResident(val) {
      self.touched = true;
      if (val === "") {
        self.resident = null;
        self.form.form.saveBills();
        return null;
      } else {
        self.resident = val;
        self.form.form.saveBills();
        return self.resident;
      }
    },
    // A keystroke that breaks the whole-cents grammar does not land: the
    // amount keeps its previous value and nothing is saved.
    setAmount(val) {
      if (!isValidAmountString(val)) {
        return self.amount;
      }
      self.amount = val;
      self.touched = true;
      if (!isZeroAmountString(val)) {
        self.no_cost = false;
      }
      self.form.form.saveBills();
      return val;
    },
    toggleNoCost() {
      const val = !self.no_cost;
      self.no_cost = val;
      self.touched = true;
      if (val) {
        self.amount = "";
      }
      self.form.form.saveBills();
      return val;
    },
  }));

export default Bill;
