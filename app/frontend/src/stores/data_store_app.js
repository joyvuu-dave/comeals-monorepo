// App-wide plumbing: Pusher boot, the 401 interceptor, the observable
// "today" and its midnight timer, the reconnect recovery, and logout.
// One of the DataStore's subsystem files — see data_store.js, which
// composes them.
import axios from "axios";
import Cookie from "js-cookie";
import dayjs from "dayjs";

import { pusherClient, startPusher } from "../helpers/pusher_client";
import { communityNow } from "../helpers/helpers";

export function appVolatile() {
  return {
    // Pending timer for the next community-midnight rollover of
    // communityToday, or null.
    midnightTimer: null,
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
      startPusher();

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
        self.handleReconnect();
      });

      self.setIsOnline(navigator.onLine);

      self.scheduleMidnightRecompute();

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
    // One recovery path for both wake-up signals: the Pusher reconnect
    // (afterCreate above) and the browser's `online` event (index.jsx).
    // Any gap means the data on screen can no longer be trusted, so
    // both signals do the same repairs.
    handleReconnect() {
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
      if (self.meal && self.meal.id) {
        self.loadDataAsync();
      }
      self.loadMonthAsync();
      // A cached hosts list may have missed an invalidation pushed
      // while offline — silently refresh it so the next modal to open
      // shows current data.
      if (self.hostsLoaded) {
        self.refetchHostsSilently();
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
    // right day — it always reads the clock fresh.
    scheduleMidnightRecompute() {
      if (self.midnightTimer !== null) {
        clearTimeout(self.midnightTimer);
      }
      var msUntilMidnight =
        communityNow().add(1, "day").startOf("day").diff(dayjs()) + 1000;
      self.midnightTimer = setTimeout(function () {
        self.recomputeCommunityToday();
        self.scheduleMidnightRecompute();
      }, msUntilMidnight);
    },
    // Clears every subsystem's timer — MST allows one beforeDestroy
    // per model, so it lives here.
    beforeDestroy() {
      if (self.midnightTimer !== null) {
        clearTimeout(self.midnightTimer);
      }
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
      }
    },
    setAuthExpired(value) {
      self.authExpired = value;
    },
  };
}
