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
  // Description save pipeline state (issue #35). Volatile: per-session
  // request bookkeeping, not data. It lives on the meal node, not the
  // DataStore, so unsaved text keeps its protection when the user
  // navigates to another meal and back.
  .volatile(() => ({
    // True from an edit until a save of that exact text returns 200.
    // While set, loadData leaves the description alone, so a reload
    // cannot silently replace unsaved typing.
    descriptionDirty: false,
    // Bumped on every edit. A save captures the value at send time; the
    // 200 clears the dirty flag only if it has not moved since — so an
    // ack for older text can never mark newer keystrokes as saved.
    descriptionEditVersion: 0,
    // True while a description request is in flight. With one request at
    // a time, this client's writes cannot reach the server out of order.
    descriptionSaveInFlight: false,
    // A save was requested while one was in flight; send one more
    // request with the latest text when it settles.
    descriptionSaveQueued: false,
    // True from a failed save until a save succeeds. Drives the
    // "not saved" marker.
    descriptionSaveFailed: false,
  }))
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
    // The "not saved" marker: there is unsaved text AND a save has
    // failed. Plain dirty is not enough — every normal save round-trip
    // passes through dirty for a moment, and flashing "not saved" during
    // healthy autosaves would teach users to ignore the marker.
    get descriptionNotSaved() {
      return self.descriptionDirty && self.descriptionSaveFailed;
    },
  }))
  .actions((self) => ({
    // The menu autosave (issue #35). A failed save used to look exactly
    // like a saved one; now the typed text is protected by the dirty
    // flag and a persistent "not saved" marker until a save really
    // lands. There is no rollback and no refetch-over-text on purpose:
    // for a checkbox, restoring server truth costs one click to redo;
    // for typed prose, it destroys work.
    setDescription(val) {
      self.description = val;
      self.descriptionDirty = true;
      self.descriptionEditVersion += 1;
      self.submitDescription();
    },
    // A keystroke's protection starts at the keystroke, not at the
    // debounced flush. Dirty keeps this node alive across a meal
    // switch, so the flush still has a live node to land on; the
    // version bump stops an in-flight ack (for older text) from
    // clearing that protection before the flush arrives.
    markDescriptionEditing() {
      self.descriptionDirty = true;
      self.descriptionEditVersion += 1;
    },
    submitDescription() {
      // Single-flight: one request at a time. The queued resend in
      // settleDescriptionSave sends whatever was typed meanwhile.
      if (self.descriptionSaveInFlight) {
        self.descriptionSaveQueued = true;
        return;
      }

      const versionAtSend = self.descriptionEditVersion;
      self.descriptionSaveInFlight = true;

      api.meals
        .updateDescription(self.id, {
          description: self.description,
          socketId: window.Comeals.socketId,
        })
        .then(function () {
          if (!isAlive(self)) return;
          self.applyDescriptionAck(versionAtSend);
        })
        .catch(function (error) {
          handleAxiosError(error);
          if (!isAlive(self)) return;
          self.markDescriptionSaveFailed();
        })
        .then(function () {
          if (!isAlive(self)) return;
          self.settleDescriptionSave();
        });
    },
    // A 200 means the network works again, so the marker can go. The
    // dirty flag clears only if no keystrokes arrived after the request
    // went out — newer text is still unsaved and keeps its protection
    // until its own resend is acked.
    applyDescriptionAck(versionAtSend) {
      self.descriptionSaveFailed = false;
      if (versionAtSend !== self.descriptionEditVersion) return;
      self.descriptionDirty = false;
    },
    markDescriptionSaveFailed() {
      self.descriptionSaveFailed = true;
    },
    settleDescriptionSave() {
      self.descriptionSaveInFlight = false;
      if (!self.descriptionSaveQueued) return;
      self.descriptionSaveQueued = false;
      self.submitDescription();
    },
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
