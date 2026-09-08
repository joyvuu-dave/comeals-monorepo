import { describe, it, expect, vi } from "vitest";

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import * as idbKeyval from "idb-keyval";
import { evictMealCache } from "../../../app/frontend/src/helpers/meal_cache.js";

describe("evictMealCache", () => {
  it("deletes the meal's cached payload by its id as a string", async () => {
    await evictMealCache(7);

    expect(idbKeyval.del).toHaveBeenCalledWith("7");
  });

  it("swallows a failed delete, so a save can never fail on the cache", async () => {
    idbKeyval.del.mockRejectedValueOnce(new Error("IndexedDB is closed"));

    await expect(evictMealCache(7)).resolves.toBeUndefined();
  });
});
