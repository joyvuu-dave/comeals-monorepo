// What a person sees, and what the page does, when a request from a row
// of the sign-up list fails: a sign-up, a take-off, Late, Veg, a guest
// add or a guest removal (S2).
import { evictMealCache } from "./meal_cache";
import { mealDayLabel } from "./helpers";
import handleAxiosError from "./handle_axios_error";
import toastStore, { ToastType } from "../stores/toast_store";

// Whose row was tapped, and on which meal. Read when the row is tapped:
// by the time the answer comes, the row may have been built again, and
// the meal may no longer be on screen.
export interface Tapped {
  // The name a sentence uses (Resident#plainName): "Jane Smith".
  name: string;
  mealId: number;
  // The meal's day as the date box shows it: "Tue, Oct 6th".
  mealDay: string;
}

// What a row of the sign-up list reads when it is tapped.
interface TappedRow {
  plainName: string;
  meal_id: number;
  root: { meal: { date: Date | null } };
}

// What this file reads and calls on the DataStore.
export interface SignupStore {
  meal: { id: number } | null;
  loadDataAsync(): void;
}

// The words after the name when a request got no answer from the app,
// for the meal on screen and for a meal the person has left.
const MAYBE_ON_SCREEN =
  "this change may not have been saved. The meal will load again and show what was saved.";
const MAYBE_LEFT =
  "this change may not have been saved. Open that meal to check it.";

export function tappedOf(row: TappedRow): Tapped {
  return {
    name: row.plainName,
    mealId: row.meal_id,
    mealDay: mealDayLabel(row.root.meal.date),
  };
}

// True when a failed request got no answer from the app, so the page
// cannot tell whether it was written: no answer at all (a lost
// connection, or a request that never left), or a 5xx with no message
// from the app (Rails' own 500 page, or Heroku's router page, which it
// sends after 30 seconds while the request can still finish). Every
// answer the app writes itself has a message. The same rule as
// noAnswerFromApp in data_store_bills.ts.
export function noAnswerFromApp(error: unknown): boolean {
  const response = (
    error as {
      response?: { status?: number; data?: { message?: string } | string };
    } | null
  )?.response;
  if (response === undefined) return true;
  const data = response.data;
  const message =
    typeof data === "object" && data !== null ? data.message : undefined;
  return (response.status ?? 0) >= 500 && !message;
}

// Show a failed request to the person, with the name of the person whose
// row was tapped first, so on a shared screen everyone can tell whose tap
// failed: "Jane Smith: Meal has no open spots.". When the meal is no
// longer on screen, the meal's day goes with the name, the way the cost
// messages name a meal the person left (#107): "Jane Smith (Tue, Oct
// 6th): Meal has no open spots.". It shows whether or not the row that
// was tapped is still on screen.
//
// With no answer from the app, the request may have been written, and
// the push for it skips this screen, because the request carried this
// screen's socket id. So the copy of the meal on the device goes, and the
// meal on screen loads again to show what the server has.
export function showSignupFailure(
  store: SignupStore,
  tapped: Tapped,
  error: unknown,
): void {
  const onScreen = store.meal?.id === tapped.mealId;
  const who = onScreen ? tapped.name : `${tapped.name} (${tapped.mealDay})`;
  if (noAnswerFromApp(error)) {
    evictMealCache(tapped.mealId);
    toastStore.show(
      `${who}: ${onScreen ? MAYBE_ON_SCREEN : MAYBE_LEFT}`,
      "error",
    );
    if (onScreen) store.loadDataAsync();
    return;
  }
  handleAxiosError(error, {
    show: (message: string, type: ToastType) =>
      toastStore.show(`${who}: ${message}`, type),
  });
}
