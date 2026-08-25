// The bill save pipeline (issue #30): debounce, single-flight,
// version-guarded acks. One of the DataStore's subsystem files — see
// data_store.js, which composes them.
import { Instance } from "mobx-state-tree";

import { api, BillInput } from "../helpers/api";
import { SAVE_DEBOUNCE_MS } from "../helpers/helpers";
import { toDisplayAmountString } from "../helpers/money";
import { evictMealCache } from "../helpers/meal_cache";
import handleAxiosError from "../helpers/handle_axios_error";
import createVersionGuard from "../helpers/version_guard";
import { BillsAck } from "../types/api";
import Bill from "./bill";
import toastStore from "./toast_store";

type BillNode = Instance<typeof Bill>;

// The warning the bills endpoint answers with when a cook-scheduling guard
// refused part of the write but the rest was saved. Read by shape, not by
// class: the response is what the server put in the body, whatever object
// carried it.
function warningIn(error: unknown): BillsAck | null {
  const response = (error as { response?: { data?: BillsAck } } | null)
    ?.response;
  return response?.data?.type === "warning" ? response.data : null;
}

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript): its own volatile fields, the rows and
// flags it saves, and the actions it defines and calls on itself.
export interface BillsStore extends ReturnType<typeof billsVolatile> {
  meal: { id: number } | null;
  bills: { values(): IterableIterator<BillNode> };
  editBillsMode: boolean;
  loadDataAsync(): void;
  flushBillsSave(): void;
  submitBills(): void;
  applyBillsAck(
    data: BillsAck,
    versionAtSend: number,
    mealIdAtSend: number,
  ): void;
  settleBillsSave(mealIdAtSend: number): void;
}

export function billsVolatile() {
  return {
    // Pending debounce timer for a bill save, or null.
    billsSaveTimer: null as ReturnType<typeof setTimeout> | null,
    // True while a bills request is in flight. With one request at a time,
    // this client's writes cannot arrive at the server out of order.
    billsSaveInFlight: false,
    // A save was requested while one was in flight; send one more request
    // with the latest state when it settles.
    billsSaveQueued: false,
    // Stale-response guard for bill saves: bumped on every bill edit,
    // captured at send; an ack applies only if nothing was typed since.
    billsEdits: createVersionGuard(),
  };
}

export function billsActions(self: BillsStore) {
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
    // Send a pending debounced save right now. Blur and meal navigation
    // call this, so "type, then click away" saves immediately — the
    // debounce only spans pauses while the field still has focus. Without
    // this, closing the tab inside the debounce window would lose the
    // edit.
    flushPendingBillsSave() {
      if (self.billsSaveTimer !== null) {
        self.submitBills();
      }
    },
    submitBills() {
      // A direct submit (save button, meal switch) supersedes a pending
      // debounced save — it sends the same latest state now.
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
        self.billsSaveTimer = null;
      }

      // No meal, nothing to save to. The timer above is already
      // cancelled, so a save that outlived the meal page ends here.
      if (!self.meal) {
        return;
      }

      // Only touched rows carry values to the server, so only they can
      // block the save.
      if (
        Array.from(self.bills.values()).some(
          (bill) => bill.touched && bill.amountIsValid === false,
        )
      ) {
        self.editBillsMode = true;
        return;
      }

      // Single-flight: one request at a time. The queued resend in
      // settleBillsSave sends whatever was edited meanwhile.
      if (self.billsSaveInFlight) {
        self.billsSaveQueued = true;
        return;
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

      const versionAtSend = self.billsEdits.current();
      const mealIdAtSend = self.meal.id;
      self.billsSaveInFlight = true;

      api.meals
        .updateBills(mealIdAtSend, {
          bills,
          socketId: window.Comeals.socketId,
        })
        .then(function (response) {
          // The server saved the bills, so the cached meal payload is
          // now stale (issue #37).
          evictMealCache(mealIdAtSend);
          self.applyBillsAck(response.data, versionAtSend, mealIdAtSend);
        })
        .catch(function (error: unknown) {
          const warning = warningIn(error);
          if (warning) {
            // A warning response still persisted the bills — evict, same
            // as the success path.
            evictMealCache(mealIdAtSend);
            const msg = warning.message || "";
            toastStore.replaceAll(
              "Cooks saved." + (msg ? " " + msg : ""),
              "info",
            );
          } else {
            handleAxiosError(error);
          }

          self.loadDataAsync();
        })
        .then(function () {
          self.settleBillsSave(mealIdAtSend);
        });
    },
    // Display what the server stored, not what we sent — but only when the
    // rows on screen are the rows this ack answers: same meal, and no edits
    // since the request went out. Otherwise ignore it; the queued next save
    // covers the newer edits and its own ack will reconcile.
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
    settleBillsSave(mealIdAtSend: number) {
      self.billsSaveInFlight = false;
      if (!self.billsSaveQueued) return;
      self.billsSaveQueued = false;
      // The queued edit was typed on the meal the last save targeted. If
      // the user switched meals while the request was in flight, the rows
      // it came from are gone — there is nothing valid to resend.
      if (!self.meal || self.meal.id !== mealIdAtSend) return;
      self.submitBills();
    },
  };
}
