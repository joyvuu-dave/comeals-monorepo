// The one root store. This file holds the model shape (props) and the
// meal-page counting views; the actions live in one file per
// subsystem, composed below:
//
//   data_store_app.js       — Pusher boot, 401 interceptor, "today",
//                             reconnect recovery, logout
//   data_store_meal_page.js — loading a meal's rows, retry backoff,
//                             menu description, open/close, teardown
//   data_store_bills.js     — the bill save pipeline (issue #30)
//   data_store_calendar.js  — rendering a month, its Pusher channels
//   data_store_hosts.js     — the hosts list the reservation modals show
//
// The month cache/fetch machinery is not a subsystem of the store at
// all — it lives in ./month_fetch, because the boot-time prefetch runs
// before any store exists.
import { types } from "mobx-state-tree";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";

import Meal from "./meal";
import Resident from "./resident";
import Bill from "./bill";
import Guest from "./guest";
import { communityNow } from "../helpers/helpers";
import { isZeroAmountString } from "../helpers/money";

import { appVolatile, appActions } from "./data_store_app";
import { mealPageVolatile, mealPageActions } from "./data_store_meal_page";
import { billsVolatile, billsActions } from "./data_store_bills";
import { calendarVolatile, calendarActions } from "./data_store_calendar";
import { hostsVolatile, hostsActions } from "./data_store_hosts";

dayjs.extend(utc);
dayjs.extend(timezone);

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
    // The current meal's rows. They live directly on the store; child
    // nodes reach back up with getRoot (their `root` view).
    residents: types.map(Resident),
    bills: types.map(Bill),
    guests: types.map(Guest),
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
    // it over; handleReconnect recomputes it too, because background
    // tabs throttle timers. Click-time reads keep calling communityNow()
    // directly — a click always computes a fresh value, so those were
    // never stale.
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
  .volatile(appVolatile)
  .volatile(mealPageVolatile)
  .volatile(billsVolatile)
  .volatile(calendarVolatile)
  .volatile(hostsVolatile)
  .views((self) => ({
    get hostsLoaded() {
      return self.hostsLoadedAt !== null;
    },
    get description() {
      if (!self.meal) return "";
      return self.meal.description;
    },
    get guestsCount() {
      return self.guests.size;
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
  .actions(appActions)
  .actions(mealPageActions)
  .actions(billsActions)
  .actions(calendarActions)
  .actions(hostsActions);
