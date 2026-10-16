import { del as kvDel } from "idb-keyval";

// This browser deletes its own copy of a meal after its own change
// (issue #37). A meal write sends this browser's Pusher socket id, and
// the server leaves that socket out of the meal-page push
// (LiveUpdate.meal). So no push tells this browser to fetch the meal
// again, and the copy on disk (IndexedDB) would show the old rows on
// the next visit.
//
// The sign-up writes (attend, late, vegetarian, add or remove a guest),
// a bills save, and a sign-up that got no answer delete the copy here
// instead of changing it: building the copy's shape by hand in each
// handler would stop matching the server's shape when that changes, and
// loadDataAsync stays the only code that writes the copy. Close, Cancel
// or Restore, and Extras do not call this: each fetches the meal again
// when it settles, and that fetch writes a fresh copy. A description
// save does neither, so the copy keeps the old text until the next
// fetch. Every visit makes one right after it shows the copy.
export function evictMealCache(mealId) {
  return kvDel(String(mealId)).catch(function () {
    // A failed delete leaves the old copy, so the next visit shows it
    // until the fetch that every visit makes replaces it.
  });
}
