// Guest adds and their Idempotency-Keys (S2). One of the DataStore's
// subsystem files — see data_store.js, which composes them.
//
// A guest add whose answer is lost may have been written. The page shows
// no guest then, so the person taps again, and a new add would make a
// second guest: the host would pay twice. So each add carries an
// Idempotency-Key, and the tap after an add that got no answer from the
// app sends that add's key again (public/api.md, "Guests").
// The server keeps the key of each add it wrote, and answers a key it has
// seen as already done, with the guest that add made.
//
// Nothing on the page changes at the tap. When the server says yes, the
// guest shows and its seat goes in one step, so Extras, Total and the
// cap always agree (S4). While a host's add waits, that host's
// add-guest control takes no taps, so a second tap cannot send a second
// guest. That also covers an add on a dead connection, which waits 35
// seconds before its key is kept for the next tap. And while an add
// waits, the seat it asks for is not open to other taps on the screen
// (Meal#openSeats), or the server would take the guest and refuse the
// other tap, and in between the page would show Total over the cap.
import { IAnyStateTreeNode, isAlive } from "mobx-state-tree";

import { api } from "../helpers/api";
import { notifyError } from "../helpers/bugsnag";
import { evictMealCache } from "../helpers/meal_cache";
import { newId } from "../helpers/new_id";
import {
  noAnswerFromApp,
  showSignupFailure,
  SignupStore,
  Tapped,
} from "../helpers/signup_failure";
import { Guest, GuestReplayed } from "../types/api";

// One tap on a host's add-guest choice: what it asks for, and what the
// page knew when it was tapped.
export interface GuestAdd {
  // The row that was tapped. It is not alive any more once the meal was
  // loaded again, which builds every row again.
  row: IAnyStateTreeNode;
  mealId: number;
  hostId: number;
  vegetarian: boolean;
  tapped: Tapped;
  // The host's guests on screen at the tap. A tap is for one guest more
  // than these.
  guestIdsAtTap: number[];
}

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript).
export interface GuestAddsStore
  extends ReturnType<typeof guestAddsVolatile>, SignupStore {
  meal: {
    id: number;
    decrementExtras(): void;
  } | null;
  guests: { has(key: string): boolean };
  appendGuest(guest: Omit<Guest, "created_at"> & { created_at: Date }): void;
  // From data_store_signup_requests.ts.
  waitForSignupRequest<T>(mealId: number, request: Promise<T>): Promise<T>;
  // This file's own views and actions.
  guestAddWaiting(mealId: number, hostId: number): boolean;
  guestAddsWaitingOn(mealId: number): number;
  endGuestAdd(add: GuestAdd): void;
  sendGuestAdd(add: GuestAdd): Promise<void>;
  guestAddAnswered(
    add: GuestAdd,
    data: Guest | GuestReplayed,
  ): Promise<void> | undefined;
  guestAddFailed(add: GuestAdd, key: string, error: unknown): void;
  takeGuestAddKey(add: GuestAdd): string;
  keepGuestAddKey(add: GuestAdd, key: string): void;
}

// The adds a key can be sent again with: the same meal, host and veg
// choice, which is the same guest to the server.
function sameGuest(add: GuestAdd): string {
  return `${add.mealId}:${add.hostId}:${add.vegetarian}`;
}

// The host of an add, on its meal.
function hostOf(mealId: number, hostId: number): string {
  return `${mealId}:${hostId}`;
}

export function guestAddsVolatile() {
  return {
    // The keys of guest adds that got no answer from the app, oldest
    // first, by sameGuest. Each may have been written. The next tap that
    // asks for the same guest takes the oldest one and sends it again,
    // so one lost add is sent again by one tap only. The key comes back
    // here when that add gets no answer from the app again. Kept for as
    // long as the page is open: a key the server no longer has (it keeps
    // them 7 days) is a new add, which is what the tap asks for then.
    guestAddKeysInDoubt: {} as Record<string, string[]>,
    // The hosts whose guest add has no answer yet, by hostOf. Kept here,
    // not on the host's row: a load builds every row again while the add
    // is out, and the new row may not show its guest yet.
    guestAddsWaiting: [] as string[],
  };
}

export function guestAddsViews(self: GuestAddsStore) {
  return {
    guestAddWaiting(mealId: number, hostId: number): boolean {
      return self.guestAddsWaiting.includes(hostOf(mealId, hostId));
    },
    // How many guest adds on the meal wait: one at most for each host.
    guestAddsWaitingOn(mealId: number): number {
      return self.guestAddsWaiting.filter((host) =>
        host.startsWith(`${mealId}:`),
      ).length;
    },
  };
}

export function guestAddsActions(self: GuestAddsStore) {
  return {
    // A tap on a host's add-guest choice. It does nothing while an add
    // for the same host on the same meal waits. The add waits until its
    // last answer: an answer can send it again (guestAddAnswered).
    startGuestAdd(add: GuestAdd) {
      if (self.guestAddWaiting(add.mealId, add.hostId)) return;
      self.guestAddsWaiting = [
        ...self.guestAddsWaiting,
        hostOf(add.mealId, add.hostId),
      ];
      self.sendGuestAdd(add).finally(function () {
        self.endGuestAdd(add);
      });
    },
    endGuestAdd(add: GuestAdd) {
      const host = hostOf(add.mealId, add.hostId);
      self.guestAddsWaiting = self.guestAddsWaiting.filter(
        (waiting) => waiting !== host,
      );
    },
    // Send one guest add, with the oldest key in doubt for the same
    // guest, or a new key. Settles once the add has its last answer.
    sendGuestAdd(add: GuestAdd): Promise<void> {
      const key = self.takeGuestAddKey(add);
      return self
        .waitForSignupRequest(
          add.mealId,
          api.meals.residents.guests.add(add.mealId, add.hostId, {
            vegetarian: add.vegetarian,
            key,
            socketId: window.Comeals.socketId,
          }),
        )
        .then(
          function (response) {
            // The server has the guest, so the copy of the meal on the
            // device is out of date (issue #37).
            evictMealCache(add.mealId);
            return self.guestAddAnswered(add, response.data);
          },
          function (error: unknown) {
            self.guestAddFailed(add, key, error);
          },
        );
    },
    // The server added the guest, or had added it for an earlier tap
    // whose answer was lost ("replayed"). A replayed guest that was not
    // on screen at the tap is the guest this tap asked for. If it was on
    // screen, the tap was for one guest more, and if it is null (it was
    // removed since, or given to another host or meal), the tap was for
    // a guest: either way a new add goes out.
    guestAddAnswered(
      add: GuestAdd,
      data: Guest | GuestReplayed,
    ): Promise<void> | undefined {
      let guest: Guest;
      if ("type" in data) {
        if (data.guest === null || add.guestIdsAtTap.includes(data.guest.id)) {
          return self.sendGuestAdd(add);
        }
        guest = data.guest;
      } else {
        guest = data;
      }
      if (!isAlive(add.row)) {
        // The meal was loaded again while the add was out, perhaps from
        // a read made before the guest was written. Then the screen does
        // not show the guest, and its seat is not counted: loadData
        // works out Extras from the same answer's guests. So the guest
        // shows now, with its seat, or the person would tap again and
        // make a second guest. The meal still loads again, to show what
        // else the server has.
        if (
          self.meal?.id === add.mealId &&
          !self.guests.has(String(guest.id))
        ) {
          self.appendGuest({
            ...guest,
            created_at: new Date(guest.created_at),
          });
          self.meal.decrementExtras();
        }
        self.reloadAfterSignupRequest(add.mealId);
        return;
      }
      // The guest and its seat in one action, so Extras, Total and the
      // cap change together. While the tapped row is alive, the meal on
      // screen is the add's meal.
      self.appendGuest({ ...guest, created_at: new Date(guest.created_at) });
      self.meal?.decrementExtras();
    },
    guestAddFailed(add: GuestAdd, key: string, error: unknown) {
      if (noAnswerFromApp(error)) self.keepGuestAddKey(add, key);
      // A 422 means this page sent one key with two different adds.
      const status = (error as { response?: { status?: number } } | null)
        ?.response?.status;
      if (status === 422) {
        notifyError(
          new Error(
            `The server refused a guest add for meal ${add.mealId}: its Idempotency-Key was already used for a different guest add`,
          ),
        );
      }
      showSignupFailure(self, add.tapped, error);
    },
    takeGuestAddKey(add: GuestAdd): string {
      const [oldest, ...rest] = self.guestAddKeysInDoubt[sameGuest(add)] ?? [];
      if (oldest === undefined) return newId();
      self.guestAddKeysInDoubt = {
        ...self.guestAddKeysInDoubt,
        [sameGuest(add)]: rest,
      };
      return oldest;
    },
    keepGuestAddKey(add: GuestAdd, key: string) {
      const kept = self.guestAddKeysInDoubt[sameGuest(add)] ?? [];
      self.guestAddKeysInDoubt = {
        ...self.guestAddKeysInDoubt,
        [sameGuest(add)]: [...kept, key],
      };
    },
  };
}
