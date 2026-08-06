// Build a real DataStore for a unit test: one meal on screen, plus
// whatever rows the test hands in. Always the real store — a fake
// reimplementation of its views would keep passing after the real
// logic changed.
//
// The tree is left unprotected on purpose, so a test can mutate rows
// directly (inside runInAction) to stage a scenario:
//
//   runInAction(() => store.residents.delete("10"));
//
// DataStore.afterCreate boots the (mocked) Pusher client and reads
// navigator.onLine, so files using this helper must mock pusher-js,
// axios, js-cookie, and idb-keyval (see tests/unit/mocks/).
import { unprotect } from "mobx-state-tree";
import { runInAction } from "mobx";
import { DataStore } from "../../../app/frontend/src/stores/data_store.js";

export function createDataStore(opts = {}) {
  const { mealProps = {}, residents = [], guests = [], bills = [] } = opts;

  const mealDefaults = { id: 1, ...mealProps };

  const store = DataStore.create({
    meals: [mealDefaults],
    meal: mealDefaults.id,
  });

  unprotect(store);
  runInAction(() => {
    residents.forEach((r) => store.residents.put(r));
    guests.forEach((g) => store.guests.put(g));
    bills.forEach((b) => store.bills.put(b));
  });

  return store;
}
