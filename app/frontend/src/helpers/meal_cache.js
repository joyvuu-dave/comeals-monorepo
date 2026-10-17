import { del as kvDel } from "idb-keyval";

// This browser deletes its own copy of a meal after its own change
// (issue #37). A meal write sends this browser's Pusher socket id, and
// the server leaves that socket out of the meal-page push
// (LiveUpdate.meal). So no push tells this browser to fetch the meal
// again, and the copy on disk (IndexedDB) would show the old rows on
// the next visit.
//
// These delete the copy here instead of changing it: the sign-up writes
// (attend, late, vegetarian, add or remove a guest), a bills save, a
// sign-up that got no answer, and a Close, Cancel, Restore or Extras
// save when it is answered. Building the copy's shape by hand in each
// handler would stop matching the server's shape when that changes, and
// loadDataAsync stays the only code that writes the copy. Close, Cancel,
// Restore and Extras also fetch the meal on screen again when they are
// answered. That fetch does not replace the copy when the person has
// left the meal by then, because it is of the other meal (#174). A
// description save does neither, so the copy keeps the old text until
// the next fetch. Every visit makes one right after it shows the copy.
export function evictMealCache(mealId) {
  return kvDel(String(mealId)).catch(function () {
    // A failed delete leaves the old copy, so the next visit shows it
    // until the fetch that every visit makes replaces it.
  });
}
