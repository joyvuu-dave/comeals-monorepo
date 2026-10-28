// App-wide plumbing: Pusher boot, the 401 interceptor, the observable
// "today" and its midnight timer, the reconnect recovery, and logout.
// One of the DataStore's subsystem files — see data_store.js, which
// composes them.
import axios from "axios";
import Cookie from "js-cookie";

import { pusherClient, startPusher } from "../helpers/pusher_client";
import { pageSetting } from "../helpers/page_settings";
import {
  communityNow,
  getCommunityTimezone,
  msUntilNextMidnight,
} from "../helpers/helpers";
import { communityId } from "../helpers/session";
import { LONGEST_CRASH_WAIT_MS } from "../helpers/crash_reload_wait";
import * as monthData from "./month_fetch";

export function appVolatile() {
  return {
    // Pending timer for the next community-midnight rollover of
    // communityToday, or null.
    midnightTimer: null,
    // The one subscription to community-<id>-residents, made the first
    // time any page that shows residents loads and kept for the life
    // of the store (the name depends only on community_id).
    residentsChannel: null,
    // The page crashed: ErrorBoundary shows "Something went wrong".
    pageCrashed: false,
    // How long the idle timer waits before it loads the page after the
    // crash. ErrorBoundary hands it over with the crash. It grows when
    // the page keeps crashing (helpers/crash_reload_wait.ts). It starts
    // at the longest wait, so a crash noted with no wait never loads the
    // page at once (markPageCrashed).
    crashReloadWaitMs: LONGEST_CRASH_WAIT_MS,
    // VersionBanner found a newer build on the server than the code
    // running here.
    newVersionAvailable: false,
    // The open calendar form holds changes a person typed. The form
    // reports it (use_dirty_report.js), the discard gate reads it when
    // someone closes the form (calendar/show.jsx, ADR 0006), and the
    // idle timer reads it before it closes the form
    // (back_to_today.tsx). Nothing on screen reads it, so a keystroke
    // does not draw the calendar again.
    calendarFormDirty: false,
    // The open calendar form shows an error message of its own. The
    // form reports it (use_form_messages.ts), and the idle timer leaves
    // such a form open: the error would go with the form, and an error
    // stays until a person closes it (#137, back_to_today.tsx). The
    // discard gate does not read it.
    calendarFormErrorShown: false,
  };
}

// Pusher confirms each channel a moment after it is subscribed, and
// again after every reconnect. A push sent before that reached no one,
// so each confirmation is followed by a fetch of what the channel covers
// (#112). The month on screen is covered by two channels: its own and
// the residents channel. When both are on their way (at page load, and
// after a reconnect), the month is fetched once, after the later of the
// two, instead of once after each. The pusherClient wrapper of a
// channel carries `confirmed` (subscribeMonth in data_store_calendar.js
// and ensureResidentsChannel below set it). Without a Pusher key nothing
// is ever confirmed (the staging app), so nothing waits.
function confirmationPending(channel) {
  return (
    Boolean(pageSetting("comeals-pusher-key")) &&
    channel !== null &&
    channel.confirmed !== true
  );
}

export function appViews(self) {
  return {
    // The residents channel's confirmation is on its way. It drops
    // every copy of a month, so the months next to the one on screen
    // are not fetched until it has come (loadMonth).
    get residentsConfirmationPending() {
      return confirmationPending(self.residentsChannel);
    },
    // The month on screen's own confirmation is on its way, and it will
    // fetch the month.
    get monthOnScreenConfirmationPending() {
      return confirmationPending(window.Comeals.calendarChannel);
    },
  };
}

export function appActions(self) {
  return {
    afterCreate() {
      window.Comeals = {
        pusher: null,
        socketId: null,
        mealChannel: null,
        calendarChannel: null,
      };

      // pusherClient stands in for the real Pusher object, which loads
      // outside the main bundle so first paint does not wait for it.
      // Subscriptions made before it arrives are queued and replayed.
      // See helpers/pusher_client.js.
      window.Comeals.pusher = pusherClient;
      // If the library fails to load, the page reloads once, and the
      // reload ends every bills save on its way, so each one is sent
      // again with keepalive first (#150).
      startPusher(function () {
        self.sendBillsAgainBeforeClose();
      });

      window.Comeals.pusher.connection.bind("connected", function () {
        window.Comeals.socketId = window.Comeals.pusher.connection.socket_id;
      });

      // Pusher does not replay events broadcast while the socket was down,
      // so after ANY gap the data on screen can no longer be trusted.
      // Refetch on every transition to "connected" except the first one at
      // page load — the page-load fetch is already in flight then. Checking
      // previous === "unavailable" is not enough: pusher-js only reaches
      // "unavailable" after ~10s, so a shorter blip reconnects as
      // connecting → connected and its dropped events would go unnoticed.
      let hasConnectedBefore = false;
      window.Comeals.pusher.connection.bind("state_change", function (states) {
        // states = {previous: 'oldState', current: 'newState'}
        if (states.current !== "connected") return;
        if (!hasConnectedBefore) {
          hasConnectedBefore = true;
          return;
        }
        // pusher-js subscribes every channel again on this same
        // "connected" event, and Pusher confirms each one a moment later.
        [
          self.residentsChannel,
          window.Comeals.calendarChannel,
          ...self.adjacentChannels,
        ].forEach(function (channel) {
          if (channel !== null) channel.confirmed = false;
        });
        self.handleReconnect({
          residentsWillConfirm: self.residentsChannel !== null,
        });
      });

      self.setIsOnline(navigator.onLine);

      self.scheduleMidnightRecompute();

      // The community's zone, from each month the server sends.
      monthData.onServerZone(self.adoptCommunityTimezone);

      if (typeof window.__comealsInterceptor !== "undefined") {
        axios.interceptors.response.eject(window.__comealsInterceptor);
      }
      window.__comealsInterceptor = axios.interceptors.response.use(
        function (response) {
          return response;
        },
        function (error) {
          if (error.response && error.response.status === 401) {
            self.setAuthExpired(true);
          }
          return Promise.reject(error);
        },
      );
    },
    logout() {
      // Best-effort server-side revocation. Fire-and-forget: even if the
      // request fails (offline, expired token) we still clear local state —
      // the user tapped "log out" and should see themselves logged out.
      //
      // Attach the bearer header explicitly before clearing the cookie. The
      // global request interceptor runs as a microtask, so if we relied on
      // it the cookie would already be gone by the time it read `token` —
      // the DELETE would dispatch unauthenticated and the server would 401
      // before destroying the legacy Key row.
      const token = Cookie.get("token");
      if (token) {
        axios
          .delete("/api/v1/sessions/current", {
            headers: { Authorization: `Bearer ${token}` },
          })
          .catch(() => {});
      }

      Cookie.remove("token", { path: "/" });
      Cookie.remove("community_id", { path: "/" });
      Cookie.remove("resident_id", { path: "/" });
      Cookie.remove("username", { path: "/" });
      Cookie.remove("timezone", { path: "/" });
    },
    setIsOnline(val) {
      self.isOnline = !!val;
    },
    // The idle timer reads these two: a move inside the app fixes
    // neither, so it loads the page again (back_to_today.tsx). Each
    // goes one way. The page load starts a new store.
    //
    // A wait of 0 would load a page that crashes every time as fast as
    // it loads, all day. So a crash noted with no wait, or with a wait
    // that is not a number of milliseconds above 0, waits the longest
    // time. So does a wait longer than that: a browser runs a timer of
    // more than about 24 days at once.
    markPageCrashed(reloadWaitMs) {
      self.pageCrashed = true;
      self.crashReloadWaitMs =
        typeof reloadWaitMs === "number" && reloadWaitMs > 0
          ? Math.min(reloadWaitMs, LONGEST_CRASH_WAIT_MS)
          : LONGEST_CRASH_WAIT_MS;
    },
    markNewVersionAvailable() {
      self.newVersionAvailable = true;
    },
    setCalendarFormDirty(value) {
      self.calendarFormDirty = value;
    },
    setCalendarFormErrorShown(value) {
      self.calendarFormErrorShown = value;
    },
    // Subscribe to the residents channel once. The server pushes it
    // when a resident or unit changes in any way a screen shows
    // (Resident#note_live_update): the hosts dropdown, the meal page's
    // sign-up list and every calendar month list residents, so all of
    // them are stale at once. With no session there is no channel to
    // open: a list can arrive after a logout, just before the page loads
    // "/" again (#153).
    ensureResidentsChannel() {
      if (self.residentsChannel) return;
      var id = communityId();
      if (id === null) return;
      self.residentsChannel = window.Comeals.pusher.subscribe(
        `community-${id}-residents`,
      );
      self.residentsChannel.bind("update", function () {
        self.handleResidentsUpdate();
      });
      // Pusher confirmed the subscription, at page load or again after a
      // reconnect. A push sent before this reached no one, so any copy
      // of a month, a meal or the hosts list read before it may hold an
      // old name. The confirmation does what a push does.
      var channel = self.residentsChannel;
      channel.bind("pusher:subscription_succeeded", function () {
        channel.confirmed = true;
        self.handleResidentsUpdate();
      });
      // Pusher refused the channel, so it will never confirm it. What
      // waited for its confirmation goes on without it.
      channel.bind("pusher:subscription_error", function (error) {
        console.warn("Pusher refused the residents channel:", error);
        channel.confirmed = true;
        self.handleResidentsUpdate();
      });
    },
    // A resident or unit changed, or may have changed while no push
    // could reach this page. Every cached month and meal may hold the
    // old name, so all of them go, and whatever is on screen is fetched
    // again.
    handleResidentsUpdate() {
      monthData.invalidateAllMonths();
      self.refetchHostsIfAskedFor();
      if (self.meal && self.meal.id) {
        self.loadDataAsync();
      }
      // The month's own confirmation fetches it when it is still on
      // its way, after this one.
      if (
        window.Comeals.calendarChannel !== null &&
        !self.monthOnScreenConfirmationPending
      ) {
        self.loadMonthAsync();
      }
    },
    // One recovery path for both wake-up signals: the Pusher reconnect
    // (afterCreate above) and the browser's `online` event (index.jsx).
    // Any gap means the data on screen can no longer be trusted, so
    // both signals do the same repairs.
    //
    // With `residentsWillConfirm` (a Pusher reconnect while the residents
    // channel is open), Pusher confirms that channel again in a moment,
    // and handleResidentsUpdate then fetches the meal, the month on the
    // calendar and the hosts list. Its reads come after pushes reach
    // this page again, so those fetches are left to it: the same fetch
    // made here would read earlier, and the later answer replaces it.
    // The browser's `online` event can come with no Pusher reconnect at
    // all, so it fetches all of them here.
    handleReconnect(options = {}) {
      // A machine asleep past midnight wakes with a stale "today" and a
      // throttled timer; the wake-up is the reliable recompute moment.
      // Before the cookie guard on purpose — no auth needed.
      self.recomputeCommunityToday();
      // Unsaved menu text next: most description save failures are
      // network blips, and this is the moment to resend (issue #35).
      // A signed-out session has no dirty meals, so no guard needed.
      self.retryDirtyDescriptions();
      // Logged out (or on the login page) there is nothing to refetch,
      // and an unauthenticated fetch would 401 and raise the "signed
      // out" banner.
      if (typeof Cookie.get("community_id") === "undefined") return;
      var leftToConfirmation = options.residentsWillConfirm === true;
      if (self.meal && self.meal.id && !leftToConfirmation) {
        self.loadDataAsync();
      }
      // The meal page shows no month, and a month drawn there would
      // open the calendar's channels again, which the meal page closed
      // (#38). Going back to the calendar fetches the month again.
      // On the calendar, handleResidentsUpdate fetches the month only
      // while the month's channel is open. With none open yet (the
      // first month never arrived), the month is fetched here.
      var onCalendar = !self.meal;
      if (
        onCalendar &&
        (window.Comeals.calendarChannel === null || !leftToConfirmation)
      ) {
        self.loadMonthAsync();
      }
      // A hosts list may have missed an invalidation pushed while
      // offline — fetch it again so the next modal to open shows current
      // data. The old list stays on screen meanwhile, and a failed fetch
      // shows no message.
      if (!leftToConfirmation) {
        self.refetchHostsIfAskedFor();
      }
    },
    // Roll the observable "today" forward. Called by the midnight timer
    // and handleReconnect.
    recomputeCommunityToday() {
      self.communityToday = communityNow().format("YYYY-MM-DD");
    },
    // Fire one second past the next community-timezone midnight (the
    // buffer keeps an on-time firing from landing on the old day), roll
    // communityToday over, and schedule the next one. If the tab was
    // asleep and the timer fires late, recompute still lands on the
    // right day — it always reads the clock fresh. The wait is worked
    // out in the community's zone without the device's own zone, so it
    // is right on a device anywhere and is never zero or less (#122).
    scheduleMidnightRecompute() {
      if (self.midnightTimer !== null) {
        clearTimeout(self.midnightTimer);
      }
      var msUntilMidnight =
        msUntilNextMidnight(Date.now(), getCommunityTimezone()) + 1000;
      self.midnightTimer = setTimeout(function () {
        self.recomputeCommunityToday();
        self.scheduleMidnightRecompute();
        // A meal chip's words come from the server and depend on the
        // day ("signed up" becomes "attending"), and nothing writes at
        // midnight to push the change — so the calendar fetches the
        // month again itself.
        // A birthday moves someone into the adult band with no write
        // on the server, so nothing pushes it: the hosts list is
        // fetched again too, if this screen has one.
        self.refetchHostsIfAskedFor();
        if (window.Comeals.calendarChannel !== null) {
          self.loadMonthAsync();
        }
      }, msUntilMidnight);
    },
    // Clears every subsystem's timer — MST allows one beforeDestroy
    // per model, so it lives here. clearTimeout(null) does nothing, so a
    // timer that is not pending needs no check.
    beforeDestroy() {
      clearTimeout(self.midnightTimer);
      clearTimeout(self.mealRetryTimer);
      clearTimeout(self.mealRefetchRetryTimer);
    },
    setAuthExpired(value) {
      self.authExpired = value;
    },
  };
}
