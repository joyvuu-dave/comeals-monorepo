import { types, getRoot, isAlive } from "mobx-state-tree";
import { api } from "../helpers/api";
import createVersionGuard from "../helpers/version_guard";
import handleAxiosError from "../helpers/handle_axios_error";

// What a meal reads from the DataStore at the root of its tree (the store
// is still JavaScript): the head count its cap is computed from, and the
// refetch that follows a settled save.
interface MealRoot {
  attendeesCount: number;
  loadDataAsync(): void;
}

const Meal = types
  .model("Meal", {
    id: types.identifierNumber,
    description: "",
    // CAREFUL: the wire field is `max` (the attendance cap); the store
    // keeps `extras` (seats left = max - attendees) and derives `max`
    // as a view, because extras is what every control renders and
    // edits. loadData converts on the way in; updateMax converts on
    // the way out. When reading, remember which side you are on.
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
    // Stale-response guard: bumped on every edit, captured at send; the
    // 200 clears the dirty flag only if nothing was typed since — so an
    // ack for older text can never mark newer keystrokes as saved.
    descriptionEdits: createVersionGuard(),
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
  // Two views blocks: MobX-State-Tree types `self` inside a block without
  // the views that block defines, so `root` goes first.
  .views((self) => ({
    // The DataStore at the root of the tree.
    get root(): MealRoot {
      return getRoot<MealRoot>(self);
    },
  }))
  .views((self) => ({
    // extras is a seat count, never money: Number() is right here.
    get max(): number | null {
      if (self.extras === null) {
        return null;
      } else {
        return Number(self.extras) + self.root.attendeesCount;
      }
    },
    // The "not saved" marker: there is unsaved text AND a save has
    // failed. Plain dirty is not enough — every normal save round-trip
    // passes through dirty for a moment, and flashing "not saved" during
    // healthy autosaves would teach users to ignore the marker.
    get descriptionNotSaved() {
      return self.descriptionDirty && self.descriptionSaveFailed;
    },
  }))
  // Local functions, returned as the actions: MobX-State-Tree types
  // `self` inside this block without the actions it defines, so an
  // action that calls another calls the function.
  .actions((self) => {
    // The menu autosave (issue #35). A failed save used to look exactly
    // like a saved one; now the typed text is protected by the dirty
    // flag and a persistent "not saved" marker until a save really
    // lands. There is no rollback and no refetch-over-text on purpose:
    // for a checkbox, restoring server truth costs one click to redo;
    // for typed prose, it destroys work.
    function setDescription(val: string) {
      self.description = val;
      self.descriptionDirty = true;
      self.descriptionEdits.bump();
      submitDescription();
    }
    // A keystroke's protection starts at the keystroke, not at the
    // debounced flush. Dirty keeps this node alive across a meal
    // switch, so the flush still has a live node to land on; the
    // version bump stops an in-flight ack (for older text) from
    // clearing that protection before the flush arrives.
    function markDescriptionEditing() {
      self.descriptionDirty = true;
      self.descriptionEdits.bump();
    }
    function submitDescription() {
      // Single-flight: one request at a time. The queued resend in
      // settleDescriptionSave sends whatever was typed meanwhile.
      if (self.descriptionSaveInFlight) {
        self.descriptionSaveQueued = true;
        return;
      }

      const versionAtSend = self.descriptionEdits.current();
      self.descriptionSaveInFlight = true;

      api.meals
        .updateDescription(self.id, {
          description: self.description,
          socketId: window.Comeals.socketId,
        })
        .then(function () {
          if (!isAlive(self)) return;
          applyDescriptionAck(versionAtSend);
        })
        .catch(function (error: unknown) {
          handleAxiosError(error);
          if (!isAlive(self)) return;
          markDescriptionSaveFailed();
        })
        .then(function () {
          if (!isAlive(self)) return;
          settleDescriptionSave();
        });
    }
    // A 200 means the network works again, so the marker can go. The
    // dirty flag clears only if no keystrokes arrived after the request
    // went out — newer text is still unsaved and keeps its protection
    // until its own resend is acked.
    function applyDescriptionAck(versionAtSend: number) {
      self.descriptionSaveFailed = false;
      if (!self.descriptionEdits.isCurrent(versionAtSend)) return;
      self.descriptionDirty = false;
    }
    function markDescriptionSaveFailed() {
      self.descriptionSaveFailed = true;
    }
    function settleDescriptionSave() {
      self.descriptionSaveInFlight = false;
      if (!self.descriptionSaveQueued) return;
      self.descriptionSaveQueued = false;
      submitDescription();
    }
    // Runs when the extras save settles — success or failure. The refetch
    // lets loadData write the server's truth over the optimistic value.
    // There is no rollback on purpose: this node is edited in place by
    // refetches, so restoring a captured value could overwrite fresh data.
    function settleExtras() {
      self.extrasPending = false;
      self.root.loadDataAsync();
    }
    // A seat count from a form control: a number, a numeric string, ""
    // (which becomes 0), or null to clear.
    function setExtras(val: number | string | null) {
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
          .catch(function (error: unknown) {
            handleAxiosError(error);
          })
          .then(function () {
            if (!isAlive(self)) return;
            settleExtras();
          });

        return;
      }

      // Scenario #2: non-negative integer
      const num = Math.trunc(Number(val));
      if (Number.isInteger(num) && num >= 0) {
        self.extras = num;
        self.extrasPending = true;

        api.meals
          .updateMax(self.id, {
            max: self.max,
            socketId: window.Comeals.socketId,
          })
          .catch(function (error: unknown) {
            handleAxiosError(error);
          })
          .then(function () {
            if (!isAlive(self)) return;
            settleExtras();
          });
      }
    }
    function incrementExtras() {
      if (self.extras === null) {
        return;
      }

      const num = Math.trunc(Number(self.extras));
      if (Number.isInteger(num)) {
        const temp = num + 1;
        self.extras = temp;
      }
    }
    function decrementExtras() {
      if (self.extras === null) {
        return;
      }

      const num = Math.trunc(Number(self.extras));
      if (Number.isInteger(num)) {
        const temp = num - 1;
        self.extras = temp;
      }
    }

    return {
      setDescription,
      markDescriptionEditing,
      submitDescription,
      applyDescriptionAck,
      markDescriptionSaveFailed,
      settleDescriptionSave,
      settleExtras,
      setExtras,
      incrementExtras,
      decrementExtras,
    };
  });

export default Meal;
