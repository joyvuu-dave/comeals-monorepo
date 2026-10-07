// The bill save pipeline (issue #30): debounce, single-flight,
// version-guarded acks. One of the DataStore's subsystem files — see
// data_store.js, which composes them.
import { Instance } from "mobx-state-tree";

import { api, BillInput } from "../helpers/api";
import { mealDayLabel, SAVE_DEBOUNCE_MS } from "../helpers/helpers";
import { toDisplayAmountString } from "../helpers/money";
import { evictMealCache } from "../helpers/meal_cache";
import handleAxiosError from "../helpers/handle_axios_error";
import createVersionGuard from "../helpers/version_guard";
import { BillsAck } from "../types/api";
import Bill from "./bill";
import toastStore from "./toast_store";

type BillNode = Instance<typeof Bill>;

// What a person sees when a bills save is refused because the meal has a
// bill the page does not show (#91).
const BILLS_INCOMPLETE_MESSAGE =
  "One cook's cost on this meal is not shown on this page, so nothing was saved. Please reload the page.";

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

// The body of the server's answer to a save that failed, or undefined
// when there was no answer. Read by shape, not by class: the response is
// what the server put in the body, whatever object carried it.
function answerIn(error: unknown): BillsAck | undefined {
  return (error as { response?: { data?: BillsAck } } | null)?.response?.data;
}

// The warning the bills endpoint answers with when a cook-scheduling guard
// refused part of the write but the rest was saved.
function warningIn(error: unknown): BillsAck | null {
  const answer = answerIn(error);
  return answer?.type === "warning" ? answer : null;
}

// One bills save: what is sent, and to which meal.
interface BillsSave {
  mealId: number;
  // The meal's day as the date box shows it. A message about this save
  // uses it when the person has left the meal by the time the server
  // answers.
  mealDay: string;
  bills: BillInput[];
  // billsEdits when the save was built. Its answer may change the rows
  // on screen only if nothing was typed since.
  versionAtSend: number;
}

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript): its own volatile fields, the rows and
// flags it saves, and the actions it defines and calls on itself.
export interface BillsStore extends ReturnType<typeof billsVolatile> {
  meal: { id: number; date: Date | null } | null;
  bills: { values(): IterableIterator<BillNode> };
  // Set by loadData (data_store_meal_page.ts) when the meal has a bill
  // the page cannot show.
  billsIncomplete: boolean;
  loadDataAsync(): void;
  flushBillsSave(): void;
  submitBills(): void;
  sendBillsSave(save: BillsSave): void;
  showBillsNotSaved(meal: MealNotSaved): void;
  applyBillsAck(
    data: BillsAck,
    versionAtSend: number,
    mealIdAtSend: number,
  ): void;
  settleBillsSave(): void;
}

export function billsVolatile() {
  return {
    // Pending debounce timer for a bill save, or null.
    billsSaveTimer: null as ReturnType<typeof setTimeout> | null,
    // True while a bills request is in flight. With one request at a time,
    // this client's writes cannot arrive at the server out of order.
    billsSaveInFlight: false,
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
    // because it may not hold the cost that was lost: it may hold only
    // another cook's cost, or the rows may have loaded again from the
    // server while the failed save waited for its answer. So the
    // message can name a meal whose costs were saved by then. If they
    // were, the person opens that meal and finds them there. Once the
    // message is gone (closed by the person, closed by its timer,
    // cleared when a calendar form closes, or replaced by a message from
    // anywhere else in the app, #137), this list means nothing, and the
    // next failure starts a new one. A failed save for the meal on
    // screen joins this message while it shows, so one outage that
    // fails several saves in a row names every meal.
    billsNotSaved: null as { toastId: number; meals: MealNotSaved[] } | null,
    // Stale-response guard for bill saves: bumped on every bill edit,
    // captured at send; an ack applies only if nothing was typed since.
    billsEdits: createVersionGuard(),
  };
}

export function billsActions(self: BillsStore) {
  // The "not saved" message, or null when it is not on screen (see
  // billsNotSaved).
  function notSavedOnScreen() {
    const shown = self.billsNotSaved;
    if (shown === null) return null;
    return toastStore.toasts.some((toast) => toast.id === shown.toastId)
      ? shown
      : null;
  }

  // Show the "not saved" message that names these meals, in place of
  // any message on screen. `meals` is never empty.
  function showMealsNotSaved(meals: MealNotSaved[]) {
    const toastId = toastStore.replaceAll(notSavedMessage(meals), "error");
    self.billsNotSaved = { toastId, meals };
  }

  // The save of the rows on screen, or null when they cannot be sent.
  // `leaving` is true when the person is leaving the meal. A refusal
  // then names the meal, because by the time it shows, another meal or
  // the calendar is on screen. It uses the same words as any other save
  // for a meal the person left that was not saved.
  function billsSaveOfRows(leaving: boolean): BillsSave | null {
    // No meal on screen, so nothing to save to.
    const meal = self.meal;
    if (!meal) {
      return null;
    }
    // loadData sets the date before it makes the rows a save is built
    // from, so the date is never null here.
    const mealDay = mealDayLabel(meal.date);

    // The meal has a bill this page does not show (#91). A save lists
    // every cook, and the server deletes the bill of a cook left out,
    // so any save from this page would delete that bill. Nothing is
    // sent. A reload gets the full list from the server.
    if (self.billsIncomplete) {
      if (leaving) {
        self.showBillsNotSaved({ mealId: meal.id, mealDay, settled: false });
      } else {
        toastStore.replaceAll(BILLS_INCOMPLETE_MESSAGE, "error");
      }
      return null;
    }

    // Only touched rows carry values to the server, so only they can
    // block the save.
    if (
      Array.from(self.bills.values()).some(
        (bill) => bill.touched && bill.amountIsValid === false,
      )
    ) {
      return null;
    }

    // The payload lists every cook (the server deletes bills for cooks
    // left out), but only rows the user touched carry amount/no_cost.
    // The server leaves the other rows' stored values alone, so a
    // display value can never rewrite a bill nobody edited.
    const bills: BillInput[] = Array.from(self.bills.values()).flatMap(
      (bill) => {
        const residentId = bill.resident_id;
        if (residentId === "") return [];
        return [
          bill.touched
            ? {
                resident_id: residentId,
                amount: bill.amount,
                no_cost: bill.no_cost,
              }
            : { resident_id: residentId },
        ];
      },
    );

    return {
      mealId: meal.id,
      mealDay,
      bills,
      versionAtSend: self.billsEdits.current(),
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
    // the debounce window or waiting for the save in flight to be
    // answered. It is built into a save now, from these rows, and sent
    // to this meal: right away, or after the save in flight is answered
    // (#107). It never goes to the next meal.
    saveBillsBeforeLeaving() {
      const unsent = self.billsSaveTimer !== null || self.billsSaveQueued;
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
        self.billsSaveTimer = null;
      }
      self.billsSaveQueued = false;
      if (!unsent) return;

      const save = billsSaveOfRows(true);
      if (save === null) return;
      if (self.billsSaveInFlight) {
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

      const save = billsSaveOfRows(false);
      if (save === null) return;

      // Single-flight: one request at a time. The queued resend in
      // settleBillsSave sends whatever was edited meanwhile.
      if (self.billsSaveInFlight) {
        self.billsSaveQueued = true;
        return;
      }

      self.sendBillsSave(save);
    },
    sendBillsSave(save: BillsSave) {
      self.billsSaveInFlight = true;

      api.meals
        .updateBills(save.mealId, {
          bills: save.bills,
          socketId: window.Comeals.socketId,
        })
        .then(function (response) {
          // The server saved the bills, so the cached meal payload is
          // now stale (issue #37).
          evictMealCache(save.mealId);
          self.applyBillsAck(response.data, save.versionAtSend, save.mealId);
        })
        .catch(function (error: unknown) {
          // The person may have left the meal while the save waited for
          // the server's answer. The message then shows on another meal
          // or on the calendar, so it names the meal (#107).
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
            // message shows, a warning is only logged, whichever meal it
            // is about.
            if (notSavedOnScreen() !== null) {
              console.warn(words);
            } else {
              toastStore.replaceAll(words, "info");
            }
          } else if (mealLeft || notSavedOnScreen() !== null) {
            // The server's words are only logged. For a meal the person
            // left they do not say which meal they are about. For the
            // meal on screen, showing them would replace the message
            // about a meal left, and one outage fails both saves in a
            // row, so the meal on screen joins that message instead.
            handleAxiosError(error, { silent: true });
            // Every failure is shown, even when a newer save for this
            // meal waits behind this one (see billsNotSaved).
            self.showBillsNotSaved({
              mealId: save.mealId,
              mealDay: save.mealDay,
              settled: answerIn(error)?.message === SETTLED_MEAL_REFUSAL,
            });
          } else {
            handleAxiosError(error);
          }

          // The rows on screen may now show what the server did not
          // store, so the meal is fetched again. A save for a meal the
          // person left did not change the rows on screen, and a fetch
          // would rebuild them and wipe a cost being typed there (#136).
          if (!mealLeft) self.loadDataAsync();
        })
        .then(function () {
          self.settleBillsSave();
        });
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
    // Display what the server stored, not what we sent — but only when the
    // rows on screen are the rows this ack answers: same meal, and no edits
    // since the request went out. Otherwise ignore it; the queued next save
    // covers the newer edits and its own ack will reconcile. An answer to
    // the save of a meal the person left arrives while another meal's rows
    // are on screen, and the meal check keeps it off them.
    applyBillsAck(data: BillsAck, versionAtSend: number, mealIdAtSend: number) {
      if (!self.billsEdits.isCurrent(versionAtSend)) return;
      if (!self.meal || self.meal.id !== mealIdAtSend) return;
      if (!data || !Array.isArray(data.bills)) return;

      data.bills.forEach(function (row) {
        const bill = Array.from(self.bills.values()).find(
          (b) => b.resident && b.resident.id === row.resident_id,
        );
        if (!bill) return;
        // Rewrite the amount only when the server disagrees with the
        // screen. When the values match, a rewrite is pure reformatting
        // ("1" becomes "1.00") and it lands under the cursor: the next
        // keystroke makes "1.000", which the whole-cents grammar refuses,
        // so the keystroke is swallowed. The field pads itself on blur
        // instead.
        const serverAmount = toDisplayAmountString(row.amount);
        if (serverAmount !== toDisplayAmountString(bill.amount)) {
          bill.amount = serverAmount;
        }
        bill.no_cost = row.no_cost;
        // The row now shows exactly what the server stored, so it no
        // longer needs to assert values on the next save — and a stale
        // resend can no longer overwrite another client's newer edit.
        bill.touched = false;
      });
    },
    // The save in flight was answered. Saves for meals the person left
    // go first, oldest first: they were made before anything typed on
    // the meal on screen now. Then a queued save sends the rows of the
    // meal on screen as they are now. The queue flag is always about the
    // meal on screen, because leaving a meal clears it.
    settleBillsSave() {
      self.billsSaveInFlight = false;
      if (self.billsSavesForMealsLeft.length > 0) {
        const [next, ...rest] = self.billsSavesForMealsLeft;
        self.billsSavesForMealsLeft = rest;
        self.sendBillsSave(next);
        return;
      }
      if (!self.billsSaveQueued) return;
      self.billsSaveQueued = false;
      self.submitBills();
    },
  };
}
