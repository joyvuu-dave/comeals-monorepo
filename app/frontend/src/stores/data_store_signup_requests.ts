// Requests from the sign-up list that have no answer yet (S4). One of
// the DataStore's subsystem files — see data_store.js, which composes
// them.
//
// A row of the sign-up list sends six requests: a sign-up, a take-off,
// Late, Veg, a guest add and a guest removal. While one of them waits,
// the meal's head count can still change. A cap picked in the Extras
// boxes then is worked out from the head count on the screen
// (Meal#max), so it can be wrong once the answer comes: a cook who
// picks 2 while a guest add waits ends up with 1 extra. So the Extras
// boxes take no picks while any of these requests on the meal waits
// (Meal#extrasLocked). The same is true after a request whose answer
// the screen could not show, until the meal loads again
// (reloadAfterSignupRequest).
//
// A load of the meal that went out before one of these requests was
// answered may have been read before the server wrote it. Its answer
// would take the change off the screen, and the push for the request
// skips this screen, because the request carried this screen's socket
// id. So such an answer is not used, and the meal loads again
// (signupAnswers, read by holdMealAnswer in data_store_meal_page.ts).
import createVersionGuard from "../helpers/version_guard";

// What this file reads and writes on the DataStore it is composed into
// (data_store.js, still JavaScript).
export interface SignupRequestsStore extends ReturnType<
  typeof signupRequestsVolatile
> {
  loadDataAsync(): void;
  signupRequestAnswered(mealId: number): void;
  guestRemovalAnswered(mealId: number, hostId: number): void;
}

// A host on a meal.
function hostOn(mealId: number, hostId: number): string {
  return `${mealId}:${hostId}`;
}

export function signupRequestsVolatile() {
  return {
    // How many requests from the sign-up list have no answer yet, by
    // meal id. A meal with none has no entry. Kept here by meal id, not
    // on the meal's node: leaving a meal drops its node (switchMeals),
    // and its requests can still be waiting when the person comes back.
    signupRequestsWaiting: {} as Record<number, number>,
    // The meals that load again because a request from the sign-up list
    // got an answer the screen could not show: no answer at all, or a
    // yes for a row that a load built again while the request was out.
    // Until the server's answer to a load of the meal is on the screen,
    // the page does not know the meal's head count. A load that fails
    // keeps the meal here until a later one lands.
    signupReloadsWanted: {} as Record<number, true>,
    // Bumped each time a request from the sign-up list is answered, or
    // fails, before the page does anything with the answer. A meal load
    // captures it when it goes out. So a load that the answer itself
    // starts (reloadAfterSignupRequest) went out after the bump, and its
    // answer is used.
    signupAnswers: createVersionGuard(),
    // The hosts whose guest removal has no answer yet, by hostOn. While
    // one waits, that host's remove-guest control takes no taps, or a
    // second tap would send a second removal of the same guest. Kept
    // here, not on the host's row, for the same reason as
    // guestAddsWaiting in data_store_guest_adds.ts.
    guestRemovalsWaiting: [] as string[],
  };
}

export function signupRequestsViews(self: SignupRequestsStore) {
  return {
    signupRequestWaiting(mealId: number): boolean {
      return (
        mealId in self.signupRequestsWaiting ||
        mealId in self.signupReloadsWanted
      );
    },
    guestRemovalWaiting(mealId: number, hostId: number): boolean {
      return self.guestRemovalsWaiting.includes(hostOn(mealId, hostId));
    },
  };
}

export function signupRequestsActions(self: SignupRequestsStore) {
  return {
    // Count `request` as waiting on its meal until it settles. Returns a
    // promise that settles the same way, once the count is down and
    // signupAnswers is bumped: the page handles the answer on that one.
    // The page shows the answer while it still handles it, before the
    // browser draws the page or takes a tap, so the Extras boxes cannot
    // take a pick between the two.
    waitForSignupRequest<T>(mealId: number, request: Promise<T>): Promise<T> {
      self.signupRequestsWaiting = {
        ...self.signupRequestsWaiting,
        [mealId]: (self.signupRequestsWaiting[mealId] ?? 0) + 1,
      };
      return request.finally(function () {
        self.signupRequestAnswered(mealId);
      });
    },
    signupRequestAnswered(mealId: number) {
      self.signupAnswers.bump();
      const waiting = { ...self.signupRequestsWaiting };
      const left = waiting[mealId] - 1;
      if (left > 0) {
        waiting[mealId] = left;
      } else {
        delete waiting[mealId];
      }
      self.signupRequestsWaiting = waiting;
    },
    // A request's answer could not be shown on the screen. The meal on
    // screen loads again, and the Extras boxes of the request's meal
    // stay locked until the server's answer to a load of that meal is on
    // the screen (mealLoadedFromServer).
    reloadAfterSignupRequest(mealId: number) {
      self.signupReloadsWanted = {
        ...self.signupReloadsWanted,
        [mealId]: true,
      };
      self.loadDataAsync();
    },
    // loadData put the server's answer for this meal on the screen.
    mealLoadedFromServer(mealId: number) {
      if (!(mealId in self.signupReloadsWanted)) return;
      const wanted = { ...self.signupReloadsWanted };
      delete wanted[mealId];
      self.signupReloadsWanted = wanted;
    },
    // A guest removal for this host went out. It waits until `request`,
    // with its own callbacks, settles.
    waitForGuestRemoval(
      mealId: number,
      hostId: number,
      request: Promise<unknown>,
    ) {
      self.guestRemovalsWaiting = [
        ...self.guestRemovalsWaiting,
        hostOn(mealId, hostId),
      ];
      request.finally(function () {
        self.guestRemovalAnswered(mealId, hostId);
      });
    },
    guestRemovalAnswered(mealId: number, hostId: number) {
      const host = hostOn(mealId, hostId);
      self.guestRemovalsWaiting = self.guestRemovalsWaiting.filter(
        (waiting) => waiting !== host,
      );
    },
  };
}
