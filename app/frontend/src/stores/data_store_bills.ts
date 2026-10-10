// The bill save pipeline (#30, #150): each cook row saves on its own,
// and a save sends edits with the bills the page saw (#135,
// docs/adr/0009-bills-saves-send-edits.md). One of the DataStore's
// subsystem files — see data_store.js, which composes them.
import { when } from "mobx";
import { Instance } from "mobx-state-tree";

import { api, BillEdit } from "../helpers/api";
import { billEditsOf } from "../helpers/bill_edits";
import { mealDayLabel } from "../helpers/helpers";
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

// How long a cook row waits after its last edit before it saves (#150).
// A person who picks a cook and then types the cost, or types a cost
// with pauses, sends one save. Leaving the cost box or pressing Enter in
// it saves at once.
export const BILL_ROW_SAVE_WAIT_MS = 2000;

// How long a row's save can be on its way before the row shows a
// spinner in its cost box. Most saves are answered sooner, and then the
// person never sees that the row was locked.
export const BILL_ROW_SPINNER_WAIT_MS = 1000;

// How long logout, Refresh and the error page's Refresh wait for the
// bills saves on their way before the page reloads (finishBillsSaves).
// A reload ends every request on its way, and the person would not
// learn whether it was saved. A save still on its way then is sent again
// with fetch keepalive when the page closes (sendBillsAgainBeforeClose).
export const BILLS_WAIT_BEFORE_RELOAD_MS = 5000;

// One meal a message about a meal the person left names.
interface MealNamed {
  mealId: number;
  // The meal's day as the date box shows it ("Tue, Oct 6th").
  mealDay: string;
}

// One meal the "not saved" message names.
interface MealNotSaved extends MealNamed {
  // True when the server refused a save for this meal because the meal
  // was settled. It stays true when a later save for the meal fails for
  // another reason: a 409 or a lost network does not mean the meal is
  // open again.
  settled: boolean;
}

// A message in the stack that names meals, and the meals it names, in
// the order they first failed. `meals` is never empty.
interface MessageNamingMeals<M extends MealNamed> {
  toastId: number;
  meals: M[];
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

// The message about bills saves for meals the person left whose second
// try got no answer from the app (see noAnswerFromApp, #137). That try
// may have been written, so the words do not say the costs were not
// saved. Kept apart from the "not saved" message: the two kinds are
// never in one sentence. `meals` is never empty.
function maybeNotSavedMessage(meals: MealNamed[]): string {
  if (meals.length > 1) {
    const mealDays = meals.map((meal) => meal.mealDay).join(" and ");
    return `The cooks and costs you entered for ${mealDays} may not have been saved. Please open those meals and check them.`;
  }
  return `The cooks and costs you entered for ${meals[0].mealDay} may not have been saved. Please open that meal and check them.`;
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

// The message with this id, if it is still in the stack of messages. A
// message behind the "more" line is in the stack too: one tap shows it.
// Once the person closed it, the message is gone, and so is what the
// page kept about it.
function inStack<T extends { toastId: number }>(message: T | null): T | null {
  if (message === null) return null;
  return toastStore.toasts.some((toast) => toast.id === message.toastId)
    ? message
    : null;
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

// One bills save: what is sent, to which meal, and from which row.
interface BillsSave {
  // The id of the cook row the save was built from. The row is locked
  // while the save is on its way. Once the person leaves the meal, no
  // row has this id.
  rowId: string;
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
  // True when the save went with fetch keepalive, which can finish after
  // the page is gone (#150): it was sent because the page was hidden or
  // closed, or it was sent again before the page closed
  // (sendBillsAgainBeforeClose).
  keepalive: boolean;
}

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript): its own volatile fields, the rows and
// flags it saves, and the actions it defines and calls on itself.
export interface BillsStore extends ReturnType<typeof billsVolatile> {
  meal: { id: number; date: Date | null } | null;
  bills: {
    values(): IterableIterator<BillNode>;
    has(id: string): boolean;
  };
  // True while the meal on screen loads, the first time or again after
  // a bills save for it failed (data_store_meal_page.ts).
  mealLoading: boolean;
  // data_store_meal_page.ts: load the meal on screen again, frozen until
  // it arrives.
  loadMealAgain(): void;
  // data_store_meal_page.ts: fetch the meal on screen if its fetch was
  // put off and nothing is pending for it now.
  afterBillsIdle(): void;
  sendBillRow(row: BillNode, keepalive: boolean): void;
  sendBillsSave(save: BillsSave): void;
  postBillsSave(save: BillsSave): void;
  endReloadWait(failuresBefore: number): boolean;
  sendBillsAgainBeforeClose(): void;
  billsSaveFailed(save: BillsSave, error: unknown): void;
  showBillsNotSaved(meal: MealNotSaved): void;
  showBillsMaybeNotSaved(meal: MealNamed): void;
  dropFixedCookInTwoRows(): void;
  applyBillsAck(data: BillsAck | undefined, save: BillsSave): void;
  markBillsSaveSlow(key: string): void;
  settleBillsSave(save: BillsSave): void;
}

export function billsVolatile() {
  return {
    // The wait before each row's save, by row id: a row is here from
    // its edit until its save is built. Only rows on screen have one.
    // Replaced, never changed in place.
    billsSaveTimers: {} as Record<string, ReturnType<typeof setTimeout>>,
    // The bills saves sent and not answered yet, for the meal on screen
    // and for meals the person left. A save sent a second time stays
    // here until the second try is answered. A meal's rows are not built
    // again from the server while a save for it is here
    // (billsPendingFor). Each row has at most one save here, because a
    // row takes no edit while its save is on its way. Two saves here
    // never name the same cook of one meal, because a row cannot take a
    // cook while another row's change to that cook is not answered
    // (cookTakenByAnotherRow), so the server can take them in any order.
    billsSavesOnTheirWay: [] as BillsSave[],
    // The keys of the saves here that have been on their way longer
    // than BILL_ROW_SPINNER_WAIT_MS. Their rows show a spinner.
    billsSlowSaveKeys: [] as string[],
    // True from the moment Logout, Refresh or the error page's Refresh
    // starts to wait for the bills saves (finishBillsSaves) until the
    // page reloads, or until the wait says it must not. The cook rows
    // take no edit then (cooks_box.jsx): an edit would wait 2 seconds
    // before its save, and the reload, or logout taking the token away,
    // would lose it.
    waitingToReload: false,
    // How many times the page has told the person that a bills edit was
    // not saved, or may not have been: a save that failed for good, or a
    // row whose save could not be built (one cook in two rows).
    // finishBillsSaves reads it before and after its wait, so it knows
    // whether one of the saves it waited for was not saved.
    billsFailuresShown: 0,
    // The message on screen about saves for meals the person left that
    // were not saved (#107): the message's id, and the meals it names,
    // in the order they first failed. While this message is still in
    // the stack of messages, the next such failure adds its meal to it,
    // and the message moves to the top, so one message names every meal.
    // A meal that fails again keeps its place. A save that works later
    // does not change the message or close it, because it may not hold
    // the cost that was lost: a save sends only what changed after the
    // save before it was built, and the meal on screen loads again from
    // the server after its save fails. So the message can name a meal
    // whose costs were saved by then. If they were, the person opens
    // that meal and finds them there. The message is an error, so it
    // stays until the person closes it, whatever other messages come
    // after it (#137). Once it is closed, this list means nothing, and
    // the next failure starts a new message.
    billsNotSaved: null as MessageNamingMeals<MealNotSaved> | null,
    // The message about saves for meals the person left whose second try
    // got no answer from the app, so they may have been written (#137):
    // the message's id, and the meals it names. It grows and moves the
    // same way as billsNotSaved. A meal is named in this message or in
    // billsNotSaved, never in both. The "not saved" one asks for more
    // (enter the costs again, which takes in checking them), so a meal
    // in both kinds goes there.
    billsMaybeNotSaved: null as MessageNamingMeals<MealNamed> | null,
    // The "may not have been saved" message about the meal on screen
    // (MAYBE_NOT_SAVED), and that meal. Its words are about the meal on
    // screen, so when the person leaves the meal while it is still in
    // the stack, the message that names the meal takes its place.
    billsMaybeOnScreen: null as ({ toastId: number } & MealNamed) | null,
    // The message that a cook is picked in two rows of the meal on
    // screen, and that cook. The page made this check itself, so once
    // the rows no longer show the cook twice, the message goes (#137).
    billsCookInTwoRows: null as { toastId: number; cookId: number } | null,
    // Bumped on every bill edit. A meal fetch captures it: its answer is
    // not used if a bill was edited after it was sent (holdMealAnswer in
    // data_store_meal_page.ts).
    billsEdits: createVersionGuard(),
  };
}

// What the cook rows read about their saves. Views, not actions: a row
// reads them while it renders.
export function billsViews(self: BillsStore) {
  return {
    // True while this row's save is on its way. The row takes no edit
    // until it is answered (#150).
    billsRowSaving(rowId: string): boolean {
      return self.billsSavesOnTheirWay.some((save) => save.rowId === rowId);
    },
    // True when this row's save has been on its way for longer than
    // BILL_ROW_SPINNER_WAIT_MS, so the row shows a spinner.
    billsRowSlowToSave(rowId: string): boolean {
      return self.billsSavesOnTheirWay.some(
        (save) =>
          save.rowId === rowId && self.billsSlowSaveKeys.includes(save.key),
      );
    },
    // True when a row other than this one is still changing this cook:
    // it has the cook at its base but shows another, so its save will
    // remove or move the cook, or its save that names the cook is on its
    // way. This row must not take the cook until that save is answered.
    // Two saves on their way at once that name one cook could reach the
    // server in either order, and an add that arrives before the remove
    // it follows would be undone by it, with no message.
    cookTakenByAnotherRow(row: BillNode, cookId: number): boolean {
      const changedInAnotherRow = Array.from(self.bills.values()).some(
        (other) =>
          other !== row &&
          other.baseCookId === cookId &&
          other.resident_id !== cookId,
      );
      // A save whose row is not on screen is for a meal the person left.
      return (
        changedInAnotherRow ||
        self.billsSavesOnTheirWay.some(
          (save) =>
            save.rowId !== row.id &&
            self.bills.has(save.rowId) &&
            save.edits.some((edit) => edit.resident_id === cookId),
        )
      );
    },
  };
}

export function billsActions(self: BillsStore) {
  // Show these words on top of the stack, in place of the earlier
  // message if it is still in the stack, and hand back the new
  // message's id.
  function showInPlaceOf(earlier: { toastId: number } | null, words: string) {
    return earlier === null
      ? toastStore.show(words, "error")
      : toastStore.replace(earlier.toastId, words, "error");
  }

  // The server saved the cooks and warned about the rotation
  // (ThirdCookWarning). The words say the cooks were saved, and name the
  // meal when the person has left it. They go on top of any message
  // about a save that failed, which stays under them (#137).
  function showWarning(warning: BillsAck, save: BillsSave) {
    const mealLeft = !self.meal || self.meal.id !== save.mealId;
    const words =
      (mealLeft ? `Cooks saved for ${save.mealDay}.` : "Cooks saved.") +
      (warning.message ? " " + warning.message : "");
    toastStore.show(words, "info");
  }

  // Take this meal out of the "may not have been saved" message, if it
  // names it: a save for the meal surely was not saved, and the "not
  // saved" message names it now (see billsMaybeNotSaved). With no meal
  // left to name, the message goes.
  function unnameMaybe(mealId: number) {
    const maybe = inStack(self.billsMaybeNotSaved);
    if (!maybe?.meals.some((named) => named.mealId === mealId)) return;
    const meals = maybe.meals.filter((named) => named.mealId !== mealId);
    if (meals.length === 0) {
      toastStore.remove(maybe.toastId);
      self.billsMaybeNotSaved = null;
      return;
    }
    self.billsMaybeNotSaved = {
      toastId: showInPlaceOf(maybe, maybeNotSavedMessage(meals)),
      meals,
    };
  }

  // Check the answer to a save that was written (applyBillsAck). The
  // caller runs settleBillsSave next, and it must run whatever the
  // answer holds: until it runs, the save stays on its way, so its row
  // stays locked. So a check that throws (an amount that is not text,
  // which only a bug in the server can send) is reported as a bug. The
  // rows could not be checked against the answer, so the meal on screen
  // loads again.
  function checkAnswer(data: BillsAck | undefined, save: BillsSave) {
    try {
      self.applyBillsAck(data, save);
    } catch (error) {
      notifyError(error);
      if (self.meal?.id === save.mealId) self.loadMealAgain();
    }
  }

  // Stop the wait before this row's save, if it has one. Answers true
  // when it had one.
  function stopRowWait(rowId: string): boolean {
    const timer = self.billsSaveTimers[rowId];
    if (timer === undefined) return false;
    clearTimeout(timer);
    self.billsSaveTimers = Object.fromEntries(
      Object.entries(self.billsSaveTimers).filter(([id]) => id !== rowId),
    );
    return true;
  }

  // Start the wait before this row's save, in place of the wait it had.
  function startRowWait(row: BillNode) {
    stopRowWait(row.id);
    self.billsSaveTimers = {
      ...self.billsSaveTimers,
      [row.id]: setTimeout(function () {
        self.sendBillRow(row, false);
      }, BILL_ROW_SAVE_WAIT_MS),
    };
  }

  // The rows on screen that wait to save.
  function rowsWaiting(): BillNode[] {
    return Array.from(self.bills.values()).filter(
      (row) => self.billsSaveTimers[row.id] !== undefined,
    );
  }

  // The save of one row, or null when there is nothing to send or it
  // cannot be sent. It names only this row's cooks: the cook it shows,
  // and the cook at its base. Building it moves the row's base to what
  // the row shows: the server will have that once this save is stored,
  // so the row's next save names only what changes after this one.
  // `leaving` is true when the person is leaving the meal. A refusal
  // then names the meal, because by the time it shows, another meal or
  // the calendar is on screen. It uses the same words as any other save
  // for a meal the person left that was not saved.
  function rowSave(
    row: BillNode,
    leaving: boolean,
    keepalive: boolean,
  ): BillsSave | null {
    // No meal on screen, so nothing to save to. The rows are frozen
    // then (cooks_box.jsx), so only a bug can get here.
    const meal = self.meal;
    if (!meal) {
      return null;
    }
    // loadData sets the date before it makes the rows a save is built
    // from, so the date is never null here.
    const mealDay = mealDayLabel(meal.date);

    const otherRows = Array.from(self.bills.values()).filter(
      (other) => other !== row,
    );
    const built = billEditsOf(row, otherRows);
    if (built.kind === "cookInTwoRows") {
      self.billsFailuresShown += 1;
      const words = cookInTwoRowsMessage(built.cook.plainName);
      if (leaving) {
        console.warn(words);
        self.showBillsNotSaved({ mealId: meal.id, mealDay, settled: false });
      } else {
        self.billsCookInTwoRows = {
          toastId: toastStore.show(words, "error"),
          cookId: built.cook.id,
        };
      }
      return null;
    }
    if (built.kind === "invalidAmount" || built.edits.length === 0) {
      return null;
    }

    row.setBaseToShown();
    return {
      rowId: row.id,
      mealId: meal.id,
      mealDay,
      edits: built.edits,
      key: newId(),
      secondTry: false,
      keepalive,
    };
  }

  // Stop every row's wait, and save now each row on screen that shows an
  // edit the server does not have, whether it waits to save or its save
  // was refused before it could be sent (one cook in two rows). A row
  // with no edit builds no save. A row whose save is on its way takes no
  // edits, so it has nothing more to send.
  function sendEveryRowNow(leaving: boolean) {
    Array.from(self.bills.values()).forEach((row) => {
      stopRowWait(row.id);
      const save = rowSave(row, leaving, false);
      if (save !== null) self.sendBillsSave(save);
    });
  }

  return {
    // A row was edited. It saves BILL_ROW_SAVE_WAIT_MS after its last
    // edit, so half-typed amounts never go to the server, and each pause
    // sends one save instead of one per keystroke.
    saveBillRowSoon(row: BillNode) {
      self.billsEdits.bump();
      self.dropFixedCookInTwoRows();
      startRowWait(row);
    },
    // The person came to the row's cost box. If the row waits to save,
    // its wait starts again. A person who picks a cook and then goes to
    // the cost box can take about 2 seconds to get there on a phone
    // (close the menu, tap the box, wait for the keyboard). If the pick's
    // save went then, the row would lock under the first digits typed,
    // and they would not land.
    restartBillRowWait(row: BillNode) {
      if (self.billsSaveTimers[row.id] !== undefined) startRowWait(row);
    },
    // Save this row now, if it waits to save. The cost box calls this
    // when the person leaves it or presses Enter, so "type, then click
    // away" saves at once: the wait only spans pauses while the cost
    // box still has focus.
    saveBillRowNow(row: BillNode) {
      if (self.billsSaveTimers[row.id] !== undefined) {
        self.sendBillRow(row, false);
      }
    },
    // Build this row's save and send it. With nothing to send, the meal
    // on screen may be waiting for nothing more before a fetch.
    sendBillRow(row: BillNode, keepalive: boolean) {
      stopRowWait(row.id);
      const save = rowSave(row, false, keepalive);
      if (save === null) {
        self.afterBillsIdle();
        return;
      }
      self.sendBillsSave(save);
    },
    // The page is being hidden or closed (#150): the browser fired
    // visibilitychange to hidden, or pagehide. On a phone that is the
    // last event the page can count on, so every row that waits to save
    // is sent now, with fetch keepalive, which can finish after the page
    // is gone. If the page stays open, the answers are handled as usual.
    sendBillsBeforeHidden() {
      rowsWaiting().forEach((row) => self.sendBillRow(row, true));
    },
    // Logout, Refresh and the error page's Refresh call this before they
    // reload the page, which ends every request on its way. The cook
    // rows freeze, and every row with an edit the server does not have
    // is sent now. The wait ends once no bills save is on its way and no
    // row waits to save, or after BILLS_WAIT_BEFORE_RELOAD_MS, whichever
    // comes first. The promise then says whether the page may reload:
    //
    // - true when no save the page waited for failed. The rows stay
    //   frozen until the reload. A save still on its way after the 5
    //   seconds is sent again now with keepalive
    //   (sendBillsAgainBeforeClose): WebKit ends it as soon as the reload
    //   starts, before the page fires pagehide, and logout takes the
    //   token away right after this. It may or may not be written, and
    //   nothing tells the person.
    // - false when one of them was not saved, or may not have been
    //   (billsFailuresShown). The message is on screen, and a reload
    //   would take it away before the person could read it, so the page
    //   stays and the rows take edits again. The next tap goes on.
    finishBillsSaves(): Promise<boolean> {
      self.waitingToReload = true;
      const failuresBefore = self.billsFailuresShown;
      sendEveryRowNow(false);
      return when(
        () =>
          self.billsSavesOnTheirWay.length === 0 &&
          Object.keys(self.billsSaveTimers).length === 0,
        { timeout: BILLS_WAIT_BEFORE_RELOAD_MS },
      ).then(
        () => self.endReloadWait(failuresBefore),
        () => self.endReloadWait(failuresBefore),
      );
    },
    // The wait before a reload ended (finishBillsSaves). Answers whether
    // the page may reload.
    endReloadWait(failuresBefore: number): boolean {
      const mayReload = self.billsFailuresShown === failuresBefore;
      self.waitingToReload = mayReload;
      if (mayReload) self.sendBillsAgainBeforeClose();
      return mayReload;
    },
    // The page is about to reload or close (#150): a reload the page
    // makes itself (endReloadWait, and the reload after a chunk fails to
    // load, lazy_retry.ts), or pagehide when the browser does not keep
    // the page in its back-forward cache. A save on its way went by
    // XMLHttpRequest, which the browser ends with the page, so the save
    // may never reach the server. WebKit ends it as soon as a reload
    // starts, before pagehide, so a reload the page makes itself does
    // this first. Each one is sent again now, unchanged, with fetch
    // keepalive, which can finish after the page is gone. It has the same key, so if the first try was written, the
    // server answers this one as replayed and writes nothing more. A save
    // that went with keepalive already is not sent again.
    //
    // The page does not read the answer: it will be gone. If it stays
    // open after all, the first try's answer is the one it reads, and a
    // failure of this one is only logged.
    sendBillsAgainBeforeClose() {
      const again = self.billsSavesOnTheirWay.filter((save) => !save.keepalive);
      self.billsSavesOnTheirWay = self.billsSavesOnTheirWay.map((save) => ({
        ...save,
        keepalive: true,
      }));
      again.forEach((save) => {
        api.meals
          .updateBills(save.mealId, {
            edits: save.edits,
            key: save.key,
            socketId: window.Comeals.socketId,
            keepalive: true,
          })
          .catch((error: unknown) => {
            handleAxiosError(error, { silent: true });
          });
      });
    },
    // switchMeals and teardownMealPage call this first: the person is
    // leaving the meal on screen, and its rows are about to be cleared.
    // Each row that shows an edit the server does not have is saved now,
    // to this meal, whether it waits to save or its save was refused
    // before it could be sent (one cook in two rows). It never goes to
    // the next meal. A row whose save is on its way takes no edits, so
    // it has nothing more to send. If one cook is still picked in two
    // rows, that row's save cannot be built, and the message names this
    // meal.
    saveBillsBeforeLeaving() {
      // The "may not have been saved" message about this meal says to
      // check the costs "when the meal shows again", which is about the
      // meal on screen. The person is leaving it, so the message that
      // names the meal takes its place (#137).
      const maybeOnScreen = inStack(self.billsMaybeOnScreen);
      self.billsMaybeOnScreen = null;
      if (maybeOnScreen !== null) {
        toastStore.remove(maybeOnScreen.toastId);
        self.showBillsMaybeNotSaved(maybeOnScreen);
      }

      sendEveryRowNow(true);
    },
    // Send a new save: its first try. Its row shows a spinner if it is
    // still on its way after BILL_ROW_SPINNER_WAIT_MS. A second try is
    // sent by postBillsSave alone, so it keeps the first try's wait: the
    // spinner shows one second after the save was first sent.
    sendBillsSave(save: BillsSave) {
      setTimeout(function () {
        self.markBillsSaveSlow(save.key);
      }, BILL_ROW_SPINNER_WAIT_MS);
      self.postBillsSave(save);
    },
    // Send a try of this save and handle its answer. Until the answer
    // comes, the save is on its way, in place of an earlier try with the
    // same key.
    postBillsSave(save: BillsSave) {
      self.billsSavesOnTheirWay = [
        ...self.billsSavesOnTheirWay.filter((other) => other.key !== save.key),
        save,
      ];

      api.meals
        .updateBills(save.mealId, {
          edits: save.edits,
          key: save.key,
          socketId: window.Comeals.socketId,
          keepalive: save.keepalive,
        })
        .then(
          function (response) {
            // The server saved the bills, so the cached meal payload is
            // now stale (issue #37).
            evictMealCache(save.mealId);
            const answer: BillsAck | undefined = response.data;
            if (answer?.type === "warning") showWarning(answer, save);
            checkAnswer(answer, save);
            self.settleBillsSave(save);
          },
          function (error: unknown) {
            self.billsSaveFailed(save, error);
          },
        );
    },
    // The save has been on its way for BILL_ROW_SPINNER_WAIT_MS, unless
    // it was answered by now.
    markBillsSaveSlow(key: string) {
      if (!self.billsSavesOnTheirWay.some((save) => save.key === key)) return;
      self.billsSlowSaveKeys = [...self.billsSlowSaveKeys, key];
    },
    // A bills save failed. Decision 7 of #135: a failure that may not be
    // final sends the same save once more, and its row stays locked
    // until that try is answered. A base is never moved back: the row's
    // next save is built on it, and the server checks that save's
    // `from`.
    billsSaveFailed(save: BillsSave, error: unknown) {
      // The person may have left the meal while the save waited for
      // the server's answer. The message then shows on another meal or
      // on the calendar, so it names the meal (#107).
      const mealLeft = !self.meal || self.meal.id !== save.mealId;

      if (!save.secondTry && worthSendingAgain(error)) {
        // Nothing shows yet: the second try may work. The first
        // failure is only logged.
        handleAxiosError(error, { silent: true });
        self.postBillsSave({ ...save, secondTry: true });
        return;
      }

      // Every way on from here shows the person a message about it.
      self.billsFailuresShown += 1;

      if (mealLeft) {
        // The server's words are only logged: they do not say which
        // meal they are about.
        handleAxiosError(error, { silent: true });
        // Every failure is shown, even when another save for this meal
        // worked (see billsNotSaved). Only a second try gets no answer
        // from the app here, as below.
        const meal = { mealId: save.mealId, mealDay: save.mealDay };
        if (noAnswerFromApp(error)) {
          self.showBillsMaybeNotSaved(meal);
        } else {
          self.showBillsNotSaved({
            ...meal,
            settled: answerIn(error)?.message === SETTLED_MEAL_REFUSAL,
          });
        }
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
        self.billsMaybeOnScreen = {
          toastId: toastStore.show(MAYBE_NOT_SAVED, "error"),
          mealId: save.mealId,
          mealDay: save.mealDay,
        };
      } else {
        handleAxiosError(error);
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
      // for the meal, so a cost another row waits to save is sent first
      // (#136). A save for a meal the person left did not change the
      // rows on screen, so that meal is not loaded.
      if (!mealLeft) self.loadMealAgain();
      self.settleBillsSave(save);
    },
    // A save for a meal the person left was not saved. Show the message
    // that names it, with the meals the message on screen already names
    // if that message still shows (see billsNotSaved). A meal the
    // message already names keeps its place, and keeps the settled words
    // once a save for it was refused as settled (see MealNotSaved).
    showBillsNotSaved(meal: MealNotSaved) {
      unnameMaybe(meal.mealId);
      const earlier = inStack(self.billsNotSaved);
      const named = earlier?.meals ?? [];
      const meals = named.some((other) => other.mealId === meal.mealId)
        ? named.map((other) =>
            other.mealId === meal.mealId
              ? { ...meal, settled: other.settled || meal.settled }
              : other,
          )
        : [...named, meal];
      self.billsNotSaved = {
        toastId: showInPlaceOf(earlier, notSavedMessage(meals)),
        meals,
      };
    },
    // A save for a meal the person left may have been written: its
    // second try got no answer from the app. Show the message that says
    // so and names it, with the meals that message already names if it
    // is still in the stack (see billsMaybeNotSaved). A meal the "not
    // saved" message names goes there instead.
    showBillsMaybeNotSaved(meal: MealNamed) {
      if (
        inStack(self.billsNotSaved)?.meals.some(
          (named) => named.mealId === meal.mealId,
        )
      ) {
        self.showBillsNotSaved({
          mealId: meal.mealId,
          mealDay: meal.mealDay,
          settled: false,
        });
        return;
      }
      const earlier = inStack(self.billsMaybeNotSaved);
      const named = earlier?.meals ?? [];
      const meals = named.some((other) => other.mealId === meal.mealId)
        ? named
        : [...named, { mealId: meal.mealId, mealDay: meal.mealDay }];
      self.billsMaybeNotSaved = {
        toastId: showInPlaceOf(earlier, maybeNotSavedMessage(meals)),
        meals,
      };
    },
    // The rows on screen changed: an edit, or the rows were cleared or
    // built again. If the message that a cook is picked in two rows is
    // still in the stack, and the rows no longer show that cook twice,
    // the page sees the cause fixed, so the message goes (#137). If
    // another cook is in two rows now, the next save says so.
    dropFixedCookInTwoRows() {
      const shown = self.billsCookInTwoRows;
      if (shown === null) return;
      const rows = Array.from(self.bills.values()).filter(
        (bill) => bill.resident_id === shown.cookId,
      );
      if (rows.length > 1) return;
      toastStore.remove(shown.toastId);
      self.billsCookInTwoRows = null;
    },
    // The answer to a save that was written. It changes no row: the
    // row's base moved when the save was built, and the row took no
    // edit while the save was on its way. It is checked instead. The
    // server reads the bills right after the save's writes, in the same
    // transaction, so each cook the save named must show what the save
    // sent, and a cook it removed must be gone. A replayed answer holds
    // the bills as stored now, and someone may have saved since the
    // first try, so a difference there is not a bug. Either way the rows
    // on screen may not be what the server has, so the meal loads again.
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
    // The save was answered, and its row is free again. The meal on
    // screen is fetched if it was waiting for its saves and now waits
    // for nothing more.
    settleBillsSave(save: BillsSave) {
      self.billsSavesOnTheirWay = self.billsSavesOnTheirWay.filter(
        (other) => other.key !== save.key,
      );
      self.billsSlowSaveKeys = self.billsSlowSaveKeys.filter(
        (key) => key !== save.key,
      );
      self.afterBillsIdle();
    },
    // True while this page has a bills edit for the meal that the server
    // may not have yet: sent and not answered, in a row's wait before
    // its save, or on a row that differs from its base with no save to
    // carry it. While it is true, the meal's rows must not be built
    // again from the server (#136): the server's answer may be older
    // than the edit, and new rows would drop it, so no save would ever
    // send it.
    //
    // While the meal on screen loads again after a failed save, a row
    // that differs from its base and does not wait to save does not
    // count. Its edit was refused before it could be sent (one cook in
    // two rows), and the rows are frozen until the meal loads, so nobody
    // could change it, and waiting for it would keep the meal from ever
    // loading.
    billsPendingFor(mealId: number): boolean {
      if (self.billsSavesOnTheirWay.some((save) => save.mealId === mealId)) {
        return true;
      }
      // The waits and the rows are always about the meal on screen.
      if (self.meal?.id !== mealId) return false;
      return (
        Object.keys(self.billsSaveTimers).length > 0 ||
        (!self.mealLoading &&
          Array.from(self.bills.values()).some((bill) => bill.unsent))
      );
    },
  };
}
