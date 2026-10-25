// Vitest's own waits, with the same 10 second limit as Testing
// Library's. vi.waitFor and vi.waitUntil give up after 1 second unless
// a call passes its own limit, and Vitest has no setting to change that
// for every test. With six full Vitest runs at once, a wait that ends in
// a few milliseconds on an idle machine took just over 1 second (#247).
// ESLint refuses vi.waitFor and vi.waitUntil in tests/unit, so a new
// wait gets this limit too. A caller's own timeout or interval wins.
import { vi } from "vitest";

// How long a wait polls before it fails, here and in Testing Library
// (render_setup.js). Well under the 30 second test limit in
// vitest.config.mjs, so a wait that never ends fails with its own
// message, not with the test's timeout.
export const WAIT_LIMIT_MS = 10_000;

function withLimit(options) {
  // Both Vitest waits also take a bare number as the timeout.
  const given = typeof options === "number" ? { timeout: options } : options;
  return { timeout: WAIT_LIMIT_MS, ...given };
}

export function vitestWaitFor(callback, options) {
  // eslint-disable-next-line no-restricted-properties -- this is the one place that calls it, with the longer limit
  return vi.waitFor(callback, withLimit(options));
}

export function vitestWaitUntil(callback, options) {
  // eslint-disable-next-line no-restricted-properties -- this is the one place that calls it, with the longer limit
  return vi.waitUntil(callback, withLimit(options));
}
