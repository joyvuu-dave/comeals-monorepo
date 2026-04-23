import { types } from "mobx-state-tree";
import { v4 } from "uuid";
import axios from "axios";
import Cookie from "js-cookie";

import Meal from "./meal";
import ResidentStore from "./resident_store";
import BillStore from "./bill_store";
import GuestStore from "./guest_store";
import EventSource from "./event_source";

import Pusher from "pusher-js";
import localforage from "localforage";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import handleAxiosError from "../helpers/handle_axios_error";
import { TIMEZONE, toPacificDayjs } from "../helpers/helpers";
import { mark, logEvent } from "../helpers/nav_trace";
import toastStore from "./toast_store";

dayjs.extend(utc);
dayjs.extend(timezone);

// In-memory cache for calendar month data, keyed identically to localforage.
// Provides synchronous access for instant month navigation.
const monthCache = new Map();

// Monotonic version per cache key. Incremented on Pusher invalidation.
// Prefetch callbacks compare against the version captured at call-start;
// if it changed, a real-time update arrived mid-flight and the stale
// response is silently discarded.
const invalidationVersion = new Map();

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
// Same pattern as `invalidationVersion` above for the month cache.
var hostsVersion = 0;

// Single Pusher subscription for hosts updates. Assigned the first
// time ensureHosts() succeeds; never resubscribed for the lifetime
// of the store because the channel name only depends on community_id.
var hostsChannel = null;

function monthCacheKey(communityId, year, month) {
  return `community-${communityId}-calendar-${year}-${month}`;
}

function invalidateMonth(communityId, year, month) {
  var key = monthCacheKey(communityId, year, month);
  monthCache.delete(key);
  localforage.removeItem(key);
  invalidationVersion.set(key, (invalidationVersion.get(key) || 0) + 1);
}

function prefetchMonthData(date) {
  var myDate = dayjs(date);
  var key = monthCacheKey(
    Cookie.get("community_id"),
    myDate.format("YYYY"),
    myDate.format("M"),
  );

  if (monthCache.has(key)) return;

  logEvent("prefetch-start", { date });
  var versionAtStart = invalidationVersion.get(key) || 0;

  localforage.getItem(key).then(function (value) {
    // Discard if a Pusher invalidation arrived since we started
    if ((invalidationVersion.get(key) || 0) !== versionAtStart) return;

    if (value !== null && typeof value !== "undefined") {
      monthCache.set(key, value);
      return;
    }

    axios
      .get(
        `/api/v1/communities/${Cookie.get("community_id")}/calendar/${date}`,
      )
      .then(function (response) {
        if (response.status === 200) {
          // Discard if a Pusher invalidation arrived since we started
          if ((invalidationVersion.get(key) || 0) !== versionAtStart) return;
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
    isLoading: true,
    editDescriptionMode: true,
    editBillsMode: true,
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
    eventSources: types.optional(types.array(EventSource), []),
    calendarEvents: types.optional(types.array(types.frozen()), []),
    // Monotonic counter bumped whenever calendarEvents changes (replace or
    // clear). The Calendar component is wrapped in React.memo and diffs a
    // cached snapshot of events keyed off this version — this gives us a
    // cheap way to skip the ~3.5ms/event render cost when a parent re-render
    // (e.g. modal open/close) didn't actually change the event set.
    calendarEventsVersion: types.optional(types.number, 0),
    currentDate: types.optional(types.string, function () {
      return dayjs().tz(TIMEZONE).format("YYYY-MM-DD");
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

      window.Comeals.pusher.connection.bind("state_change", function (states) {
        // states = {previous: 'oldState', current: 'newState'}
        if (
          states.previous === "unavailable" &&
          states.current === "connected"
        ) {
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
        }
      });

      self.setIsOnline(navigator.onLine);

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

      if (isSaving) {
        self.submitDescription();
      }
    },
    toggleEditBillsMode() {
      const isSaving = self.editBillsMode;
      self.editBillsMode = !self.editBillsMode;

      if (isSaving) {
        self.submitBills();
      }
    },
    saveDescription() {
      self.submitDescription();
    },
    saveBills() {
      self.submitBills();
    },
    setDescription(val) {
      self.meal.description = val;
      self.saveDescription();
      return self.meal.description;
    },
    toggleClosed() {
      if (!self.meal.closed) {
        // There is a cook who hasn't filled in their cost
        const cookNeedsToFillInCost = Array.from(self.bills.values()).some(
          (bill) =>
            bill.resident_id !== "" &&
            bill.amount === "" &&
            bill.no_cost === false,
        );

        if (cookNeedsToFillInCost) {
          toastStore.addToast(
            "All cook costs must be set before closing.",
            "warning",
          );
          return;
        }
      }

      const val = !self.meal.closed;
      self.meal.closed = val;

      axios({
        method: "patch",
        url: `/api/v1/meals/${self.meal.id}/closed`,
        withCredentials: true,
        data: {
          closed: val,
          socket_id: window.Comeals.socketId,
        },
      })
        .then(function (response) {
          if (response.status === 200) {
            // If meal has been opened, re-set extras value
            if (val === false) {
              self.meal.resetExtras();
              self.meal.resetClosedAt();
            } else {
              self.meal.setClosedAt();
            }
          }
        })
        .catch(function (error) {
          self.meal.toggleClosed();
          handleAxiosError(error);
        });
    },
    logout() {
      // Best-effort server-side revocation. Fire-and-forget: even if the
      // request fails (offline, expired token) we still clear local state —
      // the user tapped "log out" and should see themselves logged out.
      axios
        .delete("/api/v1/sessions/current")
        .catch(() => {});

      Cookie.remove("token", { path: "/" });
      Cookie.remove("community_id", { path: "/" });
      Cookie.remove("resident_id", { path: "/" });
      Cookie.remove("username", { path: "/" });
      Cookie.remove("timezone", { path: "/" });
    },
    submitDescription() {
      let obj = {
        id: self.meal.id,
        description: self.meal.description,
        socket_id: window.Comeals.socketId,
      };

      axios({
        method: "patch",
        url: `/api/v1/meals/${self.meal.id}/description`,
        data: obj,
        withCredentials: true,
      }).catch(function (error) {
        handleAxiosError(error);
      });
    },
    submitBills() {
      // Check for errors with bills
      if (
        Array.from(self.bills.values()).some(
          (bill) => bill.amountIsValid === false,
        )
      ) {
        self.editBillsMode = true;
        return;
      }

      // Format Bills
      let bills = Array.from(self.bills.values())
        .map((bill) => bill.toJSON())
        .map((bill) => {
          let obj = Object.assign({}, bill);

          // delete id
          delete obj["id"];

          // resident --> resident_id
          obj["resident_id"] = obj["resident"];
          delete obj["resident"];

          return obj;
        })
        .filter((bill) => bill.resident_id !== null);

      let obj = {
        id: self.meal.id,
        bills: bills,
        socket_id: window.Comeals.socketId,
      };

      axios({
        method: "patch",
        url: `/api/v1/meals/${self.meal.id}/bills`,
        data: obj,
        withCredentials: true,
      }).catch(function (error) {
        var isWarning =
          error.response &&
          error.response.data &&
          error.response.data.type === "warning";
        if (isWarning) {
          var msg = error.response.data.message || "";
          toastStore.replaceAll(
            "Cooks saved." + (msg ? " " + msg : ""),
            "info",
          );
        } else {
          handleAxiosError(error);
        }

        self.loadDataAsync();
      });
    },
    loadDataAsync() {
      axios
        .get(`/api/v1/meals/${self.meal.id}/cooks`)
        .then(function (response) {
          if (response.status === 200) {
            localforage
              .setItem(response.data.id.toString(), response.data)
              .then(function () {
                // Skip stale responses from a previous meal
                if (self.meal && self.meal.id === response.data.id) {
                  self.loadData(response.data);
                }
              });
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
        });
    },
    loadMonthAsync() {
      logEvent("loadMonthAsync-start", { date: self.currentDate });
      axios
        .get(
          `/api/v1/communities/${Cookie.get("community_id")}/calendar/${
            self.currentDate
          }`,
        )
        .then(function (response) {
          if (response.status === 200) {
            var respData = response.data;
            var key = monthCacheKey(respData.id, respData.year, respData.month);
            monthCache.set(key, respData);
            localforage.setItem(key, respData).then(function () {
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
        .get(
          `/api/v1/communities/${communityId}/hosts`,
        )
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
    loadNext() {
      axios
        .get(
          `/api/v1/meals/${self.meal.nextId}/cooks`,
        )
        .then(function (response) {
          if (response.status === 200) {
            localforage.setItem(response.data.id.toString(), response.data);
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
        });
    },
    loadPrev() {
      axios
        .get(
          `/api/v1/meals/${self.meal.prevId}/cooks`,
        )
        .then(function (response) {
          if (response.status === 200) {
            localforage.setItem(response.data.id.toString(), response.data);
          }
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
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

      // Assign Meal Data — construct a "fake local" Date with Pacific
      // date components so that dayjs(meal.date) always reflects Pacific,
      // consistent with getPacificNow() in calendar/show.jsx.
      var d = toPacificDayjs(data.date);
      self.meal.date = new Date(d.year(), d.month(), d.date());
      self.meal.description = data.description;
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

      // Format amount for display
      bills = bills.map((bill) => {
        const amt = Number(bill["amount"]);
        return Object.assign({}, bill, {
          amount: amt === 0 ? "" : amt.toFixed(2),
        });
      });

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

      // Change loading state
      self.isLoading = false;

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
        self.isLoading = false;
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
      // toPacificDayjs handles both offset and naive strings correctly.
      function convertEvents(events) {
        events.forEach(function (event) {
          var converted = Object.assign({}, event);
          if (converted.start) {
            var s = toPacificDayjs(converted.start);
            converted.start = new Date(
              s.year(),
              s.month(),
              s.date(),
              s.hour(),
              s.minute(),
            );
          }
          if (converted.end) {
            var e = toPacificDayjs(converted.end);
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

      self.isLoading = false;

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
      if (typeof self.meals.find((item) => item.id === id) === "undefined") {
        self.addMeal({ id: Number.parseInt(id, 10) });
      }

      self.meal = id;

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
    switchMonths(date) {
      self.currentDate = date;

      var myDate = dayjs(date);
      var key = monthCacheKey(
        Cookie.get("community_id"),
        myDate.format("YYYY"),
        myDate.format("M"),
      );

      // Synchronous in-memory cache: instant render, no blank flash
      if (monthCache.has(key)) {
        self.loadMonth(monthCache.get(key));
        self.loadMonthAsync();
        return;
      }

      // Async IndexedDB fallback
      localforage.getItem(key).then(function (value) {
        if (value === null || typeof value === "undefined") {
          self.loadMonthAsync();
        } else {
          monthCache.set(key, value);
          self.loadMonth(value);
          self.loadMonthAsync();
        }
      });
    },
    goToMeal(mealId) {
      self.isLoading = true;
      self.switchMeals(Number.parseInt(mealId, 10));
    },
    goToMonth(date) {
      self.isLoading = true;
      self.switchMonths(date);
    },
    setIsOnline(val) {
      self.isOnline = !!val;
    },
    setAuthExpired(value) {
      self.authExpired = value;
    },
  }));
