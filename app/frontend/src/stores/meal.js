import { types, getParent, isAlive } from "mobx-state-tree";
import { api } from "../helpers/api";
import handleAxiosError from "../helpers/handle_axios_error";

const Meal = types
  .model("Meal", {
    id: types.identifierNumber,
    description: "",
    extras: types.maybeNull(types.number),
    // True while an extras save is in flight; the checkboxes are disabled.
    extrasPending: false,
    closed: false,
    closed_at: types.maybeNull(types.Date),
    date: types.maybeNull(types.Date),
    reconciled: false,
    nextId: types.maybeNull(types.number),
    prevId: types.maybeNull(types.number),
  })
  .views((self) => ({
    get max() {
      if (self.extras === null) {
        return null;
      } else {
        return Number(self.extras) + self.form.attendeesCount;
      }
    },
    get form() {
      return getParent(self, 2);
    },
  }))
  .actions((self) => ({
    // Runs when the extras save settles — success or failure. The refetch
    // lets loadData write the server's truth over the optimistic value.
    // There is no rollback on purpose: this node is edited in place by
    // refetches, so restoring a captured value could overwrite fresh data.
    settleExtras() {
      self.extrasPending = false;
      self.form.loadDataAsync();
    },
    setExtras(val) {
      if (self.extrasPending) {
        return;
      }

      // Scenario #1: explicit null (clear extras)
      // Note: empty string falls to Scenario #2 and resolves to 0
      if (val === null) {
        self.extras = null;
        self.extrasPending = true;

        api.meals
          .updateMax(self.id, {
            max: null,
            socketId: window.Comeals.socketId,
          })
          .catch(function (error) {
            handleAxiosError(error);
          })
          .then(function () {
            if (!isAlive(self)) return;
            self.settleExtras();
          });

        return;
      }

      // Scenario #2: non-negative integer
      const num = parseInt(Number(val), 10);
      if (Number.isInteger(num) && num >= 0) {
        self.extras = num;
        self.extrasPending = true;

        api.meals
          .updateMax(self.id, {
            max: self.max,
            socketId: window.Comeals.socketId,
          })
          .catch(function (error) {
            handleAxiosError(error);
          })
          .then(function () {
            if (!isAlive(self)) return;
            self.settleExtras();
          });
      }
    },
    incrementExtras() {
      if (self.extras === null) {
        return;
      }

      const num = parseInt(Number(self.extras), 10);
      if (Number.isInteger(num)) {
        const temp = num + 1;
        self.extras = temp;
      }
    },
    decrementExtras() {
      if (self.extras === null) {
        return;
      }

      const num = parseInt(Number(self.extras), 10);
      if (Number.isInteger(num)) {
        const temp = num - 1;
        self.extras = temp;
      }
    },
  }));

export default Meal;
