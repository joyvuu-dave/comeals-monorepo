// Build a real DataStore for a unit test: one meal on screen, plus
// whatever rows the test hands in. Always the real store — a fake
// reimplementation of its views would keep passing after the real
// logic changed.
//
// The store comes back PROTECTED, like the real one: state may change
// only inside an action, and a change from anywhere else throws. That
// is how the app runs, and an unprotected store hid a real bug (a save
// pipeline writing state from a .then callback, 2026-08-26). A test that
// stages a scenario by writing rows directly says so with `stage`:
//
//   stage(store, () => store.residents.delete("10"));
//
// DataStore.afterCreate boots the (mocked) Pusher client and reads
// navigator.onLine, so files using this helper must mock pusher-js,
// axios, js-cookie, and idb-keyval (see tests/unit/mocks/).
import { protect, unprotect } from "mobx-state-tree";
import { vi } from "vitest";
import { DataStore } from "../../../app/frontend/src/stores/data_store.js";

export function createDataStore(opts = {}) {
  const { mealProps = {}, residents = [], guests = [], bills = [] } = opts;

  const mealDefaults = { id: 1, ...mealProps };

  const store = DataStore.create({
    meals: [mealDefaults],
    meal: mealDefaults.id,
  });

  stage(store, () => {
    residents.forEach((r) => store.residents.put(r));
    guests.forEach((g) => store.guests.put(g));
    bills.forEach((b) => store.bills.put(b));
  });

  return store;
}

// Write to the tree directly, as a test's scenario setup, then put the
// protection back so the code under test runs under the app's rule.
export function stage(store, write) {
  unprotect(store);
  try {
    write();
  } finally {
    protect(store);
  }
}

// Replace one of the store's actions with a stub for the test. Replacing
// an action is a write to the protected tree, so it is staged. A plain
// vi.fn, not vi.spyOn: vitest restores every spy at teardown, and putting
// the original back would be a write to the protected tree again. The
// store lives only for the test, so nothing needs restoring. Returns the
// stub, for call assertions.
export function stubAction(store, name, impl = () => {}) {
  const stub = vi.fn(impl);
  stage(store, () => {
    store[name] = stub;
  });
  return stub;
}
