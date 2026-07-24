// In-memory cache of calendar month payloads, keyed the same way as
// the localforage (IndexedDB) copies. Reads are synchronous, so month
// navigation renders instantly with no blank flash.
//
// The cache is an LRU: reads and writes move a key to the back, and
// writes evict from the front once the cap is passed. Without a cap,
// a session that browses years of history would hold every visited
// month in RAM until the next page reload — and this app runs on a
// shared screen that stays open for weeks.
//
// The cap is a safety limit, not something normal use ever reaches.
// The default of 120 means a session would have to browse ten years
// of months, without a page reload, before anything is evicted. At
// roughly 20-100 KB per payload the full cache is a few MB at worst.
// Eviction drops only the RAM copy — the month is still in IndexedDB
// and comes back with one async read.
//
// VITE_MONTH_CACHE_MAX_ENTRIES overrides the default. Tests set it
// very low to force eviction on every navigation. It also lets us
// lower the cap without a code change if month payloads ever grow.
// Vite reads the variable at build time, so changing it means
// rebuilding the app. Anything that is not a positive whole number
// falls back to the default.
const DEFAULT_MAX_ENTRIES = 120;
const capFromEnv = Number(import.meta.env.VITE_MONTH_CACHE_MAX_ENTRIES);
export const MONTH_CACHE_MAX_ENTRIES =
  Number.isInteger(capFromEnv) && capFromEnv > 0
    ? capFromEnv
    : DEFAULT_MAX_ENTRIES;

const cache = new Map();

// Monotonic version per key, bumped on every Pusher invalidation.
// Prefetch callbacks capture the version when they start and compare
// on arrival; a mismatch means a real-time update landed mid-flight
// and the stale response must be dropped. When a key is evicted its
// version goes too — with no cached entry there is nothing left to
// guard, and the next invalidation recreates it at 1.
const versions = new Map();

export function keyFor(communityId, year, month) {
  return `community-${communityId}-calendar-${year}-${month}`;
}

// A Map remembers insertion order, so re-inserting on read makes that
// order track recency of use: eviction takes from the front, and the
// months people actually look at sit at the back.
export function get(key) {
  if (!cache.has(key)) return undefined;
  var value = cache.get(key);
  cache.delete(key);
  cache.set(key, value);
  return value;
}

export function set(key, value) {
  cache.delete(key);
  cache.set(key, value);
  while (cache.size > MONTH_CACHE_MAX_ENTRIES) {
    var oldest = cache.keys().next().value;
    cache.delete(oldest);
    versions.delete(oldest);
  }
}

// How many months are in RAM right now. The app never reads this;
// tests use it to check the cap holds under real navigation.
export function size() {
  return cache.size;
}

// Drops the cache entry but keeps the version. Invalidation removes
// the entry and then bumps the version; an in-flight prefetch needs
// the bumped version to survive so it can see it was superseded.
export function remove(key) {
  cache.delete(key);
}

export function bumpVersion(key) {
  versions.set(key, (versions.get(key) || 0) + 1);
}

export function versionFor(key) {
  return versions.get(key) || 0;
}
