import { describe, it, expect, beforeEach, vi } from "vitest";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { protect } from "mobx-state-tree";
import { createDataStore } from "../helpers/create_data_store.js";

// createDataStore unprotects the tree so tests can stage rows directly.
// That hides one bug class: a state change made outside an action. The
// save pipelines settle in .then callbacks, which run outside any action,
// so their writes must go through the wrapped actions on `self`. A local
// function call there works on an unprotected tree and throws on the
// real one (found by the e2e suite when the stores became TypeScript,
// 2026-08-26). These run on a protected tree.
describe("Meal save pipelines on a protected tree", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    vi.stubEnv("VITE_PUSHER_CLUSTER", "us2");
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
    window.alert = vi.fn();
  });

  it("a description save's ack lands: the node is clean again", async () => {
    const store = createDataStore();
    protect(store);

    store.meal.setDescription("Tacos");
    expect(store.meal.descriptionDirty).toBe(true);
    await new Promise((r) => setTimeout(r, 0));

    expect(store.meal.descriptionDirty).toBe(false);
    expect(store.meal.descriptionSaveInFlight).toBe(false);
  });

  it("an extras save settles: pending clears", async () => {
    const store = createDataStore();
    protect(store);

    store.meal.setExtras(2);
    expect(store.meal.extrasPending).toBe(true);
    await new Promise((r) => setTimeout(r, 0));

    expect(store.meal.extrasPending).toBe(false);
  });
});
