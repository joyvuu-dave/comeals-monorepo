// The meal page: loading a meal's rows (from IndexedDB, then the
// server), the retry backoff for a failed first load, the menu
// description plumbing, open/close, and the page teardown. One of the
// DataStore's subsystem files — see data_store.js, which composes them.
import {
  isAlive,
  IMSTArray,
  IMSTMap,
  Instance,
  SnapshotIn,
} from "mobx-state-tree";
import { newId } from "../helpers/new_id";
import { get as kvGet, set as kvSet, del as kvDel } from "idb-keyval";

import { api } from "../helpers/api";
import { toCommunityDayjs } from "../helpers/helpers";
import { toDisplayAmountString } from "../helpers/money";
import handleAxiosError from "../helpers/handle_axios_error";
import { notifyError } from "../helpers/bugsnag";
import createVersionGuard from "../helpers/version_guard";
import { MealForm } from "../types/api";
import Bill from "./bill";
import Guest from "./guest";
import Meal from "./meal";
import Resident from "./resident";

type MealNode = Instance<typeof Meal>;

// Where the meal data handed to loadData came from: the server's answer,
// or the copy of an earlier answer saved on the device (IndexedDB).
type MealFormSource = "server" | "device";

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript): its own volatile fields, the meal on
// screen and its rows, the loading flags, two actions from other
// subsystems, and the actions it defines and calls on itself.
export interface MealPageStore extends ReturnType<typeof mealPageVolatile> {
  // A reference: read as the node, written with the node's id.
  get meal(): MealNode | null;
  set meal(value: MealNode | number | null);
  meals: IMSTArray<typeof Meal>;
  residents: IMSTMap<typeof Resident>;
  guests: IMSTMap<typeof Guest>;
  bills: IMSTMap<typeof Bill>;
  mealLoading: boolean;
  mealLoadFailed: boolean;
  mealLoadNotFound: boolean;
  closedPending: boolean;
  saveBillsBeforeLeaving(): void;
  ensureResidentsChannel(): void;
  settleClosed(): void;
  loadDataAsync(): void;
  handleMealLoadError(error: unknown, mealId: number): void;
  handleMealProcessingError(error: unknown, mealId: number): void;
  scheduleMealRetry(mealId: number): void;
  onMealRetryTimer(mealId: number): void;
  cancelMealRetry(): void;
  preLoadData(): void;
  loadData(data: MealForm, source: MealFormSource): void;
  watchMealChannel(mealId: number): void;
  clearResidents(): void;
  clearBills(): void;
  clearGuests(): void;
  addMeal(snapshot: SnapshotIn<typeof Meal>): void;
  switchMeals(id: number): void;
}

// The HTTP status a failed request answered with, if it answered at all.
// Read by shape: the object the client rejects with is what carries it.
function statusIn(error: unknown): number | undefined {
  return (error as { response?: { status?: number } } | null)?.response?.status;
}

// Backoff for retrying a failed FIRST load of a meal: 2s, 4s, 8s,
// 16s, then every 30s — forever. A shared screen must heal without a
// human tap, and at 30s the retries cost the server nothing.
const MEAL_RETRY_BASE_MS = 2000;
const MEAL_RETRY_CAP_MS = 30000;

export function mealPageVolatile() {
  return {
    // Pending timer for the next automatic meal-load retry, or null.
    mealRetryTimer: null as ReturnType<typeof setTimeout> | null,
    // The wait used for the last scheduled retry, or null when the
    // backoff is at its starting point.
    mealRetryDelayMs: null as number | null,
    // The first load of the meal on screen got an answer the page could
    // not use. That is a bug, not a network state, so nothing retries;
    // LoadStatus says so and offers the way back (#110).
    mealLoadBroken: false,
    // Stale-response guard for meal fetches. Two fetches of the same
    // meal can be on the wire at once (a Pusher update during a
    // reconnect refetch), and the responses can land in either order;
    // only the newest fetch's response may reach the screen.
    mealFetches: createVersionGuard(),
    // The meal has a bill whose cook is not in the residents list, so
    // the page cannot show that bill (#91). While this is true, no
    // bills save is built from the rows (data_store_bills.ts): a save
    // lists every cook, and the server deletes the bill of a cook left
    // out. loadData sets it, and clearBills sets it back to false with
    // the rows.
    billsIncomplete: false,
  };
}

export function mealPageActions(self: MealPageStore) {
  return {
    // The description save pipeline lives on the meal node (issue #35),
    // so unsaved text stays protected even after the user navigates to
    // another meal. The menu box binds these two actions to the node it
    // rendered: a debounced flush that fires after a meal switch must
    // land on the meal the text was typed on — landing on store.meal
    // silently replaced the NEW meal's menu.
    setDescriptionOn(node: MealNode | null, val: string) {
      if (!node || !isAlive(node)) return;
      node.setDescription(val);
    },
    // Called on every keystroke, before any flush: a dirty node
    // survives the switchMeals prune, so its text still has a live
    // node to land on.
    noteMenuTyping(node: MealNode | null) {
      if (!node || !isAlive(node)) return;
      node.markDescriptionEditing();
    },
    // Resend unsaved menu text (issue #35). handleReconnect calls
    // this: most description save failures are network blips, so the
    // retry usually clears the "not saved" marker without the user
    // doing anything.
    retryDirtyDescriptions() {
      self.meals.forEach(function (meal) {
        if (meal.descriptionDirty) {
          meal.submitDescription();
        }
      });
    },
    // Runs when the open/close save settles — success or failure. The
    // refetch lets loadData write the server's truth, including the
    // server's closed_at (the client clock is never used). There is no
    // rollback on purpose: the meal node is edited in place by refetches,
    // so a blind flip could invert fresh data.
    settleClosed() {
      self.closedPending = false;
      self.loadDataAsync();
    },
    // Closing no longer requires costs to be filled in. Forcing a
    // number before the shopping happened bred fake $1 costs; the close
    // button asks about blank costs (cooksMissingCost) and the cook
    // closes with a deliberate Yes instead. Bills stay editable until
    // reconciliation.
    toggleClosed() {
      if (self.closedPending) {
        return;
      }

      const meal = self.meal;
      if (!meal) return;
      const val = !meal.closed;
      meal.closed = val;
      self.closedPending = true;

      api.meals
        .updateClosed(meal.id, {
          closed: val,
          socketId: window.Comeals.socketId,
        })
        .catch(function (error: unknown) {
          handleAxiosError(error);
        })
        .then(function () {
          self.settleClosed();
        });
    },
    loadDataAsync() {
      // Leaving the meal page nulls the meal (issue #38). A settle
      // callback that lands after that has nothing to refetch.
      if (!self.meal) return;
      const mealIdAtFetch = self.meal.id;
      const fetchToken = self.mealFetches.bump();
      api.meals
        .getCooks(mealIdAtFetch)
        .then(
          function (response) {
            // A newer fetch is out: this answer is older than what
            // that one will bring, so neither cache nor screen gets it.
            if (!self.mealFetches.isCurrent(fetchToken)) return;
            return kvSet(response.data.id.toString(), response.data)
              .catch(function (error: unknown) {
                // The copy on disk only makes the next visit faster. A
                // failed write must not keep the answer off the screen
                // (#111).
                console.error(
                  "IndexedDB failed; going on without the copy on disk:",
                  error,
                );
              })
              .then(function () {
                if (!self.mealFetches.isCurrent(fetchToken)) return;
                // Skip stale responses from a previous meal
                if (self.meal && self.meal.id === response.data.id) {
                  self.loadData(response.data, "server");
                }
              });
          },
          // Second then-handler on purpose: it fires only when the
          // FETCH rejected. The retry treatment is for network
          // failures — a bug while processing a good response must
          // not loop retries forever. The state change comes first:
          // the console logging must not be able to break it.
          function (error: unknown) {
            self.handleMealLoadError(error, mealIdAtFetch);
            handleAxiosError(error, { silent: true });
          },
        )
        .catch(function (error: unknown) {
          self.handleMealProcessingError(error, mealIdAtFetch);
        });
    },
    // A meal fetch failed. Only the FIRST load of the meal on screen
    // gets the retry treatment: with mealLoading false there is data
    // on screen, and background refetch failures already heal through
    // the reconnect and online handlers. A 404 means the meal does
    // not exist — no retry can fix that.
    handleMealLoadError(error: unknown, mealId: number) {
      if (!self.meal || self.meal.id !== mealId) return;
      if (!self.mealLoading) return;
      const status = statusIn(error);
      if (status === 404) {
        self.cancelMealRetry();
        self.mealLoadNotFound = true;
        return;
      }
      self.mealLoadFailed = true;
      self.scheduleMealRetry(mealId);
    },
    // Processing an answer threw. It is a bug, so it goes to Bugsnag,
    // and it must not loop retries. If the meal on screen was still on
    // its first load, the page would say "loading..." forever, so it
    // says what happened instead.
    handleMealProcessingError(error: unknown, mealId: number) {
      console.error("Could not use the meal from the server:", error);
      notifyError(error);
      if (!self.meal || self.meal.id !== mealId) return;
      if (!self.mealLoading) return;
      self.cancelMealRetry();
      self.mealLoadBroken = true;
    },
    scheduleMealRetry(mealId: number) {
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
      }
      self.mealRetryDelayMs =
        self.mealRetryDelayMs === null
          ? MEAL_RETRY_BASE_MS
          : Math.min(self.mealRetryDelayMs * 2, MEAL_RETRY_CAP_MS);
      self.mealRetryTimer = setTimeout(function () {
        self.onMealRetryTimer(mealId);
      }, self.mealRetryDelayMs);
    },
    onMealRetryTimer(mealId: number) {
      self.mealRetryTimer = null;
      // The screen may have moved on while the timer waited.
      if (!self.meal || self.meal.id !== mealId) return;
      if (!self.mealLoading) return;
      self.loadDataAsync();
    },
    // The "Retry now" button. Resets the backoff: a person is watching
    // now, so if this try also fails the next automatic one should
    // come quickly again.
    retryMealLoadNow() {
      if (!self.meal || !self.mealLoading) return;
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
        self.mealRetryTimer = null;
      }
      self.mealRetryDelayMs = null;
      self.loadDataAsync();
    },
    // Cancels any pending retry and forgets the failure. Runs when the
    // meal on screen changes (switch, teardown) and when a load lands.
    cancelMealRetry() {
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
        self.mealRetryTimer = null;
      }
      self.mealRetryDelayMs = null;
      self.mealLoadFailed = false;
      self.mealLoadNotFound = false;
      self.mealLoadBroken = false;
    },
    preLoadData() {
      self.clearBills();
      self.clearResidents();
      self.clearGuests();
    },
    loadData(data: MealForm, source: MealFormSource) {
      self.preLoadData();
      const meal = self.meal;
      if (!meal) return;

      // Assign Meal Data — construct a "fake local" Date whose year/month/day
      // components come from the community's timezone so that dayjs(meal.date)
      // always reflects the community day, consistent with getCommunityNow()
      // in calendar/show.jsx.
      const d = toCommunityDayjs(data.date);
      meal.date = new Date(d.year(), d.month(), d.date());
      // While the menu has unsaved typing, a reload must not overwrite it
      // (issue #35): your text wins on your own screen until it saves.
      // After it saves, last-write-wins as usual.
      if (!meal.descriptionDirty) {
        meal.description = data.description;
      }
      meal.closed = data.closed;
      meal.closed_at = data.closed_at ? new Date(data.closed_at) : null;
      meal.reconciled = data.reconciled;
      meal.nextId = data.next_id;
      meal.prevId = data.prev_id;

      if (data.max === null) {
        meal.extras = null;
      } else {
        const residentsCount = data.residents.filter(
          (resident) => resident.attending,
        ).length;

        const guestsCount = data.guests.length;
        meal.extras = data.max - (residentsCount + guestsCount);
      }

      // Copies, not the wire rows: the payload may be the IndexedDB
      // copy, which must stay as the server sent it.
      const residents = [...data.residents].sort((a, b) => {
        if (a.name < b.name) return -1;
        if (a.name > b.name) return 1;
        return 0;
      });

      // Assign Residents
      residents.forEach((resident) => {
        self.residents
          .put({
            ...resident,
            attending_at:
              resident.attending_at === null
                ? null
                : new Date(resident.attending_at),
          })
          .rememberAttendingAtLoad();
      });

      // Assign Guests
      data.guests.forEach((guest) => {
        self.guests.put({ ...guest, created_at: new Date(guest.created_at) });
      });

      // A bill's row points at its cook's resident row, so a bill whose
      // cook is not in the residents list cannot be shown. The page shows
      // the other bills and refuses every bills save until a load lists
      // every cook (#91). The server lists every cook who has a bill
      // (MealFormSerializer), so in the server's answer this is a bug,
      // and it is reported. In the copy saved on the device it is not
      // reported: a copy saved before the server listed every cook can
      // still be on the device, and the server's answer is fetched right
      // after it.
      const cookListed = (bill: { resident_id: number }) =>
        self.residents.has(String(bill.resident_id));
      const shownBills = data.bills.filter(cookListed);
      const hiddenCookIds = data.bills
        .filter((bill) => !cookListed(bill))
        .map((bill) => bill.resident_id);
      self.billsIncomplete = hiddenCookIds.length > 0;
      if (self.billsIncomplete) {
        console.warn(
          "Bills will not save: these cooks have a bill but are not in the residents list:",
          hiddenCookIds,
        );
        if (source === "server") {
          notifyError(
            new Error(
              `Meal ${meal.id} has bills whose cooks are not in its residents list: ${hiddenCookIds.join(", ")}`,
            ),
          );
        }
      }

      // Assign Bills. The wire's resident_id becomes the `resident`
      // reference. Zero displays as blank ("not filled in yet"); any other
      // amount keeps its exact wire value, zero-padded to two decimals by
      // string edits. Never reformat money through a float — a rounded
      // display value must not exist at all, so it can never reach the
      // ledger. Three rows are always shown, so blanks fill the rest.
      // (types.identifier requires string ids.)
      const bills: SnapshotIn<typeof Bill>[] = shownBills.map((bill) => ({
        id: String(newId()),
        resident: bill.resident_id,
        amount: toDisplayAmountString(bill.amount),
        no_cost: bill.no_cost,
      }));
      const extra = Math.max(3 - bills.length, 0);
      for (let i = 0; i < extra; i += 1) {
        bills.push({ id: String(newId()) });
      }
      bills.forEach((bill) => {
        self.bills.put(bill).rememberLoadedCook();
      });

      // Change loading state. A landed load also ends any retry state:
      // the failure is over and the backoff starts fresh next time.
      self.mealLoading = false;
      self.cancelMealRetry();

      self.watchMealChannel(meal.id);

      // A change to a resident (a new name, retired, can no longer cook)
      // changes the sign-up list and the cook menus. The server sends
      // those changes on the residents channel, not the meal's.
      self.ensureResidentsChannel();
    },
    // Keep this page subscribed to the meal on screen. A refetch of the
    // same meal keeps the channel it has: closing it and opening it
    // again would miss any push sent in between, and every new
    // subscription fetches once more when Pusher confirms it, so it
    // would never stop.
    watchMealChannel(mealId: number) {
      const name = `meal-${mealId}`;
      const open = window.Comeals.mealChannel;
      if (open !== null && open.name === name) return;
      if (open !== null) {
        window.Comeals.pusher.unsubscribe(open.name);
      }
      const channel = window.Comeals.pusher.subscribe(name);
      window.Comeals.mealChannel = channel;
      // The meal changed on the server: fetch it again.
      channel.bind("update", function () {
        self.loadDataAsync();
      });
      // Pusher confirmed the subscription. A push sent before this
      // reached no one, and the meal on screen may have been read before
      // it, so it is fetched once more (#112).
      channel.bind("pusher:subscription_succeeded", function () {
        self.loadDataAsync();
      });
    },
    clearResidents() {
      self.residents.clear();
    },
    clearBills() {
      self.bills.clear();
      self.billsIncomplete = false;
    },
    clearGuests() {
      self.guests.clear();
    },
    appendGuest(obj: SnapshotIn<typeof Guest>) {
      self.guests.put(obj);
    },
    removeGuest(id: number | string) {
      self.guests.delete(id.toString());
    },
    addMeal(obj: SnapshotIn<typeof Meal>) {
      self.meals.push(obj);
    },
    switchMeals(id: number) {
      // A bill edit not sent yet belongs to the meal we are leaving,
      // whether it is in the debounce window or waiting for a save in
      // flight to be answered. Build its save now, while the meal id and
      // the bill rows it was typed on are still current (#107).
      self.saveBillsBeforeLeaving();

      if (typeof self.meals.find((item) => item.id === id) === "undefined") {
        self.addMeal({ id });
      }

      self.meal = id;

      // Prune the nodes left by earlier meals (issue #38): nothing
      // renders them, and they hold stale snapshots. Point self.meal at
      // the new node FIRST — a reference to a destroyed node throws.
      // A node with unsaved menu text stays alive: issue #35 keeps the
      // text on the node until a save lands, and the retry loop reads
      // these nodes.
      self.meals
        .filter((m) => m.id !== id && !m.descriptionDirty)
        .forEach((m) => self.meals.remove(m));

      // The rows belong to the meal we are leaving, so they leave with
      // it (same rule as teardownMealPage). They used to stay on screen
      // until the new meal's data arrived, still editable — and a bill
      // edit made in that window was sent to the NEW meal id with the
      // OLD meal's cook list as the payload. The server deletes cooks
      // left out of that list, so one keystroke during a slow load
      // could rewrite the new meal's bills. saveBillsBeforeLeaving
      // above already built a save of any edit not sent yet, so
      // clearing here cannot lose one.
      self.clearBills();
      self.clearResidents();
      self.clearGuests();

      // A retry belongs to the meal it was scheduled for; the new
      // meal starts with a clean slate and a fresh backoff.
      self.cancelMealRetry();

      kvGet(id.toString())
        .then(function (value) {
          // Skip if user already navigated to a different meal
          if (!self.meal || self.meal.id !== id) return;

          // idb-keyval resolves undefined for a missing key (localforage
          // used to resolve null).
          if (value === null || typeof value === "undefined") {
            self.loadDataAsync();
          } else {
            self.loadData(value as MealForm, "device");
            self.loadDataAsync();
          }
        })
        .catch(function (error: unknown) {
          console.error(
            "Failed to load cached meal data, fetching from server:",
            error,
          );
          kvDel(id.toString()).catch(function () {});
          self.loadDataAsync();
        });
    },
    goToMeal(mealId: number | string) {
      self.mealLoading = true;
      self.switchMeals(Number.parseInt(String(mealId), 10));
    },
    // The calendar page calls this on mount (issue #38). Without it the
    // last meal's channel stayed live forever: every edit to that meal
    // triggered a full background store rebuild from the calendar.
    teardownMealPage() {
      // A bill edit not sent yet belongs to the meal we are leaving.
      // Build its save while the meal and its bill rows are still
      // current — the same step switchMeals takes first.
      self.saveBillsBeforeLeaving();

      if (window.Comeals.mealChannel !== null) {
        window.Comeals.pusher.unsubscribe(window.Comeals.mealChannel.name);
        window.Comeals.mealChannel = null;
      }

      // Null the reference FIRST, then destroy the nodes — a reference
      // to a destroyed node throws. With meal null, a late meal response
      // fails the same-meal guards and is dropped. Nodes with unsaved
      // menu text stay alive, same as the pruning in switchMeals.
      self.meal = null;
      self.meals
        .filter((m) => !m.descriptionDirty)
        .forEach((m) => self.meals.remove(m));

      // The rows belong to the meal, so they leave with it. Rows left
      // behind crashed the meal page on its next mount: the first render
      // showed them before goToMeal ran, and a row read
      // store.meal.reconciled on the null meal (production, 2026-07-22).
      // saveBillsBeforeLeaving above already built a save of any edit
      // not sent yet, so clearing here cannot lose one.
      self.clearBills();
      self.clearResidents();
      self.clearGuests();

      // No meal page, no retry: the timer must not fire on the
      // calendar.
      self.cancelMealRetry();
    },
  };
}
