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
    incrementExtras(): void;
  } | null;
  appendGuest(guest: Omit<Guest, "created_at"> & { created_at: Date }): void;
  sendGuestAdd(add: GuestAdd): void;
  guestAddAnswered(add: GuestAdd, data: Guest | GuestReplayed): void;
  guestAddFailed(add: GuestAdd, key: string, error: unknown): void;
  takeGuestAddKey(add: GuestAdd): string;
  keepGuestAddKey(add: GuestAdd, key: string): void;
}

// The adds a key can be sent again with: the same meal, host and veg
// choice, which is the same guest to the server.
function sameGuest(add: GuestAdd): string {
  return `${add.mealId}:${add.hostId}:${add.vegetarian}`;
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
  };
}

export function guestAddsActions(self: GuestAddsStore) {
  return {
    // Send one guest add, with the oldest key in doubt for the same
    // guest, or a new key. The row took the seat on screen at the tap.
    sendGuestAdd(add: GuestAdd) {
      const key = self.takeGuestAddKey(add);
      api.meals.residents.guests
        .add(add.mealId, add.hostId, {
          vegetarian: add.vegetarian,
          key,
          socketId: window.Comeals.socketId,
        })
        .then(
          function (response) {
            // The server has the guest, so the copy of the meal on the
            // device is out of date (issue #37).
            evictMealCache(add.mealId);
            self.guestAddAnswered(add, response.data);
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
    guestAddAnswered(add: GuestAdd, data: Guest | GuestReplayed) {
      let guest: Guest;
      if ("type" in data) {
        if (data.guest === null || add.guestIdsAtTap.includes(data.guest.id)) {
          self.sendGuestAdd(add);
          return;
        }
        guest = data.guest;
      } else {
        guest = data;
      }
      if (!isAlive(add.row)) {
        // The meal was loaded again while the add was out, perhaps
        // before the guest was written. Load it again to show it.
        // Without this the person taps again and makes a second guest.
        self.loadDataAsync();
        return;
      }
      self.appendGuest({ ...guest, created_at: new Date(guest.created_at) });
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
      // The seat the tap took goes back, while the rows on screen are
      // the ones that were tapped. Rows built again since show the
      // server's seat count already.
      if (isAlive(add.row)) self.meal?.incrementExtras();
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
