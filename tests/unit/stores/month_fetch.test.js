import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

// The navigation guard in month_fetch.js: the newest navigation wins,
// and a read or a fetch that a later navigation overtook must not
// render and must not overwrite fresher data. live_updates.test.js
// covers the Pusher side; these are the races inside one client.

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import Cookie from "js-cookie";
import * as idbKeyval from "idb-keyval";
import * as monthCache from "../../../app/frontend/src/stores/month_cache.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import {
  invalidateAllMonths,
  invalidateMonth,
  invalidateMonthForDate,
  loadForNavigation,
  NO_ANSWER_RETRY_MS,
  prefetchMonth,
  refetch,
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

// What idb-keyval rejects with when the browser has closed the
// database under a tab that stayed open (#111).
const DISK_CLOSED = new Error("IndexedDB is closed");

function expectDiskErrorLogged() {
  expect(console.error).toHaveBeenCalledWith(
    "IndexedDB failed; going on without the copy on disk:",
    DISK_CLOSED,
  );
}

// What axios rejects with when the request got no answer (offline, a
// dropped connection): the error carries the request, and no response.
function noAnswer() {
  return Object.assign(new Error("Network Error"), { request: {} });
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
    toastStore.clearAll();
    serveMonths();
  });

  // IndexedDB can fail in a tab that stays open for weeks. The copies on
  // disk only make a load faster, so every disk call that fails is
  // logged and the load goes on without the copy (#111).
  describe("when IndexedDB fails", () => {
    it("invalidateMonth still drops the RAM copy and the version moves on", async () => {
      monthCache.set(keyFor(2026, 4), payload(2026, 4));
      const versionBefore = monthCache.versionFor(keyFor(2026, 4));
      idbKeyval.del.mockRejectedValueOnce(DISK_CLOSED);

      invalidateMonth(COMMUNITY, "2026", "4");
      await flush();

      expect(monthCache.get(keyFor(2026, 4))).toBeUndefined();
      expect(monthCache.versionFor(keyFor(2026, 4))).toBe(versionBefore + 1);
      expectDiskErrorLogged();
    });

    it("invalidateAllMonths still empties RAM", async () => {
      monthCache.set(keyFor(2026, 4), payload(2026, 4));
      idbKeyval.clear.mockRejectedValueOnce(DISK_CLOSED);

      invalidateAllMonths();
      await flush();

      expect(monthCache.size()).toBe(0);
      expectDiskErrorLogged();
    });

    it("prefetchMonth fetches when the disk read fails", async () => {
      idbKeyval.get.mockRejectedValueOnce(DISK_CLOSED);

      prefetchMonth("2026-04-15");
      await flush();

      expect(axios.get).toHaveBeenCalledWith(
        `/api/v1/communities/${COMMUNITY}/calendar/2026-04-15`,
      );
      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
      expectDiskErrorLogged();
    });

    it("prefetchMonth keeps the fetched month in RAM when the disk write fails", async () => {
      idbKeyval.set.mockRejectedValueOnce(DISK_CLOSED);

      prefetchMonth("2026-04-15");
      await flush();

      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
      expectDiskErrorLogged();
    });

    it("loadForNavigation fetches and draws the month when the disk read fails", async () => {
      idbKeyval.get.mockRejectedValueOnce(DISK_CLOSED);
      const render = vi.fn();

      loadForNavigation("2026-04-15", render);
      await flush();

      expect(render.mock.calls).toEqual([[payload(2026, 4)]]);
      expectDiskErrorLogged();
    });

    it("loadForNavigation draws the fetched month when the disk write fails", async () => {
      idbKeyval.set.mockRejectedValueOnce(DISK_CLOSED);
      const render = vi.fn();

      loadForNavigation("2026-04-15", render);
      await flush();

      expect(render.mock.calls).toEqual([[payload(2026, 4)]]);
      expect(monthCache.get(keyFor(2026, 4))).toEqual(payload(2026, 4));
      expectDiskErrorLogged();
    });
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

    it("caches nothing when the fetch gets no answer, and does not throw", async () => {
      axios.get.mockRejectedValueOnce(noAnswer());

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

    // A background fetch: the failure is logged (handle_axios_error's
    // own tests check the words), never shown as a toast.
    it("renders and caches nothing, and shows no toast, when the fetch gets no answer", async () => {
      axios.get.mockRejectedValueOnce(noAnswer());
      const render = vi.fn();

      loadForNavigation("2026-04-15", render);
      await flush();

      expect(render).not.toHaveBeenCalled();
      expect(monthCache.get(keyFor(2026, 4))).toBeUndefined();
      expect(idbKeyval.set).not.toHaveBeenCalled();
      expect(toastStore.toasts).toHaveLength(0);
    });
  });

  // A page load stops the boot-time prefetch. WebKit fails it with
  // ERR_NETWORK, and refuses a new request the page sends while it is
  // leaving, which logs "... due to access control checks." (#163). So
  // the calendar, which adopted that prefetch, must not ask again at
  // once. It waits; if the page is gone by then, nothing is sent. If the
  // page is still here, the failure was the network, and it asks again.
  describe("when the prefetch the calendar adopted gets no answer", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    // Lets every promise chain that can run now finish. The fake clock
    // stays where it is, so no wait runs out.
    async function settle() {
      await vi.advanceTimersByTimeAsync(0);
    }

    // What WebKit fails the request with when a page load stops it.
    function stoppedByPageLoad() {
      return Object.assign(noAnswer(), { code: "ERR_NETWORK" });
    }

    function januaryRequests() {
      return axios.get.mock.calls.filter(([url]) =>
        url.endsWith("/calendar/2026-01-15"),
      ).length;
    }

    // The boot-time prefetch of January is on the wire, and the
    // calendar mounts and adopts it. Hands back the prefetch, to fail.
    async function calendarAdoptsThePrefetch(render) {
      const prefetch = deferred();
      axios.get.mockImplementationOnce(() => prefetch.promise);
      prefetchMonth("2026-01-15");
      await settle();
      loadForNavigation("2026-01-15", render);
      await settle();
      expect(januaryRequests()).toBe(1);
      return prefetch;
    }

    it("sends no second request at once when a page load stops the prefetch", async () => {
      const render = vi.fn();
      const prefetch = await calendarAdoptsThePrefetch(render);

      prefetch.reject(stoppedByPageLoad());
      await settle();
      await vi.advanceTimersByTimeAsync(NO_ANSWER_RETRY_MS - 1);

      expect(januaryRequests()).toBe(1);
      expect(render).not.toHaveBeenCalled();
    });

    it("asks again after the wait when the page is still here, and draws the month", async () => {
      const render = vi.fn();
      const prefetch = await calendarAdoptsThePrefetch(render);

      prefetch.reject(stoppedByPageLoad());
      await settle();
      await vi.advanceTimersByTimeAsync(NO_ANSWER_RETRY_MS);

      expect(januaryRequests()).toBe(2);
      expect(render.mock.calls).toEqual([[payload(2026, 1)]]);
      expect(monthCache.get(keyFor(2026, 1))).toEqual(payload(2026, 1));
    });

    it("does not ask again for a month the person left during the wait", async () => {
      const render = vi.fn();
      const prefetch = await calendarAdoptsThePrefetch(render);

      prefetch.reject(noAnswer());
      await settle();
      loadForNavigation("2026-02-15", vi.fn());
      await vi.advanceTimersByTimeAsync(NO_ANSWER_RETRY_MS);

      expect(januaryRequests()).toBe(1);
      expect(render).not.toHaveBeenCalled();
    });

    // An answer means the request was not stopped, so the page is not
    // leaving. That case asks again at once, as before.
    it("asks again at once when the prefetch was answered with an error", async () => {
      const render = vi.fn();
      const prefetch = await calendarAdoptsThePrefetch(render);

      prefetch.reject(
        Object.assign(new Error("Request failed with status code 500"), {
          request: {},
          response: { status: 500, data: {} },
        }),
      );
      await settle();

      expect(januaryRequests()).toBe(2);
      expect(render.mock.calls).toEqual([[payload(2026, 1)]]);
    });
  });

  // "Sign in" in the signed-out banner, and logout, remove the session
  // cookies just before the page reloads. Work the page started before
  // that can still go on in between, and a request built then named the
  // community "undefined" (#153).
  describe("after the session ends", () => {
    function endSession() {
      Cookie.remove("token");
      Cookie.remove("community_id");
    }

    it("loadForNavigation sends no request when the disk read ends after the session", async () => {
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);
      const render = vi.fn();

      loadForNavigation("2026-01-15", render);
      endSession();
      read.resolve(undefined);
      await flush();

      expect(axios.get).not.toHaveBeenCalled();
      expect(render).not.toHaveBeenCalled();
    });

    it("prefetchMonth sends no request when the disk read ends after the session", async () => {
      const read = deferred();
      idbKeyval.get.mockImplementationOnce(() => read.promise);

      prefetchMonth("2026-01-15");
      endSession();
      read.resolve(undefined);
      await flush();

      expect(axios.get).not.toHaveBeenCalled();
    });

    it("refetch sends no request", async () => {
      endSession();
      const render = vi.fn();

      refetch("2026-01-15", render);
      await flush();

      expect(axios.get).not.toHaveBeenCalled();
      expect(render).not.toHaveBeenCalled();
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
