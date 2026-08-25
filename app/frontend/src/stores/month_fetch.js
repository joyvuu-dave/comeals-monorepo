// The fetch side of the calendar. This file owns every network request
// for a month of calendar data and every decision about whether to make
// one: the in-memory LRU (./month_cache), the IndexedDB copies, the
// dedupe of in-flight requests, the freshness window, and the
// navigation guard that lets the newest navigation win.
//
// The calendar's data path is four files, one job each:
//   stores/month_fetch.js          fetch, cache lookups, freshness  (this file)
//   stores/month_cache.js          the in-memory LRU
//   stores/data_store_calendar.js  render: turn a month into calendar events,
//                                  subscribe to live updates
//   helpers/pusher_client.js       the live-update transport, and the
//                                  end-to-end protocol in its header
//
// The DataStore only renders — it hands loadForNavigation/revalidate a
// `render` callback (its loadMonth action) and this module decides
// which data reaches it, if any.
//
// This state is module-level on purpose: the boot-time prefetch
// (index.jsx) runs before any store exists, and the store's navigation
// must adopt that same in-flight request instead of racing it.
import axios from "axios";
import Cookie from "js-cookie";
import dayjs from "dayjs";
import {
  get as kvGet,
  set as kvSet,
  del as kvDel,
  clear as kvClear,
} from "idb-keyval";

import * as monthCache from "./month_cache";
import createVersionGuard from "../helpers/version_guard";
import handleAxiosError from "../helpers/handle_axios_error";
import { toCommunityDayjs } from "../helpers/helpers";

// Stale-response guard for month navigation. Bumped at the start of
// every navigation and every revalidation; each async continuation
// captures the token at start and checks it before touching the
// screen, so the newest navigation always wins. A superseded fetch
// response is dropped entirely — caching it could overwrite fresher
// data for the same month. A superseded IndexedDB read may still warm
// the in-memory cache (its data is correct under its own key) but
// skips rendering and skips its revalidation fetch.
const navigations = createVersionGuard();

// Network fetches started by a prefetch, keyed like monthCache. When
// the calendar mounts while the boot-time prefetch of the same month
// is still in flight, revalidate adopts the pending request instead
// of racing it with a duplicate one.
const networkInFlight = {};

// How long a network-fetched month counts as fresh. Within this
// window loadForNavigation renders it without a revalidation fetch —
// the data just came from the server, so refetching it would repeat
// the same request. Past the window, normal stale-while-revalidate.
const MONTH_FRESH_MS = 5000;

function keyForDate(date) {
  var d = dayjs(date);
  return monthCache.keyFor(
    Cookie.get("community_id"),
    d.format("YYYY"),
    d.format("M"),
  );
}

// Evict one month from both caches and bump its invalidation version,
// so an in-flight read of the old data is discarded.
export function invalidateMonth(communityId, year, month) {
  var key = monthCache.keyFor(communityId, year, month);
  monthCache.remove(key);
  kvDel(key);
  monthCache.bumpVersion(key);
}

// Drop every cached month and meal, in RAM and in IndexedDB. The
// residents channel fires this: a renamed, retired or moved resident
// (or a renamed unit) appears on chips in any month and in every
// meal's sign-up list, and there is no way to know which copies hold
// the old value. IndexedDB holds only these copies, so it is cleared
// whole. The month on screen is refetched by the caller.
export function invalidateAllMonths() {
  monthCache.clear();
  kvClear();
}

// The month on screen is stale (a Pusher update, a reconnect, the day
// changing): drop the copies, so a navigation away and back cannot
// show them, and mark the version, so a prefetch of this month that
// is still on the wire drops its answer instead of storing it —
// revalidate would otherwise adopt that in-flight request and render
// data read before the change. Then fetch.
export function refetch(date, render) {
  var d = dayjs(date);
  invalidateMonth(Cookie.get("community_id"), d.format("YYYY"), d.format("M"));
  revalidate(date, render);
}

// The client that knows, invalidates (issue #37): only the current
// month and its neighbors have Pusher channels, so a reservation or
// event saved onto a farther month would leave that month's cache
// stale — and the person who just made the booking would see it
// missing. The modal that made the change calls this with the
// affected date(s); an edit that moves a date calls it for both the
// old and the new month. Accepts what the modals hold: a picker Date
// (already a community-day "fake local" Date) or a wire date string
// (offset or naive), which resolves to the community month — the same
// month the cache key uses.
export function invalidateMonthForDate(date) {
  if (!date) return;
  var d;
  try {
    d = date instanceof Date ? dayjs(date) : toCommunityDayjs(date);
  } catch {
    // dayjs.tz throws a RangeError on unparseable strings. A date we
    // cannot read names no month to evict.
    return;
  }
  if (!d.isValid()) return;
  invalidateMonth(Cookie.get("community_id"), d.format("YYYY"), d.format("M"));
}

// Warm the caches for a month nobody is looking at yet: the boot-time
// prefetch (index.jsx calls this before React mounts) and the
// adjacent months of the one on screen. Renders nothing.
export function prefetchMonth(date) {
  var key = keyForDate(date);

  // The read also marks the month as recently used, so an adjacent
  // month that is already cached stays away from the eviction end.
  if (monthCache.get(key) !== undefined) return;

  var versionAtStart = monthCache.versionFor(key);

  kvGet(key).then(function (value) {
    // Discard if a Pusher invalidation arrived since we started
    if (monthCache.versionFor(key) !== versionAtStart) return;

    if (value !== null && typeof value !== "undefined") {
      monthCache.set(key, value);
      return;
    }

    var pending = axios
      .get(`/api/v1/communities/${Cookie.get("community_id")}/calendar/${date}`)
      .then(function (response) {
        if (response.status === 200) {
          // Discard if a Pusher invalidation arrived since we started
          if (monthCache.versionFor(key) !== versionAtStart) return;
          monthCache.set(key, response.data);
          monthCache.markFresh(key);
          kvSet(key, response.data);
        }
      })
      .catch(function () {
        // Prefetch failure is non-critical
      })
      .finally(function () {
        delete networkInFlight[key];
      });
    networkInFlight[key] = pending;
  });
}

// A navigation to `date`: render the best copy we have right away,
// then revalidate against the server unless the copy is seconds old.
export function loadForNavigation(date, render) {
  var token = navigations.bump();
  var key = keyForDate(date);

  // Synchronous in-memory cache: instant render, no blank flash
  var cached = monthCache.get(key);
  if (cached !== undefined) {
    render(cached);
    // Data that came from the network seconds ago (a boot-time or
    // adjacent-month prefetch, or a quick back-and-forth) needs no
    // revalidation — the fetch would repeat the same request.
    // Older entries revalidate as always.
    if (!monthCache.isFresh(key, MONTH_FRESH_MS)) {
      revalidate(date, render);
    }
    return;
  }

  // Async IndexedDB fallback
  kvGet(key).then(function (value) {
    if (value === null || typeof value === "undefined") {
      // User already navigated elsewhere: nothing to fetch here.
      if (!navigations.isCurrent(token)) return;
      revalidate(date, render);
    } else {
      // Warming the in-memory cache is safe even when superseded —
      // the data sits under its own key.
      monthCache.set(key, value);
      // User already navigated elsewhere: skip the render and the
      // revalidation fetch.
      if (!navigations.isCurrent(token)) return;
      render(value);
      revalidate(date, render);
    }
  });
}

// Fetch `date` from the server and render it — unless a prefetch of
// the same month is still on the wire (the boot-time prefetch,
// usually): then wait for it and render its result instead of issuing
// a duplicate request. If it failed or was invalidated mid-flight,
// fall through to a normal fetch.
export function revalidate(date, render) {
  var token = navigations.bump();
  var key = keyForDate(date);
  var pending = networkInFlight[key];
  if (pending) {
    pending.then(function () {
      if (!navigations.isCurrent(token)) return;
      var cached = monthCache.get(key);
      if (cached !== undefined) {
        render(cached);
      } else {
        fetchMonth(date, token, render);
      }
    });
    return;
  }
  fetchMonth(date, token, render);
}

function fetchMonth(date, token, render) {
  axios
    .get(`/api/v1/communities/${Cookie.get("community_id")}/calendar/${date}`)
    .then(function (response) {
      if (response.status === 200) {
        // A newer navigation or refetch superseded this response:
        // drop it entirely. Rendering it would show the wrong month;
        // caching it could overwrite fresher same-month data.
        if (!navigations.isCurrent(token)) return;
        var respData = response.data;
        var key = monthCache.keyFor(respData.id, respData.year, respData.month);
        monthCache.set(key, respData);
        monthCache.markFresh(key);
        kvSet(key, respData).then(function () {
          if (!navigations.isCurrent(token)) return;
          render(respData);
        });
      }
    })
    .catch(function (error) {
      handleAxiosError(error, { silent: true });
    });
}
