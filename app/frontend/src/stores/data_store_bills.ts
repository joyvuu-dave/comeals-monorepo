// The bill save pipeline (issue #30): debounce, one request at a time,
// and saves that send edits with the bills the page saw (#135,
// docs/adr/0009-bills-saves-send-edits.md). One of the DataStore's
// subsystem files — see data_store.js, which composes them.
import { Instance } from "mobx-state-tree";

import { api, BillEdit } from "../helpers/api";
import { billEditsOf } from "../helpers/bill_edits";
import { mealDayLabel, SAVE_DEBOUNCE_MS } from "../helpers/helpers";
import { sameAmount } from "../helpers/money";
import { evictMealCache } from "../helpers/meal_cache";
import { newId } from "../helpers/new_id";
import handleAxiosError from "../helpers/handle_axios_error";
import { notifyError } from "../helpers/bugsnag";
import createVersionGuard from "../helpers/version_guard";
import { BillsAck } from "../types/api";
import Bill from "./bill";
import toastStore from "./toast_store";

type BillNode = Instance<typeof Bill>;

// One meal the "not saved" message names.
interface MealNotSaved {
  mealId: number;
  // The meal's day as the date box shows it ("Tue, Oct 6th").
  mealDay: string;
  // True when the server refused a save for this meal because the meal
  // was settled. It stays true when a later save for the meal fails for
  // another reason: a 409 or a lost network does not mean the meal is
  // open again.
  settled: boolean;
}

// The message about bills saves the server did not store, for meals the
// person has left (#107). It shows while they look at another meal or
// the calendar, so it names each meal by its day. `meals` is never
// empty.
function notSavedMessage(meals: MealNotSaved[]): string {
  if (meals.length > 1) {
    const mealDays = meals.map((meal) => meal.mealDay).join(" and ");
    return `The cooks and costs you entered for ${mealDays} were not saved. Please open those meals and enter them again.`;
  }
  const [{ mealDay, settled }] = meals;
  if (settled) {
    return `The cooks and costs you entered for ${mealDay} were not saved, because that meal has already been settled.`;
  }
  return `The cooks and costs you entered for ${mealDay} were not saved. Please open that meal and enter them again.`;
}

// What a person sees when the second try of a save for the meal on
// screen got no answer from the app (see noAnswerFromApp), whatever the
// first try got. The second try may have been written, so the words do
// not say that nothing was saved. The meal loads again right after, and
// shows what the server has.
const MAYBE_NOT_SAVED =
  "Your cooks and costs may not have been saved. Check them when the meal shows again.";

// What a person sees when one cook is picked in two rows. A save names
// each cook once, so nothing is sent until one of the rows shows another
// cook.
function cookInTwoRowsMessage(name: string): string {
  return `${name} is picked in two rows, so nothing was saved. Pick another cook in one of them.`;
}

// The words the server answers a write to a settled meal with
// (reconciled_rejection in app/controllers/api/v1/meals_controller.rb).
// The answer has no field that tells this refusal apart from the other
// 400s, so the words are compared. The same words are in
// tests/fixtures/api_contract.json, under "messages". Two tests compare
// them with that file:
// spec/requests/api/v1/update_bills_spec.rb checks that the server
// sends them, and tests/unit/api_contract.test.ts checks this constant.
export const SETTLED_MEAL_REFUSAL =
  "Change not permitted. Meal has already been reconciled.";

// The server's answer to a save that failed, or undefined when there
// was no answer. Read by shape, not by class: the response is what the
// server sent, whatever object carried it.
function responseIn(
  error: unknown,
): { status?: number; data?: BillsAck } | undefined {
  return (error as { response?: { status?: number; data?: BillsAck } } | null)
    ?.response;
}

// The body of the server's answer to a save that failed, or undefined
// when there was no answer.
function answerIn(error: unknown): BillsAck | undefined {
  return responseIn(error)?.data;
}

// The warning the bills endpoint answers with when the cooks were saved,
// with advice about the rotation (ThirdCookWarning).
function warningIn(error: unknown): BillsAck | null {
  const answer = answerIn(error);
  return answer?.type === "warning" ? answer : null;
}

// The status of the server's answer, or 0 when the answer has none.
function statusOf(response: { status?: number }): number {
  return response.status ?? 0;
}

// A failed save is sent once more, unchanged and with the same key, when
// another try may work (decision 7 of #135): a 409 with no type (two
// writes collided, or the meal lock was busy, and nothing was written),
// a 5xx, or no answer at all (a lost connection, the timeout, or a
// request that never left). After a 5xx or no answer the first try may
// have been written: Heroku's router answers 503 after 30 seconds while
// the request can still finish. The key makes the second try safe. If
// the first was written, the server answers the second as replayed and
// writes nothing more. A stale 409, a 400 or a 422 would get the same
// answer again, so they are final.
function worthSendingAgain(error: unknown): boolean {
  const response = responseIn(error);
  if (response === undefined) return true;
  const status = statusOf(response);
  return status >= 500 || (status === 409 && response.data?.type !== "stale");
}

// True when a failed save got no answer from the app, so the page cannot
// tell whether it was written: no answer at all (a lost connection, the
// timeout, or a request that never left), or a 5xx with no message from
// the app (Rails' own 500 page, or Heroku's router page). Every answer
// the app writes itself has a message.
function noAnswerFromApp(error: unknown): boolean {
  const response = responseIn(error);
  if (response === undefined) return true;
  return statusOf(response) >= 500 && !response.data?.message;
}

// One bills save: what is sent, and to which meal.
interface BillsSave {
  mealId: number;
  // The meal's day as the date box shows it. A message about this save
  // uses it when the person has left the meal by the time the server
  // answers.
  mealDay: string;
  edits: BillEdit[];
  // The save's Idempotency-Key: a new one for each save, and the same
  // one when the save is sent again.
  key: string;
  // False on the first try. True when the save is sent once more after
  // a failure that may not be final (worthSendingAgain). There is no
  // third try.
  secondTry: boolean;
}

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript): its own volatile fields, the rows and
// flags it saves, and the actions it defines and calls on itself.
export interface BillsStore extends ReturnType<typeof billsVolatile> {
  meal: { id: number; date: Date | null } | null;
  bills: { values(): IterableIterator<BillNode> };
  // True while the meal on screen loads, the first time or again after
  // a bills save for it failed (data_store_meal_page.ts).
  mealLoading: boolean;
  loadDataAsync(): void;
  // data_store_meal_page.ts: load the meal on screen again, frozen until
  // it arrives.
  loadMealAgain(): void;
  // data_store_meal_page.ts: fetch the meal on screen if its fetch was
  // put off and nothing is pending for it now.
  afterBillsIdle(): void;
  flushBillsSave(): void;
  submitBills(): void;
  sendBillsSave(save: BillsSave): void;
  billsSaveFailed(save: BillsSave, error: unknown): void;
  showBillsNotSaved(meal: MealNotSaved): void;
  applyBillsAck(data: BillsAck | undefined, save: BillsSave): void;
  settleBillsSave(): void;
}

export function billsVolatile() {
  return {
    // Pending debounce timer for a bill save, or null.
    billsSaveTimer: null as ReturnType<typeof setTimeout> | null,
    // The bills save sent and not answered yet, or null. With one
    // request at a time, this client's writes cannot arrive at the
    // server out of order. It holds its meal's id, and that meal's rows
    // are not built again from the server until it is answered
    // (billsPendingFor). A save sent a second time stays here until the
    // second try is answered.
    billsSaveInFlight: null as BillsSave | null,
    // A save of the meal on screen was requested while one was in
    // flight; send one more request with the latest state when it
    // settles. Leaving the meal clears it (saveBillsBeforeLeaving), so
    // it is always about the meal on screen.
    billsSaveQueued: false,
    // Saves built from the rows of a meal the person left while a save
    // was in flight (#107). Each waits for the save before it, then goes
    // to the meal it was built from, oldest first.
    billsSavesForMealsLeft: [] as BillsSave[],
    // The message on screen about saves for meals the person left that
    // were not saved (#107): the toast's id, and the meals it names, in
    // the order they first failed. The app shows one message at a time,
    // and a new one replaces the one on screen. So while this message
    // still shows, the next such failure adds its meal to it, and the
    // person sees every meal. A meal that fails again keeps its place.
    // A save that works later does not change the message or close it,
    // because it may not hold the cost that was lost: a save sends only
    // what changed after the save before it was built, and the meal on
    // screen loads again from the server after its save fails. So the
    // message can name a meal whose costs were saved by then. If they
    // were, the person opens that meal and finds them there. Once the
    // message is gone (closed by the person, closed by its timer,
    // cleared when a calendar form closes, or replaced by a message from
    // anywhere else in the app, #137), this list means nothing, and the
    // next failure starts a new one. A failed save for the meal on
    // screen joins this message while it shows, so one outage that
    // fails several saves in a row names every meal. So does a save of
    // the meal on screen that the page could not build (one cook in two
    // rows).
    billsNotSaved: null as { toastId: number; meals: MealNotSaved[] } | null,
    // The id of the message about a failed save of the meal on screen
    // (billsSaveFailed). When the save's second try got no answer from
    // the app (noAnswerFromApp), whatever the first try got, the message
    // says the costs may not have been saved. Otherwise it is the
    // server's words. A save for a meal the person left gets the "not
    // saved" message that names the meal instead (billsNotSaved), and so
    // does a save of the meal on screen while that message shows; this
    // id is not set for those. Null before the first such message.
    // While it still shows, a save that comes back with a warning does
    // not replace it, the same as for the "not saved" message. Toast ids
    // are never used twice, so once the message is gone, this id matches
    // no toast.
    billsFailedToastId: null as number | null,
    // Bumped on every bill edit. A meal fetch captures it: its answer is
    // not used if a bill was edited after it was sent (holdMealAnswer in
    // data_store_meal_page.ts).
    billsEdits: createVersionGuard(),
  };
}

export function billsActions(self: BillsStore) {
  // True while the message with this id is on screen.
  function onScreen(toastId: number | null): boolean {
    return toastStore.toasts.some((toast) => toast.id === toastId);
  }

  // The "not saved" message, or null when it is not on screen (see
  // billsNotSaved).
  function notSavedOnScreen() {
    const shown = self.billsNotSaved;
    if (shown === null) return null;
    return onScreen(shown.toastId) ? shown : null;
  }

  // Show the "not saved" message that names these meals, in place of
  // any message on screen. `meals` is never empty.
  function showMealsNotSaved(meals: MealNotSaved[]) {
    const toastId = toastStore.replaceAll(notSavedMessage(meals), "error");
    self.billsNotSaved = { toastId, meals };
  }

  // Check the answer to a save that was written (applyBillsAck). The
  // caller runs settleBillsSave next, and it must run whatever the
  // answer holds: until it runs, billsSaveInFlight stays set, so no
  // later save is ever sent. So a check that throws (an amount that is
  // not text, which only a bug in the server can send) is reported as
  // a bug. The rows could not be checked against the answer, so the
  // meal on screen loads again.
  function checkAnswer(data: BillsAck | undefined, save: BillsSave) {
    try {
      self.applyBillsAck(data, save);
    } catch (error) {
      notifyError(error);
      if (self.meal?.id === save.mealId) self.loadMealAgain();
    }
  }

  // The save of the rows on screen, or null when there is nothing to
  // send or it cannot be sent. Building it moves every row's base to
  // what the row shows: the server will have that once this save is
  // stored, so the next save names only what changes after this one.
  // `leaving` is true when the person is leaving the meal. A refusal
  // then names the meal, because by the time it shows, another meal or
  // the calendar is on screen. It uses the same words as any other save
  // for a meal the person left that was not saved. A refusal on the meal
  // on screen does the same while the "not saved" message shows, so it
  // does not replace that message, which may be the only sign that a
  // meal's costs were lost. It joins the message, the same way a failed
  // save for the meal on screen does (billsSaveFailed).
  function billsSaveOfRows(leaving: boolean): BillsSave | null {
    // No meal on screen, so nothing to save to.
    const meal = self.meal;
    if (!meal) {
      return null;
    }
    // loadData sets the date before it makes the rows a save is built
    // from, so the date is never null here.
    const mealDay = mealDayLabel(meal.date);

    const rows = Array.from(self.bills.values());
    const built = billEditsOf(rows);
    if (built.kind === "cookInTwoRows") {
      const words = cookInTwoRowsMessage(built.cook.plainName);
      if (leaving || notSavedOnScreen() !== null) {
        console.warn(words);
        self.showBillsNotSaved({ mealId: meal.id, mealDay, settled: false });
      } else {
        toastStore.replaceAll(words, "error");
      }
      return null;
    }
    if (built.kind === "invalidAmount" || built.edits.length === 0) {
      return null;
    }

    rows.forEach((bill) => bill.setBaseToShown());
    return {
      mealId: meal.id,
      mealDay,
      edits: built.edits,
      key: newId(),
      secondTry: false,
    };
  }

  return {
    // Debounced, same delay as the description field: a save fires only
    // after the user stops editing, so half-typed amounts never hit the
    // wire and each pause produces one request instead of one per keystroke.
    saveBills() {
      self.billsEdits.bump();
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
      }
      self.billsSaveTimer = setTimeout(function () {
        self.flushBillsSave();
      }, SAVE_DEBOUNCE_MS);
    },
    flushBillsSave() {
      self.billsSaveTimer = null;
      self.submitBills();
    },
    // Send a pending debounced save right now. Blur calls this, so
    // "type, then click away" saves immediately — the debounce only
    // spans pauses while the field still has focus. Without this,
    // closing the tab inside the debounce window would lose the edit.
    flushPendingBillsSave() {
      if (self.billsSaveTimer !== null) {
        self.submitBills();
      }
    },
    // switchMeals and teardownMealPage call this first: the person is
    // leaving the meal on screen, and its rows are about to be cleared.
    // An edit not sent yet belongs to this meal, whether it is still in
    // the debounce window, waiting for the save in flight to be
    // answered, or on a row whose save was refused before it could be
    // sent (one cook in two rows). That last kind has no timer and no
    // queued save, only a row that differs from its base. It is built
    // into a save now, from these rows and their bases, and sent to this
    // meal: right away, or after the save in flight is answered (#107).
    // It never goes to the next meal. If one cook is still picked in two
    // rows, no save can be built, and the message names this meal. The
    // bases already hold what the save in flight sent, so this save's
    // `from` is that save's `to`.
    saveBillsBeforeLeaving() {
      const unsent =
        self.billsSaveTimer !== null ||
        self.billsSaveQueued ||
        Array.from(self.bills.values()).some((bill) => bill.unsent);
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
        self.billsSaveTimer = null;
      }
      self.billsSaveQueued = false;
      if (!unsent) return;

      const save = billsSaveOfRows(true);
      if (save === null) return;
      if (self.billsSaveInFlight !== null) {
        self.billsSavesForMealsLeft = [...self.billsSavesForMealsLeft, save];
        return;
      }
      self.sendBillsSave(save);
    },
    submitBills() {
      // A direct submit (blur, the end of the debounce) supersedes a
      // pending debounced save — it sends the same latest state now.
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
        self.billsSaveTimer = null;
      }

      // Single-flight: one request at a time. The queued resend in
      // settleBillsSave sends whatever was edited meanwhile. The save
      // is built only then, and not now: building it moves the rows'
      // bases, and a base must not move for a save that is not sent.
      if (self.billsSaveInFlight !== null) {
        self.billsSaveQueued = true;
        return;
      }

      const save = billsSaveOfRows(false);
      if (save === null) {
        // Nothing was sent. If the rows now show what the server has,
        // the meal may be waiting for nothing more before a fetch.
        self.afterBillsIdle();
        return;
      }

      self.sendBillsSave(save);
    },
    sendBillsSave(save: BillsSave) {
      self.billsSaveInFlight = save;

      api.meals
        .updateBills(save.mealId, {
          edits: save.edits,
          key: save.key,
          socketId: window.Comeals.socketId,
        })
        .then(
          function (response) {
            // The server saved the bills, so the cached meal payload is
            // now stale (issue #37).
            evictMealCache(save.mealId);
            checkAnswer(response.data, save);
            self.settleBillsSave();
          },
          function (error: unknown) {
            self.billsSaveFailed(save, error);
          },
        );
    },
    // A bills save failed, or was saved with a warning (a 400 the client
    // rejects with). Decision 7 of #135: a failure that may not be final
    // sends the same save once more, before any save built after it. A
    // base is never moved back: a save built after this one was built on
    // it, and the server checks that save's `from`.
    billsSaveFailed(save: BillsSave, error: unknown) {
      // The person may have left the meal while the save waited for
      // the server's answer. The message then shows on another meal or
      // on the calendar, so it names the meal (#107).
      const mealLeft = !self.meal || self.meal.id !== save.mealId;
      const warning = warningIn(error);
      if (warning) {
        // A warning response still persisted the bills — evict, same
        // as the success path.
        evictMealCache(save.mealId);
        const msg = warning.message || "";
        const words =
          (mealLeft ? `Cooks saved for ${save.mealDay}.` : "Cooks saved.") +
          (msg ? " " + msg : "");
        // A message that says a save failed is never replaced by one
        // that says a save worked: the failure is still true, and the
        // person may not have read it yet. So while the "not saved"
        // message shows, or the message about a failed save of the meal
        // on screen, a warning is only logged, whichever meal it is
        // about.
        if (notSavedOnScreen() !== null || onScreen(self.billsFailedToastId)) {
          console.warn(words);
        } else {
          toastStore.replaceAll(words, "info");
        }
        checkAnswer(warning, save);
        self.settleBillsSave();
        return;
      }

      if (!save.secondTry && worthSendingAgain(error)) {
        // Nothing shows yet: the second try may work. The first
        // failure is only logged.
        handleAxiosError(error, { silent: true });
        self.sendBillsSave({ ...save, secondTry: true });
        return;
      }

      if (mealLeft || notSavedOnScreen() !== null) {
        // The server's words are only logged. For a meal the person
        // left they do not say which meal they are about. For the meal
        // on screen, showing them would replace the message about a
        // meal left, and one outage fails both saves in a row, so the
        // meal on screen joins that message instead.
        handleAxiosError(error, { silent: true });
        // Every failure is shown, even when a newer save for this meal
        // waits behind this one (see billsNotSaved).
        self.showBillsNotSaved({
          mealId: save.mealId,
          mealDay: save.mealDay,
          settled: answerIn(error)?.message === SETTLED_MEAL_REFUSAL,
        });
      } else if (noAnswerFromApp(error)) {
        // The second try got no answer from the app, so it may have been
        // written, whatever the first try got. Only a second try gets
        // here: a first try with no answer from the app is always sent
        // again. Words like "no response" could be read as "nothing was
        // saved", so these say what the page knows. When the second try
        // gets the app's own words instead, those show, even after a
        // first try with no answer: Puma runs one thread, so the first
        // try was finished before the second was read, and if it had
        // been written, the second would have been answered as replayed.
        handleAxiosError(error, { silent: true });
        self.billsFailedToastId = toastStore.replaceAll(
          MAYBE_NOT_SAVED,
          "error",
        );
      } else {
        self.billsFailedToastId = handleAxiosError(error);
      }
      // A 422 means this page sent one key with two different saves.
      if (responseIn(error)?.status === 422) {
        notifyError(
          new Error(
            `The server refused a bills save for meal ${save.mealId}: its Idempotency-Key was already used for a different save`,
          ),
        );
      }

      // The rows on screen show what this save sent, and their bases say
      // the server has it, which it may not. So the meal loads again,
      // frozen until it arrives. The load waits until nothing is pending
      // for the meal, so a cost typed behind this save is sent first
      // (#136). A save for a meal the person left did not change the
      // rows on screen, so that meal is not loaded.
      if (!mealLeft) self.loadMealAgain();
      self.settleBillsSave();
    },
    // A save was not saved: for a meal the person left, or for the meal
    // on screen while this message shows. Show the message that names
    // it, with the meals the message on screen already names
    // if that message still shows (see billsNotSaved). A meal the
    // message already names keeps its place, and keeps the settled words
    // once a save for it was refused as settled (see MealNotSaved).
    showBillsNotSaved(meal: MealNotSaved) {
      const earlier = notSavedOnScreen()?.meals ?? [];
      showMealsNotSaved(
        earlier.some((named) => named.mealId === meal.mealId)
          ? earlier.map((named) =>
              named.mealId === meal.mealId
                ? { ...meal, settled: named.settled || meal.settled }
                : named,
            )
          : [...earlier, meal],
      );
    },
    // The answer to a save that was written. It changes no row: the
    // rows' bases moved when the save was built, and a row may already
    // show a newer cost. It is checked instead. The server reads the
    // bills right after the save's writes, in the same transaction, so
    // each cook the save named must show what the save sent, and a cook
    // it removed must be gone. A replayed answer holds the bills as
    // stored now, and someone may have saved since the first try, so a
    // difference there is not a bug. Either way the rows on screen may
    // not be what the server has, so the meal loads again.
    applyBillsAck(data: BillsAck | undefined, save: BillsSave) {
      const bills = data?.bills;
      if (bills === undefined) return;
      const stored = new Map(bills.map((bill) => [bill.resident_id, bill]));
      const asSent = save.edits.every((edit) => {
        const bill = stored.get(edit.resident_id);
        if (edit.op === "remove") return bill === undefined;
        return (
          bill !== undefined &&
          sameAmount(bill.amount, edit.to.amount) &&
          bill.no_cost === edit.to.no_cost
        );
      });
      if (asSent) return;
      if (data?.type !== "replayed") {
        notifyError(
          new Error(
            `The answer to a bills save for meal ${save.mealId} does not hold what the save sent`,
          ),
        );
      }
      if (self.meal?.id === save.mealId) self.loadMealAgain();
    },
    // The save in flight was answered. Saves for meals the person left
    // go first, oldest first: they were made before anything typed on
    // the meal on screen now. Then a queued save sends the rows of the
    // meal on screen as they are now. The queue flag is always about the
    // meal on screen, because leaving a meal clears it. Last, the meal on
    // screen is fetched if it was waiting for its saves and now waits
    // for nothing more.
    settleBillsSave() {
      self.billsSaveInFlight = null;
      if (self.billsSavesForMealsLeft.length > 0) {
        const [next, ...rest] = self.billsSavesForMealsLeft;
        self.billsSavesForMealsLeft = rest;
        self.sendBillsSave(next);
      } else if (self.billsSaveQueued) {
        self.billsSaveQueued = false;
        self.submitBills();
      }
      self.afterBillsIdle();
    },
    // True while this page has a bills edit for the meal that the server
    // may not have yet: sent and not answered, waiting to be sent after
    // the save in flight, in the wait before a save, or on a row that
    // differs from its base with no save to carry it. While it is true,
    // the meal's rows must not be built again from the server (#136):
    // the server's answer may be older than the edit, and new rows would
    // drop it, so the next save would never send it.
    //
    // While the meal on screen loads again after a failed save, a row
    // that differs from its base with no timer or queued save to carry
    // it does not count. Its edit was refused before it could be sent
    // (one cook in two rows), and the rows are frozen until the meal
    // loads, so nobody could change it, and waiting for it would keep
    // the meal from ever loading.
    billsPendingFor(mealId: number): boolean {
      if (self.billsSaveInFlight?.mealId === mealId) return true;
      if (self.billsSavesForMealsLeft.some((save) => save.mealId === mealId)) {
        return true;
      }
      // The timer, the queue flag and the rows are always about the meal
      // on screen.
      if (self.meal?.id !== mealId) return false;
      return (
        self.billsSaveTimer !== null ||
        self.billsSaveQueued ||
        (!self.mealLoading &&
          Array.from(self.bills.values()).some((bill) => bill.unsent))
      );
    },
  };
}
