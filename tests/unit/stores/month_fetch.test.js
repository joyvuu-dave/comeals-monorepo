import { describe, it, expect, beforeEach, vi } from "vitest";

// The navigation guard in month_fetch.js: the newest navigation wins,
// and a read or a fetch that a later navigation overtook must not
// render and must not overwrite fresher data. live_updates.test.js
// covers the Pusher side; these are the races inside one client.

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import * as idbKeyval from "idb-keyval";
import * as monthCache from "../../../app/frontend/src/stores/month_cache.js";
import {
  invalidateMonth,
  invalidateMonthForDate,
  loadForNavigation,
  prefetchMonth,
} from "../../../app/frontend/src/stores/month_fetch.js";

const COMMUNITY = "test-community-id";

function payload(year, month) {
  return { id: COMMUNITY, year, month, meals: [], events: [] };
}

function keyFor(year, month) {
  return monthCache.keyFor(COMMUNITY, String(year), String(month));
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function flush() {
  for (let i = 0; i < 10; i++) {
    await new Promise((r) => setTimeout(r, 0));
  }
}

function serveMonths() {
  axios.get.mockImplementation((url) => {
    const m = url.match(/\/calendar\/(\d{4})-(\d{2})-\d{2}$/);
    return Promise.resolve({
      status: 200,
      data: payload(Number(m[1]), Number(m[2])),
    });
  });
}

describe("month_fetch", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    monthCache.clear();
    serveMonths();
  });

  describe("invalidateMonthForDate", () => {
    it("evicts the month a wire date names", () => {
      invalidateMonthForDate("2026-04-15T19:00:00");

      expect(idbKeyval.del).toHaveBeenCalledWith(keyFor(2026, 4));
    });

    it("evicts nothing for a date it cannot read", () => {
      invalidateMonthForDate("not a date");

      expect(idbKeyval.del).not.toHaveBeenCalled();
    });
  });

  describe("prefetchMonth", () => {
    it("drops a disk read that an invalidation overtook, and does not fetch", async () => {
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);

      prefetchMonth("2026-04-15");
      invalidateMonth(COMMUNITY, "2026", "4");
      read.resolve(undefined);
      await flush();

      expect(monthCache.get(keyFor(2026, 4))).toBeUndefined();
      expect(axios.get).not.toHaveBeenCalled();
    });
  });

  describe("prefetchMonth", () => {
    it("fetches a month into both caches, so the navigation renders it without a request", async () => {
      const render = vi.fn();

      prefetchMonth("2026-04-15");
      await flush();
      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
      expect(idbKeyval.set).toHaveBeenCalledWith(
        keyFor(2026, 4),
        payload(2026, 4),
      );

      loadForNavigation("2026-04-15", render);
      await flush();

      expect(render).toHaveBeenCalledWith(payload(2026, 4));
      expect(axios.get).toHaveBeenCalledTimes(1);
    });

    it("caches nothing when the fetch fails, and does not throw", async () => {
      axios.get.mockRejectedValueOnce(new Error("offline"));

      prefetchMonth("2026-04-15");
      await flush();

      expect(monthCache.get(keyFor(2026, 4))).toBeUndefined();
      expect(idbKeyval.set).not.toHaveBeenCalled();
    });
  });

  describe("loadForNavigation", () => {
    it("renders the disk copy at once, then the server's answer", async () => {
      const onDisk = { ...payload(2026, 4), events: [{ id: 9, title: "Old" }] };
      idbKeyval.get.mockResolvedValueOnce(onDisk);
      const render = vi.fn();

      loadForNavigation("2026-04-15", render);
      await flush();

      expect(render.mock.calls).toEqual([[onDisk], [payload(2026, 4)]]);
      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
    });

    it("renders nothing, and does not throw, when the fetch fails", async () => {
      axios.get.mockRejectedValueOnce(new Error("offline"));
      const render = vi.fn();

      loadForNavigation("2026-04-15", render);
      await flush();

      expect(render).not.toHaveBeenCalled();
      expect(console.error).toHaveBeenCalledWith(
        "Error: could not submit form.",
      );
    });
  });

  describe("loadForNavigation, overtaken by a second navigation", () => {
    it("during a disk read that misses: no render, no fetch for the old month", async () => {
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);
      const renderApril = vi.fn();
      const renderMay = vi.fn();

      loadForNavigation("2026-04-15", renderApril);
      loadForNavigation("2026-05-15", renderMay);
      read.resolve(undefined);
      await flush();

      expect(renderApril).not.toHaveBeenCalled();
      expect(renderMay).toHaveBeenCalledWith(payload(2026, 5));
      const aprilFetches = axios.get.mock.calls.filter(([url]) =>
        url.endsWith("/calendar/2026-04-15"),
      );
      expect(aprilFetches).toHaveLength(0);
    });

    it("during a disk read that hits: warms the cache, but no render and no fetch", async () => {
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);
      const renderApril = vi.fn();

      loadForNavigation("2026-04-15", renderApril);
      loadForNavigation("2026-05-15", vi.fn());
      read.resolve(payload(2026, 4));
      await flush();

      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
      expect(renderApril).not.toHaveBeenCalled();
      const aprilFetches = axios.get.mock.calls.filter(([url]) =>
        url.endsWith("/calendar/2026-04-15"),
      );
      expect(aprilFetches).toHaveLength(0);
    });

    it("during the fetch: the response is dropped, not cached", async () => {
      const response = deferred();
      axios.get.mockImplementationOnce(() => response.promise);
      const renderApril = vi.fn();

      loadForNavigation("2026-04-15", renderApril);
      await flush();
      loadForNavigation("2026-05-15", vi.fn());
      response.resolve({ status: 200, data: payload(2026, 4) });
      await flush();

      expect(renderApril).not.toHaveBeenCalled();
      expect(monthCache.get(keyFor(2026, 4))).toBeUndefined();
    });

    it("during the disk write after the fetch: cached, but not rendered", async () => {
      const write = deferred();
      idbKeyval.set.mockImplementationOnce(() => write.promise);
      const renderApril = vi.fn();

      loadForNavigation("2026-04-15", renderApril);
      await flush();
      expect(idbKeyval.set).toHaveBeenCalledWith(
        keyFor(2026, 4),
        payload(2026, 4),
      );
      loadForNavigation("2026-05-15", vi.fn());
      write.resolve();
      await flush();

      expect(renderApril).not.toHaveBeenCalled();
      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
    });
  });
});
