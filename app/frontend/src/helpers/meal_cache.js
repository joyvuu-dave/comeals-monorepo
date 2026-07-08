import localforage from "localforage";

// The client that knows, invalidates (issue #37). Meal mutations send
// socketId, so the sender gets no Pusher echo — nothing else updates the
// cached meal payload after a change the sender made. Every successful
// meal mutation evicts the entry instead of patching it: hand-building
// the cached payload shape in each handler would rot, and loadDataAsync
// stays the cache's only writer.
export function evictMealCache(mealId) {
  return localforage.removeItem(String(mealId)).catch(function () {
    // Best-effort: a failed eviction just leaves this meal on the old
    // stale-while-revalidate behavior for one visit.
  });
}
