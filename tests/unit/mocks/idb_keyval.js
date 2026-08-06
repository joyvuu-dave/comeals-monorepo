// The shared idb-keyval mock: an always-empty store. Use it with the
// redirect form:
//
//   vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));
//
// `get` resolves undefined (a missing key), so code under test always
// falls through to its network path. A test that needs a cache hit
// sets it explicitly: idbKeyval.get.mockResolvedValue(payload).
// month_cache_integration.test.js keeps its own disk-backed variant —
// it tests the IndexedDB round trip itself.
import { vi } from "vitest";

export const get = vi.fn(() => Promise.resolve(undefined));
export const set = vi.fn(() => Promise.resolve());
export const del = vi.fn(() => Promise.resolve());
export const clear = vi.fn(() => Promise.resolve());
