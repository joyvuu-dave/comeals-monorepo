import { types, isAlive } from "mobx-state-tree";
import { v4 } from "uuid";
import axios from "axios";
import Cookie from "js-cookie";

import Meal from "./meal";
import ResidentStore from "./resident_store";
import BillStore from "./bill_store";
import GuestStore from "./guest_store";
import * as monthCache from "./month_cache";

import Pusher from "pusher-js";
import localforage from "localforage";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import handleAxiosError from "../helpers/handle_axios_error";
import { api } from "../helpers/api";
import {
  communityNow,
  toCommunityDayjs,
  SAVE_DEBOUNCE_MS,
} from "../helpers/helpers";
import { isZeroAmountString, toDisplayAmountString } from "../helpers/money";
import { evictMealCache } from "../helpers/meal_cache";
import { mark, logEvent } from "../helpers/nav_trace";
import toastStore from "./toast_store";

dayjs.extend(utc);
dayjs.extend(timezone);

// The in-memory calendar month cache and its per-key invalidation
// versions live in ./month_cache (imported above as `monthCache`).
// It is a capped LRU; IndexedDB keeps the persistent copies under
// the same keys.

// Pusher subscriptions for adjacent months (cache invalidation only).
var adjacentChannels = [];

// In-flight promise for the hosts fetch, so concurrent callers
// (two modals opened in quick succession) don't trigger duplicate
// network requests. Cleared when the fetch settles.
var hostsInFlight = null;

// Monotonic counter for hosts fetches. Bumped every time a new fetch
// starts; the resolve path compares against the captured `versionAtStart`
// and discards a response whose version was superseded by a later fetch
// (Pusher invalidation + refetch while an older fetch is still in flight).
// Same pattern as the month cache's invalidation versions.
var hostsVersion = 0;

// Monotonic counter for month navigation, same pattern as `hostsVersion`.
// Bumped at the start of every loadMonthAsync and switchMonths call; each
// async continuation captures the value at start and checks it before
// touching the screen, so the newest navigation always wins. A superseded
// fetch response is dropped entirely — caching it could overwrite fresher
// data for the same month. A superseded IndexedDB read may still warm
// `monthCache` (its data is correct under its own key) but skips rendering
// and skips its revalidation fetch.
var monthFetchVersion = 0;

// Single Pusher subscription for hosts updates. Assigned the first
// time ensureHosts() succeeds; never resubscribed for the lifetime
// of the store because the channel name only depends on community_id.
var hostsChannel = null;

// Backoff for retrying a failed FIRST load of a meal: 2s, 4s, 8s,
// 16s, then every 30s — forever. A shared screen must heal without a
// human tap, and at 30s the retries cost the server nothing.
const MEAL_RETRY_BASE_MS = 2000;
const MEAL_RETRY_CAP_MS = 30000;

function invalidateMonth(communityId, year, month) {
  var key = monthCache.keyFor(communityId, year, month);
  monthCache.remove(key);
  localforage.removeItem(key);
  monthCache.bumpVersion(key);
}

function prefetchMonthData(date) {
  var myDate = dayjs(date);
  var key = monthCache.keyFor(
    Cookie.get("community_id"),
    myDate.format("YYYY"),
    myDate.format("M"),
  );

  // The read also marks the month as recently used, so an adjacent
  // month that is already cached stays away from the eviction end.
  if (monthCache.get(key) !== undefined) return;

  logEvent("prefetch-start", { date });
  var versionAtStart = monthCache.versionFor(key);

  localforage.getItem(key).then(function (value) {
    // Discard if a Pusher invalidation arrived since we started
    if (monthCache.versionFor(key) !== versionAtStart) return;

    if (value !== null && typeof value !== "undefined") {
      monthCache.set(key, value);
      return;
    }

    axios
      .get(`/api/v1/communities/${Cookie.get("community_id")}/calendar/${date}`)
      .then(function (response) {
        if (response.status === 200) {
          // Discard if a Pusher invalidation arrived since we started
          if (monthCache.versionFor(key) !== versionAtStart) return;
          monthCache.set(key, response.data);
          localforage.setItem(key, response.data);
        }
      })
      .catch(function () {
        // Prefetch failure is non-critical
      });
  });
}

export const DataStore = types
  .model("DataStore", {
    // One loading flag per page (issue #38). They used to be a single
    // shared flag, so a calendar event landing mid-meal-load could wake
    // the prev/next arrows before nextId/prevId existed.
    mealLoading: true,
    monthLoading: true,
    editDescriptionMode: true,
    editBillsMode: true,
    // True while an open/close save is in flight; the button is disabled.
    closedPending: false,
    // The first load of the meal on screen failed and automatic
    // retries are running. Shows the "Trouble loading" notice.
    mealLoadFailed: false,
    // The server said 404: the meal does not exist. Retrying cannot
    // fix that, so this shows a message and a way back instead.
    mealLoadNotFound: false,
    meal: types.maybeNull(types.reference(Meal)),
    meals: types.optional(types.array(Meal), []),
    residentStore: types.optional(ResidentStore, {
      residents: {},
    }),
    billStore: types.optional(BillStore, {
      bills: {},
    }),
    guestStore: types.optional(GuestStore, {
      guests: {},
    }),
    calendarName: types.optional(types.string, ""),
    userName: types.optional(types.string, ""),
    calendarEvents: types.optional(types.array(types.frozen()), []),
    // Monotonic counter bumped whenever calendarEvents changes (replace or
    // clear). The Calendar component is wrapped in React.memo and diffs a
    // cached snapshot of events keyed off this version — this gives us a
    // cheap way to skip the ~3.5ms/event render cost when a parent re-render
    // (e.g. modal open/close) didn't actually change the event set.
    calendarEventsVersion: types.optional(types.number, 0),
    currentDate: types.optional(types.string, function () {
      return communityNow().format("YYYY-MM-DD");
    }),
    // "Today" in the community timezone, as observable state. Render-time
    // reads (the calendar header, the today highlight, past-event dimming,
    // the meal page's day label) use this so an idle tab re-renders when
    // the day changes. A timer set for the next community midnight rolls
    // it over; the `online` handler and the Pusher reconnect handler
    // recompute it too, because background tabs throttle timers.
    // Click-time reads keep calling communityNow() directly — a click
    // always computes a fresh value, so those were never stale.
    communityToday: types.optional(types.string, function () {
      return communityNow().format("YYYY-MM-DD");
    }),
    isOnline: false,
    authExpired: false,
    // Cached community hosts (adult + active residents with units), used by
    // the Guest Room and Common House reservation New/Edit modals.
    // Shape: [{ id, name, unitName }, ...] — transformed from the API's
    // tuple shape ([residents.id, residents.name, units.name]) at the store
    // boundary in setHosts.
    // Kept fresh by Pusher `community-<id>-residents` real-time refetch
    // and silent refetch on reconnect. See ensureHosts.
    hosts: types.optional(types.array(types.frozen()), []),
    // Non-null timestamp means the hosts array reflects a completed fetch.
    hostsLoadedAt: types.maybeNull(types.number),
  })
  // Bill save pipeline state (issue #30). Volatile: per-session request
  // bookkeeping, not data.
  .volatile(() => ({
    // Pending debounce timer for a bill save, or null.
    billsSaveTimer: null,
    // Bumped on every bill edit. A save captures the value at send time;
    // the ack applies only if it has not moved since — so a response can
    // never overwrite keystrokes newer than the request.
    billsEditVersion: 0,
    // True while a bills request is in flight. With one request at a time,
    // this client's writes cannot arrive at the server out of order.
    billsSaveInFlight: false,
    // A save was requested while one was in flight; send one more request
    // with the latest state when it settles.
    billsSaveQueued: false,
    // Pending timer for the next community-midnight rollover of
    // communityToday, or null.
    midnightTimer: null,
    // Pending timer for the next automatic meal-load retry, or null.
    mealRetryTimer: null,
    // The wait used for the last scheduled retry, or null when the
    // backoff is at its starting point.
    mealRetryDelayMs: null,
  }))
  .views((self) => ({
    get hostsLoaded() {
      return self.hostsLoadedAt !== null;
    },
    get description() {
      if (!self.meal) return "";
      return self.meal.description;
    },
    get residents() {
      return self.residentStore.residents;
    },
    get bills() {
      return self.billStore.bills;
    },
    get guests() {
      return self.guestStore.guests;
    },
    get guestsCount() {
      return self.guestStore.guests.size;
    },
    get mealResidentsCount() {
      return Array.from(self.residents.values()).filter(
        (resident) => resident.attending,
      ).length;
    },
    get attendeesCount() {
      return self.guestsCount + self.mealResidentsCount;
    },
    get vegetarianCount() {
      const vegResidents = Array.from(self.residents.values()).filter(
        (resident) => resident.attending && resident.vegetarian,
      ).length;

      const vegGuests = Array.from(self.guests.values()).filter(
        (guest) => guest.vegetarian,
      ).length;

      return vegResidents + vegGuests;
    },
    get lateCount() {
      return Array.from(self.residents.values()).filter(
        (resident) => resident.attending && resident.late,
      ).length;
    },
    // Assigned cooks whose cost is still blank: no amount and no
    // no-cost flag. A zero amount means "not filled in yet" — the same
    // test loadData uses to display zero as blank — so the list behaves
    // the same before and after a reload. The close button asks about
    // these names before closing; a later reminder task works off the
    // same state.
    get cooksMissingCost() {
      return Array.from(self.bills.values())
        .filter(
          (bill) =>
            bill.resident_id !== "" &&
            isZeroAmountString(bill.amount) &&
            bill.no_cost === false,
        )
        .map((bill) => bill.resident.plainName);
    },
    get extras() {
      if (!self.meal) return "n/a";
      // Extras only show when the meal is closed
      if (!self.meal.closed) {
        return "n/a";
      }

      if (self.meal.closed && typeof self.meal.max === "number") {
        return self.meal.max - self.attendeesCount;
      } else {
        return "";
      }
    },
    get canAdd() {
      if (!self.meal) return false;
      return (
        !self.meal.closed ||
        (self.meal.closed &&
          typeof self.extras === "number" &&
          self.extras >= 1)
      );
    },
  }))
  .actions((self) => ({
    afterCreate() {
      window.Comeals = {
        pusher: null,
        socketId: null,
        mealChannel: null,
        calendarChannel: null,
      };

      // Pusher public key + cluster from env vars (VITE_PUSHER_KEY, VITE_PUSHER_CLUSTER).
      // Local dev: .env file (committed defaults). Override via .env.local if needed.
      window.Comeals.pusher = new Pusher(import.meta.env.VITE_PUSHER_KEY, {
        cluster: import.meta.env.VITE_PUSHER_CLUSTER,
        encrypted: true,
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
        // A laptop asleep past midnight wakes with a stale "today" and a
        // throttled timer; the reconnect is the reliable wake-up signal.
        // Before the cookie guard on purpose — no auth needed.
        self.recomputeCommunityToday();
        // Logged out (or on the login page) there is nothing to refetch,
        // and an unauthenticated fetch would 401 and raise the "signed
        // out" banner. Same guard as the `online` handler in index.jsx.
        if (typeof Cookie.get("community_id") === "undefined") return;
        if (self.meal && self.meal.id) {
          self.loadDataAsync();
        }
        self.loadMonthAsync();
        // If we had a cached hosts list, any invalidation pushed while
        // offline was missed — silently refresh it now so the next modal
        // to open shows current data.
        if (self.hostsLoaded) {
          self.refetchHostsSilently();
        }
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
    toggleEditDescriptionMode() {
      const isSaving = self.editDescriptionMode;
      self.editDescriptionMode = !self.editDescriptionMode;

      if (isSaving && self.meal) {
        self.meal.submitDescription();
      }
    },
    toggleEditBillsMode() {
      const isSaving = self.editBillsMode;
      self.editBillsMode = !self.editBillsMode;

      if (isSaving) {
        self.submitBills();
      }
    },
    // Debounced, same delay as the description field: a save fires only
    // after the user stops editing, so half-typed amounts never hit the
    // wire and each pause produces one request instead of one per keystroke.
    saveBills() {
      self.billsEditVersion += 1;
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
      }
      self.billsSaveTimer = setTimeout(function () {
        self.flushBillsSave();
      }, SAVE_DEBOUNCE_MS);
    },
    flushBillsSave() {
      self.billsSaveTimer = null;
      self.submitBills();
    },
    // Send a pending debounced save right now. Blur and meal navigation
    // call this, so "type, then click away" saves immediately — the
    // debounce only spans pauses while the field still has focus. Without
    // this, closing the tab inside the debounce window would lose the
    // edit.
    flushPendingBillsSave() {
      if (self.billsSaveTimer !== null) {
        self.submitBills();
      }
    },
    // The description save pipeline lives on the meal node (issue #35),
    // so unsaved text stays protected even after the user navigates to
    // another meal. The menu box binds these two actions to the node it
    // rendered: a debounced flush that fires after a meal switch must
    // land on the meal the text was typed on — landing on store.meal
    // silently replaced the NEW meal's menu.
    setDescriptionOn(node, val) {
      if (!node || !isAlive(node)) return;
      node.setDescription(val);
    },
    // Called on every keystroke, before any flush: a dirty node
    // survives the switchMeals prune, so its text still has a live
    // node to land on.
    noteMenuTyping(node) {
      if (!node || !isAlive(node)) return;
      node.markDescriptionEditing();
    },
    // Resend unsaved menu text (issue #35). The `online` handler calls
    // this: most description save failures are network blips, so the
    // retry usually clears the "not saved" marker without the user doing
    // anything.
    retryDirtyDescriptions() {
      self.meals.forEach(function (meal) {
        if (meal.descriptionDirty) {
          meal.submitDescription();
        }
      });
    },
    // Runs when the open/close save settles — success or failure. The
    // refetch lets loadData write the server's truth, including the
    // server's closed_at (the client clock is never used). There is no
    // rollback on purpose: the meal node is edited in place by refetches,
    // so a blind flip could invert fresh data.
    settleClosed() {
      self.closedPending = false;
      self.loadDataAsync();
    },
    // Closing no longer requires costs to be filled in. Forcing a
    // number before the shopping happened bred fake $1 costs; the close
    // button asks about blank costs (cooksMissingCost) and the cook
    // closes with a deliberate Yes instead. Bills stay editable until
    // reconciliation.
    toggleClosed() {
      if (self.closedPending) {
        return;
      }

      const val = !self.meal.closed;
      self.meal.closed = val;
      self.closedPending = true;

      api.meals
        .updateClosed(self.meal.id, {
          closed: val,
          socketId: window.Comeals.socketId,
        })
        .catch(function (error) {
          handleAxiosError(error);
        })
        .then(function () {
          self.settleClosed();
        });
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
    submitBills() {
      // A direct submit (save button, meal switch) supersedes a pending
      // debounced save — it sends the same latest state now.
      if (self.billsSaveTimer !== null) {
        clearTimeout(self.billsSaveTimer);
        self.billsSaveTimer = null;
      }

      // No meal, nothing to save to. The timer above is already
      // cancelled, so a save that outlived the meal page ends here.
      if (!self.meal) {
        return;
      }

      // Only touched rows carry values to the server, so only they can
      // block the save.
      if (
        Array.from(self.bills.values()).some(
          (bill) => bill.touched && bill.amountIsValid === false,
        )
      ) {
        self.editBillsMode = true;
        return;
      }

      // Single-flight: one request at a time. The queued resend in
      // settleBillsSave sends whatever was edited meanwhile.
      if (self.billsSaveInFlight) {
        self.billsSaveQueued = true;
        return;
      }

      // The payload lists every cook (the server deletes bills for cooks
      // left out), but only rows the user touched carry amount/no_cost.
      // The server leaves the other rows' stored values alone, so a
      // display value can never rewrite a bill nobody edited.
      let bills = Array.from(self.bills.values())
        .filter((bill) => bill.resident_id !== "")
        .map((bill) =>
          bill.touched
            ? {
                resident_id: bill.resident_id,
                amount: bill.amount,
                no_cost: bill.no_cost,
              }
            : { resident_id: bill.resident_id },
        );

      const versionAtSend = self.billsEditVersion;
      const mealIdAtSend = self.meal.id;
      self.billsSaveInFlight = true;

      api.meals
        .updateBills(mealIdAtSend, {
          bills,
          socketId: window.Comeals.socketId,
        })
        .then(function (response) {
          // The server saved the bills, so the cached meal payload is
          // now stale (issue #37).
          evictMealCache(mealIdAtSend);
          self.applyBillsAck(response.data, versionAtSend, mealIdAtSend);
        })
        .catch(function (error) {
          var isWarning =
            error.response &&
            error.response.data &&
            error.response.data.type === "warning";
          if (isWarning) {
            // A warning response still persisted the bills — evict, same
            // as the success path.
            evictMealCache(mealIdAtSend);
            var msg = error.response.data.message || "";
            toastStore.replaceAll(
              "Cooks saved." + (msg ? " " + msg : ""),
              "info",
            );
          } else {
            handleAxiosError(error);
          }

          self.loadDataAsync();
        })
        .then(function () {
          self.settleBillsSave(mealIdAtSend);
        });
    },
    // Display what the server stored, not what we sent — but only when the
    // rows on screen are the rows this ack answers: same meal, and no edits
    // since the request went out. Otherwise ignore it; the queued next save
    // covers the newer edits and its own ack will reconcile.
    applyBillsAck(data, versionAtSend, mealIdAtSend) {
      if (versionAtSend !== self.billsEditVersion) return;
      if (!self.meal || self.meal.id !== mealIdAtSend) return;
      if (!data || !Array.isArray(data.bills)) return;

      data.bills.forEach(function (row) {
        const bill = Array.from(self.bills.values()).find(
          (b) => b.resident && b.resident.id === row.resident_id,
        );
        if (!bill) return;
        // Rewrite the amount only when the server disagrees with the
        // screen. When the values match, a rewrite is pure reformatting
        // ("1" becomes "1.00") and it lands under the cursor: the next
        // keystroke makes "1.000", which the whole-cents grammar refuses,
        // so the keystroke is swallowed. The field pads itself on blur
        // instead.
        const serverAmount = toDisplayAmountString(row.amount);
        if (serverAmount !== toDisplayAmountString(bill.amount)) {
          bill.amount = serverAmount;
        }
        bill.no_cost = row.no_cost;
        // The row now shows exactly what the server stored, so it no
        // longer needs to assert values on the next save — and a stale
        // resend can no longer overwrite another client's newer edit.
        bill.touched = false;
      });
    },
    settleBillsSave(mealIdAtSend) {
      self.billsSaveInFlight = false;
      if (!self.billsSaveQueued) return;
      self.billsSaveQueued = false;
      // The queued edit was typed on the meal the last save targeted. If
      // the user switched meals while the request was in flight, the rows
      // it came from are gone — there is nothing valid to resend.
      if (!self.meal || self.meal.id !== mealIdAtSend) return;
      self.submitBills();
    },
    loadDataAsync() {
      // Leaving the meal page nulls the meal (issue #38). A settle
      // callback that lands after that has nothing to refetch.
      if (!self.meal) return;
      const mealIdAtFetch = self.meal.id;
      api.meals
        .getCooks(mealIdAtFetch)
        .then(
          function (response) {
            if (response.status === 200) {
              return localforage
                .setItem(response.data.id.toString(), response.data)
                .then(function () {
                  // Skip stale responses from a previous meal
                  if (self.meal && self.meal.id === response.data.id) {
                    self.loadData(response.data);
                  }
                });
            }
          },
          // Second then-handler on purpose: it fires only when the
          // FETCH rejected. The retry treatment is for network
          // failures — a bug while processing a good response must
          // not loop retries forever. The state change comes first:
          // the console logging must not be able to break it.
          function (error) {
            self.handleMealLoadError(error, mealIdAtFetch);
            handleAxiosError(error, { silent: true });
          },
        )
        .catch(function (error) {
          // A processing failure keeps its old silent behavior.
          handleAxiosError(error, { silent: true });
        });
    },
    // A meal fetch failed. Only the FIRST load of the meal on screen
    // gets the retry treatment: with mealLoading false there is data
    // on screen, and background refetch failures already heal through
    // the reconnect and online handlers. A 404 means the meal does
    // not exist — no retry can fix that.
    handleMealLoadError(error, mealId) {
      if (!self.meal || self.meal.id !== mealId) return;
      if (!self.mealLoading) return;
      const status = error && error.response && error.response.status;
      if (status === 404) {
        self.cancelMealRetry();
        self.mealLoadNotFound = true;
        return;
      }
      self.mealLoadFailed = true;
      self.scheduleMealRetry(mealId);
    },
    scheduleMealRetry(mealId) {
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
      }
      self.mealRetryDelayMs =
        self.mealRetryDelayMs === null
          ? MEAL_RETRY_BASE_MS
          : Math.min(self.mealRetryDelayMs * 2, MEAL_RETRY_CAP_MS);
      self.mealRetryTimer = setTimeout(function () {
        self.onMealRetryTimer(mealId);
      }, self.mealRetryDelayMs);
    },
    onMealRetryTimer(mealId) {
      self.mealRetryTimer = null;
      // The screen may have moved on while the timer waited.
      if (!self.meal || self.meal.id !== mealId) return;
      if (!self.mealLoading) return;
      self.loadDataAsync();
    },
    // The "Retry now" button. Resets the backoff: a person is watching
    // now, so if this try also fails the next automatic one should
    // come quickly again.
    retryMealLoadNow() {
      if (!self.meal || !self.mealLoading) return;
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
        self.mealRetryTimer = null;
      }
      self.mealRetryDelayMs = null;
      self.loadDataAsync();
    },
    // Cancels any pending retry and forgets the failure. Runs when the
    // meal on screen changes (switch, teardown) and when a load lands.
    cancelMealRetry() {
      if (self.mealRetryTimer !== null) {
        clearTimeout(self.mealRetryTimer);
        self.mealRetryTimer = null;
      }
      self.mealRetryDelayMs = null;
      self.mealLoadFailed = false;
      self.mealLoadNotFound = false;
    },
    loadMonthAsync() {
      monthFetchVersion += 1;
      var versionAtStart = monthFetchVersion;
      logEvent("loadMonthAsync-start", { date: self.currentDate });
      axios
        .get(
          `/api/v1/communities/${Cookie.get("community_id")}/calendar/${
            self.currentDate
          }`,
        )
        .then(function (response) {
          if (response.status === 200) {
            // A newer navigation or refetch superseded this response:
            // drop it entirely. Rendering it would show the wrong month;
            // caching it could overwrite fresher same-month data.
            if (versionAtStart !== monthFetchVersion) return;
            var respData = response.data;
            var key = monthCache.keyFor(
              respData.id,
              respData.year,
              respData.month,
            );
            monthCache.set(key, respData);
            localforage.setItem(key, respData).then(function () {
              if (versionAtStart !== monthFetchVersion) return;
              logEvent("loadMonthAsync-resolved", { date: self.currentDate });
              self.loadMonth(respData);
            });
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
        });
    },
    // Guarantee the hosts list is loaded. Resolves immediately if the
    // cache is warm; otherwise kicks off a fetch (deduped against any
    // concurrent ensureHosts caller) and resolves when it lands.
    ensureHosts() {
      if (self.hostsLoaded) return Promise.resolve(self.hosts);
      return self._fetchHosts({ supersede: false });
    },
    // Refresh the hosts cache without clearing it first — the existing
    // array keeps rendering in any open modal until the new data arrives,
    // avoiding a flicker-to-empty. Used on Pusher update (residents changed
    // server-side) and Pusher reconnect (may have missed an update while
    // offline). Supersedes any in-flight ensureHosts fetch so we don't
    // serve a potentially-stale response.
    //
    // On failure: silently keeps the previously-loaded list visible. The
    // next Pusher `update` event (or reconnect) will re-trigger this path,
    // so transient network blips self-heal without user-visible errors.
    refetchHostsSilently() {
      return self._fetchHosts({ supersede: true });
    },
    // Internal: shared fetch implementation for ensureHosts and
    // refetchHostsSilently. Every call bumps `hostsVersion`; the resolve
    // path compares against the captured version and discards stale
    // responses (same pattern as the month cache).
    //
    //   supersede: false — dedupe onto any in-flight fetch
    //   supersede: true  — start a fresh fetch even if one is in flight;
    //                      the in-flight response will be version-skipped
    _fetchHosts(options = {}) {
      if (hostsInFlight && !options.supersede) return hostsInFlight;

      hostsVersion += 1;
      var versionAtStart = hostsVersion;
      var communityId = Cookie.get("community_id");

      var promise = axios
        .get(`/api/v1/communities/${communityId}/hosts`)
        .then(function (response) {
          // Superseded by a later fetch: let the winner's response win.
          if (versionAtStart !== hostsVersion) return self.hosts;
          if (response.status === 200) {
            self.setHosts(response.data);
            self.subscribeHostsChannel(communityId);
          }
          return self.hosts;
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
          return self.hosts;
        })
        .finally(function () {
          // Only clear the in-flight ref if we're still the reigning fetch.
          // A superseding fetch has already replaced `hostsInFlight` with
          // its own promise; don't trample it.
          if (versionAtStart === hostsVersion) hostsInFlight = null;
        });
      hostsInFlight = promise;
      return promise;
    },
    // Transform the API's tuple shape ([residents.id, residents.name,
    // units.name]) into named-field objects at the store boundary so every
    // consumer reads host.id / host.name / host.unitName instead of cryptic
    // [0]/[1]/[2] indexing. The backend pluck order is set in
    // CommunitiesController#hosts — keep these in sync.
    setHosts(data) {
      var transformed = data.map(function (row) {
        return { id: row[0], name: row[1], unitName: row[2] };
      });
      self.hosts.replace(transformed);
      self.hostsLoadedAt = Date.now();
    },
    subscribeHostsChannel(communityId) {
      if (hostsChannel) return;
      hostsChannel = window.Comeals.pusher.subscribe(
        `community-${communityId}-residents`,
      );
      hostsChannel.bind("update", function () {
        self.refetchHostsSilently();
      });
    },
    preLoadData() {
      if (self.billStore && self.billStore.bills) {
        self.clearBills();
      }
      if (self.residentStore && self.residentStore.residents) {
        self.clearResidents();
      }
      if (self.guestStore && self.guestStore.guests) {
        self.clearGuests();
      }
    },
    loadData(data) {
      self.preLoadData();

      // Assign Meal Data — construct a "fake local" Date whose year/month/day
      // components come from the community's timezone so that dayjs(meal.date)
      // always reflects the community day, consistent with getCommunityNow()
      // in calendar/show.jsx.
      var d = toCommunityDayjs(data.date);
      self.meal.date = new Date(d.year(), d.month(), d.date());
      // While the menu has unsaved typing, a reload must not overwrite it
      // (issue #35): your text wins on your own screen until it saves.
      // After it saves, last-write-wins as usual.
      if (!self.meal.descriptionDirty) {
        self.meal.description = data.description;
      }
      self.meal.closed = data.closed;
      self.meal.closed_at = data.closed_at ? new Date(data.closed_at) : null;
      self.meal.reconciled = data.reconciled;
      self.meal.nextId = data.next_id;
      self.meal.prevId = data.prev_id;

      if (data.max === null) {
        self.meal.extras = null;
      } else {
        const residentsCount = data.residents.filter(
          (resident) => resident.attending,
        ).length;

        const guestsCount = data.guests.length;
        self.meal.extras = data.max - (residentsCount + guestsCount);
      }

      let residents = data.residents.sort((a, b) => {
        if (a.name < b.name) return -1;
        if (a.name > b.name) return 1;
        return 0;
      });

      // Assign Residents
      residents.forEach((resident) => {
        if (resident.attending_at !== null) {
          resident.attending_at = new Date(resident.attending_at);
        }
        self.residentStore.residents.put(resident);
      });

      // Assign Guests
      data.guests.forEach((guest) => {
        guest.created_at = new Date(guest.created_at);
        self.guestStore.guests.put(guest);
      });

      // Assign Bills
      let bills = data.bills;

      // Rename resident_id --> resident (copy to avoid mutating cached data)
      bills = bills.map((bill) => {
        var obj = Object.assign({}, bill);
        obj["resident"] = obj["resident_id"];
        delete obj["resident_id"];
        return obj;
      });

      // Zero displays as blank ("not filled in yet"); any other amount
      // keeps its exact wire value, zero-padded to two decimals by string
      // edits. Never reformat money through a float — a rounded display
      // value must not exist at all, so it can never reach the ledger.
      bills = bills.map((bill) =>
        Object.assign({}, bill, {
          amount: toDisplayAmountString(bill["amount"]),
        }),
      );

      // Determine # of blank bills needed
      const extra = Math.max(3 - bills.length, 0);

      // Create array for iterating
      const array = Array(extra).fill();

      // Create blanks bills
      array.forEach(() => bills.push({}));

      // Assign ids to bills (types.identifier requires strings)
      bills = bills.map((obj) => {
        var bill = Object.assign({ id: v4() }, obj);
        bill.id = String(bill.id);
        return bill;
      });

      // Put bills into BillStore, skipping any with dangling resident references
      bills.forEach((bill) => {
        if (
          bill.resident != null &&
          !self.residentStore.residents.has(String(bill.resident))
        ) {
          console.warn(
            "Skipping bill with unknown resident reference:",
            bill.resident,
          );
          return;
        }
        self.billStore.bills.put(bill);
      });

      // Change loading state. A landed load also ends any retry state:
      // the failure is over and the backoff starts fresh next time.
      self.mealLoading = false;
      self.cancelMealRetry();

      // Unsubscribe from previous meal
      if (window.Comeals.mealChannel !== null) {
        window.Comeals.pusher.unsubscribe(window.Comeals.mealChannel.name);
      }

      // Subscribe to changes of this meal
      window.Comeals.mealChannel = window.Comeals.pusher.subscribe(
        `meal-${self.meal.id}`,
      );
      window.Comeals.mealChannel.bind("update", function () {
        self.loadDataAsync();
      });
    },
    loadMonth(data) {
      if (typeof data === "string") {
        self.monthLoading = false;
        console.error("Error loading month data.", data);
        return true;
      }

      logEvent("loadMonth", { currentDate: self.currentDate });
      mark("loadMonth-start");

      // Build the full events array as plain JS, then replace the
      // observable in one shot for a single MobX notification.
      var allEvents = [];

      // Convert event start/end strings to native Date objects.
      // react-big-calendar requires native Dates for its date arithmetic.
      // toCommunityDayjs handles both offset and naive strings correctly.
      function convertEvents(events) {
        events.forEach(function (event) {
          var converted = Object.assign({}, event);
          if (converted.start) {
            var s = toCommunityDayjs(converted.start);
            converted.start = new Date(
              s.year(),
              s.month(),
              s.date(),
              s.hour(),
              s.minute(),
            );
          }
          if (converted.end) {
            var e = toCommunityDayjs(converted.end);
            converted.end = new Date(
              e.year(),
              e.month(),
              e.date(),
              e.hour(),
              e.minute(),
            );
          }
          allEvents.push(converted);
        });
      }

      var expectedKeys = [
        "meals",
        "bills",
        "rotations",
        "birthdays",
        "common_house_reservations",
        "guest_room_reservations",
        "events",
      ];
      var missing = expectedKeys.filter(function (k) {
        return !Array.isArray(data[k]);
      });
      if (missing.length > 0) {
        console.warn(
          "loadMonth: missing event arrays from API:",
          missing.join(", "),
        );
      }

      convertEvents(data.meals || []);
      convertEvents(data.bills || []);
      convertEvents(data.rotations || []);
      convertEvents(data.birthdays || []);
      convertEvents(data.common_house_reservations || []);
      convertEvents(data.guest_room_reservations || []);
      convertEvents(data.events || []);

      mark("events-converted");

      self.calendarEvents.replace(allEvents);
      self.calendarEventsVersion += 1;

      mark("events-replaced", { count: allEvents.length });

      self.monthLoading = false;

      // Unsubscribe from previous month
      if (window.Comeals.calendarChannel !== null) {
        window.Comeals.pusher.unsubscribe(window.Comeals.calendarChannel.name);
      }

      // Subscribe to changes of this month
      var subscribeString = `community-${Cookie.get(
        "community_id",
      )}-calendar-${dayjs(self.currentDate).format("YYYY")}-${dayjs(
        self.currentDate,
      ).format("M")}`;
      window.Comeals.calendarChannel =
        window.Comeals.pusher.subscribe(subscribeString);

      window.Comeals.calendarChannel.bind("update", function () {
        logEvent("pusher-calendar-update", { date: self.currentDate });
        self.loadMonthAsync();
      });

      // Clean up previous adjacent month subscriptions
      adjacentChannels.forEach(function (ch) {
        window.Comeals.pusher.unsubscribe(ch.name);
      });
      adjacentChannels = [];

      // Subscribe to adjacent months for real-time cache invalidation.
      // When data changes in a neighboring month, evict it from both
      // caches so the next navigation fetches fresh data from the API.
      var communityId = Cookie.get("community_id");
      var current = dayjs(self.currentDate);
      [current.subtract(1, "month"), current.add(1, "month")].forEach(
        function (adj) {
          var adjYear = adj.format("YYYY");
          var adjMonth = adj.format("M");
          var channelName =
            "community-" +
            communityId +
            "-calendar-" +
            adjYear +
            "-" +
            adjMonth;

          // Don't duplicate the current month's subscription
          if (channelName === subscribeString) return;

          var channel = window.Comeals.pusher.subscribe(channelName);
          channel.bind("update", function () {
            invalidateMonth(communityId, adjYear, adjMonth);
          });
          adjacentChannels.push(channel);
        },
      );

      // Prefetch adjacent months for instant navigation
      prefetchMonthData(current.subtract(1, "month").format("YYYY-MM-DD"));
      prefetchMonthData(current.add(1, "month").format("YYYY-MM-DD"));
    },
    clearResidents() {
      self.residentStore.residents.clear();
    },
    clearBills() {
      self.billStore.bills.clear();
    },
    clearGuests() {
      self.guestStore.guests.clear();
    },
    clearCalendarEvents() {
      self.calendarEvents.clear();
      self.calendarEventsVersion += 1;
    },
    appendGuest(obj) {
      self.guestStore.guests.put(obj);
    },
    addMeal(obj) {
      self.meals.push(obj);
    },
    switchMeals(id) {
      // A bill edit still sitting in the debounce window belongs to the
      // meal we are leaving. Send it now, while the meal id and the bill
      // rows it was typed on are still current.
      self.flushPendingBillsSave();

      if (typeof self.meals.find((item) => item.id === id) === "undefined") {
        self.addMeal({ id: Number.parseInt(id, 10) });
      }

      self.meal = id;

      // Prune the nodes left by earlier meals (issue #38): nothing
      // renders them, and they hold stale snapshots. Point self.meal at
      // the new node FIRST — a reference to a destroyed node throws.
      // A node with unsaved menu text stays alive: issue #35 keeps the
      // text on the node until a save lands, and the retry loop reads
      // these nodes.
      self.meals
        .filter((m) => m.id !== self.meal.id && !m.descriptionDirty)
        .forEach((m) => self.meals.remove(m));

      // The rows belong to the meal we are leaving, so they leave with
      // it (same rule as teardownMealPage). They used to stay on screen
      // until the new meal's data arrived, still editable — and a bill
      // edit made in that window was sent to the NEW meal id with the
      // OLD meal's cook list as the payload. The server deletes cooks
      // left out of that list, so one keystroke during a slow load
      // could rewrite the new meal's bills. The flush above already
      // captured any pending edit, so clearing here cannot lose one.
      self.clearBills();
      self.clearResidents();
      self.clearGuests();

      // A retry belongs to the meal it was scheduled for; the new
      // meal starts with a clean slate and a fresh backoff.
      self.cancelMealRetry();

      localforage
        .getItem(id.toString())
        .then(function (value) {
          // Skip if user already navigated to a different meal
          if (!self.meal || self.meal.id !== id) return;

          if (value === null) {
            self.loadDataAsync();
          } else {
            self.loadData(value);
            self.loadDataAsync();
          }
        })
        .catch(function (error) {
          console.error(
            "Failed to load cached meal data, fetching from server:",
            error,
          );
          localforage.removeItem(id.toString()).catch(function () {});
          self.loadDataAsync();
        });
    },
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
    invalidateMonthForDate(date) {
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
      invalidateMonth(
        Cookie.get("community_id"),
        d.format("YYYY"),
        d.format("M"),
      );
    },
    switchMonths(date) {
      monthFetchVersion += 1;
      var versionAtStart = monthFetchVersion;
      self.currentDate = date;

      var myDate = dayjs(date);
      var key = monthCache.keyFor(
        Cookie.get("community_id"),
        myDate.format("YYYY"),
        myDate.format("M"),
      );

      // Synchronous in-memory cache: instant render, no blank flash
      var cached = monthCache.get(key);
      if (cached !== undefined) {
        self.loadMonth(cached);
        self.loadMonthAsync();
        return;
      }

      // Async IndexedDB fallback
      localforage.getItem(key).then(function (value) {
        if (value === null || typeof value === "undefined") {
          // User already navigated elsewhere: nothing to fetch here.
          if (versionAtStart !== monthFetchVersion) return;
          self.loadMonthAsync();
        } else {
          // Warming the in-memory cache is safe even when superseded —
          // the data sits under its own key.
          monthCache.set(key, value);
          // User already navigated elsewhere: skip the render and the
          // revalidation fetch. Same guard as switchMeals above.
          if (versionAtStart !== monthFetchVersion) return;
          self.loadMonth(value);
          self.loadMonthAsync();
        }
      });
    },
    goToMeal(mealId) {
      self.mealLoading = true;
      self.switchMeals(Number.parseInt(mealId, 10));
    },
    goToMonth(date) {
      self.monthLoading = true;
      self.switchMonths(date);
    },
    // The calendar page calls this on mount (issue #38). Without it the
    // last meal's channel stayed live forever: every edit to that meal
    // triggered a full background store rebuild from the calendar.
    teardownMealPage() {
      // A bill edit still in the debounce window belongs to the meal we
      // are leaving. Send it while the meal and its bill rows are still
      // current — the same flush switchMeals does.
      self.flushPendingBillsSave();

      if (window.Comeals.mealChannel !== null) {
        window.Comeals.pusher.unsubscribe(window.Comeals.mealChannel.name);
        window.Comeals.mealChannel = null;
      }

      // Null the reference FIRST, then destroy the nodes — a reference
      // to a destroyed node throws. With meal null, a late meal response
      // fails the same-meal guards and is dropped. Nodes with unsaved
      // menu text stay alive, same as the pruning in switchMeals.
      self.meal = null;
      self.meals
        .filter((m) => !m.descriptionDirty)
        .forEach((m) => self.meals.remove(m));

      // The rows belong to the meal, so they leave with it. Rows left
      // behind crashed the meal page on its next mount: the first render
      // showed them before goToMeal ran, and a row read
      // store.meal.reconciled on the null meal (production, 2026-07-22).
      // The flush above already captured its payload, so clearing here
      // cannot lose an edit.
      self.clearBills();
      self.clearResidents();
      self.clearGuests();

      // No meal page, no retry: the timer must not fire on the
      // calendar.
      self.cancelMealRetry();
    },
    // The meal page calls this on mount (issue #38): the calendar's
    // channels must not keep firing month refetches from the meal page.
    teardownCalendarPage() {
      if (window.Comeals.calendarChannel !== null) {
        window.Comeals.pusher.unsubscribe(window.Comeals.calendarChannel.name);
        window.Comeals.calendarChannel = null;
      }
      adjacentChannels.forEach(function (ch) {
        window.Comeals.pusher.unsubscribe(ch.name);
      });
      adjacentChannels = [];
    },
    setIsOnline(val) {
      self.isOnline = !!val;
    },
    // Roll the observable "today" forward. Called by the midnight timer,
    // the `online` handler (index.jsx), and the Pusher reconnect handler.
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
  }));
