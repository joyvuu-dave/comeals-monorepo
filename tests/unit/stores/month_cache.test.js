import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The module holds its cache in module-level Maps, so each test gets
// a fresh copy via resetModules + dynamic import.
let monthCache;

beforeEach(async () => {
  vi.resetModules();
  monthCache = await import("../../../app/frontend/src/stores/month_cache.js");
});

// Fills the cache with `count` entries: key-0, key-1, ... in order.
function fill(count) {
  for (let i = 0; i < count; i++) {
    monthCache.set(`key-${i}`, { month: i });
  }
}

describe("month cache", () => {
  describe("keyFor", () => {
    it("builds the same key format localforage uses", () => {
      expect(monthCache.keyFor(7, "2026", "3")).toBe(
        "community-7-calendar-2026-3",
      );
    });
  });

  describe("get and set", () => {
    it("returns undefined for a key that was never set", () => {
      expect(monthCache.get("missing")).toBeUndefined();
    });

    it("returns the stored value", () => {
      monthCache.set("a", { meals: [1, 2] });
      expect(monthCache.get("a")).toEqual({ meals: [1, 2] });
    });

    it("replaces the value when the same key is set again", () => {
      monthCache.set("a", { version: "old" });
      monthCache.set("a", { version: "new" });
      expect(monthCache.get("a")).toEqual({ version: "new" });
    });
  });

  describe("eviction", () => {
    it("holds exactly the cap without evicting", () => {
      fill(monthCache.MONTH_CACHE_MAX_ENTRIES);
      expect(monthCache.get("key-0")).toEqual({ month: 0 });
      expect(
        monthCache.get(`key-${monthCache.MONTH_CACHE_MAX_ENTRIES - 1}`),
      ).toBeDefined();
    });

    it("evicts the oldest entry past the cap", () => {
      fill(monthCache.MONTH_CACHE_MAX_ENTRIES + 1);
      expect(monthCache.get("key-0")).toBeUndefined();
      expect(monthCache.get("key-1")).toEqual({ month: 1 });
      expect(
        monthCache.get(`key-${monthCache.MONTH_CACHE_MAX_ENTRIES}`),
      ).toBeDefined();
    });

    it("re-setting an existing key at the cap does not evict", () => {
      fill(monthCache.MONTH_CACHE_MAX_ENTRIES);
      monthCache.set("key-3", { month: "updated" });
      expect(monthCache.get("key-0")).toEqual({ month: 0 });
      expect(monthCache.get("key-3")).toEqual({ month: "updated" });
    });

    it("a read protects the entry from eviction", () => {
      fill(monthCache.MONTH_CACHE_MAX_ENTRIES);
      // key-0 is oldest; reading it moves it to the back.
      monthCache.get("key-0");
      monthCache.set("one-more", { month: "extra" });
      // key-1 became the oldest and takes the eviction instead.
      expect(monthCache.get("key-0")).toEqual({ month: 0 });
      expect(monthCache.get("key-1")).toBeUndefined();
    });

    it("a re-set protects the entry from eviction", () => {
      fill(monthCache.MONTH_CACHE_MAX_ENTRIES);
      monthCache.set("key-0", { month: "refreshed" });
      monthCache.set("one-more", { month: "extra" });
      expect(monthCache.get("key-0")).toEqual({ month: "refreshed" });
      expect(monthCache.get("key-1")).toBeUndefined();
    });
  });

  describe("cap from the environment", () => {
    afterEach(() => {
      vi.unstubAllEnvs();
    });

    // The module reads the env var once at import time, so each value
    // needs a fresh import.
    async function importWithCap(value) {
      vi.stubEnv("VITE_MONTH_CACHE_MAX_ENTRIES", value);
      vi.resetModules();
      return await import("../../../app/frontend/src/stores/month_cache.js");
    }

    it("uses the default of 120 when the variable is unset", () => {
      // The top-level beforeEach imported with no stub in place.
      expect(monthCache.MONTH_CACHE_MAX_ENTRIES).toBe(120);
    });

    it("reads the cap from VITE_MONTH_CACHE_MAX_ENTRIES", async () => {
      const tiny = await importWithCap("2");
      expect(tiny.MONTH_CACHE_MAX_ENTRIES).toBe(2);

      tiny.set("a", { month: 1 });
      tiny.set("b", { month: 2 });
      tiny.set("c", { month: 3 });

      expect(tiny.size()).toBe(2);
      expect(tiny.get("a")).toBeUndefined();
      expect(tiny.get("b")).toEqual({ month: 2 });
      expect(tiny.get("c")).toEqual({ month: 3 });
    });

    it("falls back to the default for values that are not positive whole numbers", async () => {
      for (const bad of ["0", "-5", "2.5", "banana", ""]) {
        const mod = await importWithCap(bad);
        expect(mod.MONTH_CACHE_MAX_ENTRIES).toBe(120);
      }
    });
  });

  describe("invalidation versions", () => {
    it("starts at zero for an unknown key", () => {
      expect(monthCache.versionFor("never-seen")).toBe(0);
    });

    it("bumps by one each time", () => {
      monthCache.bumpVersion("a");
      monthCache.bumpVersion("a");
      expect(monthCache.versionFor("a")).toBe(2);
    });

    it("keeps the version while the key stays cached", () => {
      monthCache.set("a", { month: 1 });
      monthCache.bumpVersion("a");
      expect(monthCache.versionFor("a")).toBe(1);
    });

    it("prunes the version when the key is evicted", () => {
      fill(monthCache.MONTH_CACHE_MAX_ENTRIES);
      monthCache.bumpVersion("key-0");
      monthCache.set("one-more", { month: "extra" });
      // key-0 was evicted, so its version entry went with it.
      expect(monthCache.get("key-0")).toBeUndefined();
      expect(monthCache.versionFor("key-0")).toBe(0);
    });

    it("remove() drops the entry but keeps the version", () => {
      // Invalidation removes the entry and then bumps the version.
      // An in-flight prefetch compares against the bumped version to
      // see it was superseded, so remove() must not prune it.
      monthCache.set("a", { month: 1 });
      monthCache.bumpVersion("a");
      monthCache.remove("a");
      expect(monthCache.get("a")).toBeUndefined();
      expect(monthCache.versionFor("a")).toBe(1);
    });
  });
});
