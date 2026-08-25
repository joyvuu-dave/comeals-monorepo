// The calendar page: rendering a month's events and managing its
// Pusher subscriptions. The cache/fetch machinery lives in
// ./month_fetch; this file is the render side. One of the DataStore's
// subsystem files — see data_store.js, which composes them.
import Cookie from "js-cookie";
import dayjs from "dayjs";

import * as monthData from "./month_fetch";
import { toCommunityDayjs } from "../helpers/helpers";
import { mark } from "../helpers/nav_trace";

export function calendarVolatile() {
  return {
    // Pusher subscriptions for adjacent months (cache invalidation only).
    adjacentChannels: [],
  };
}

export function calendarActions(self) {
  return {
    // The month on screen can no longer be trusted (a Pusher update, a
    // reconnect, the day changing): drop its copies and fetch it again.
    // The month module drops superseded and pre-change responses;
    // loadMonth renders.
    loadMonthAsync() {
      monthData.refetch(self.currentDate, self.loadMonth);
    },
    // The modal that changed a date calls this so the affected month
    // is refetched even when it has no Pusher channel (issue #37).
    invalidateMonthForDate(date) {
      monthData.invalidateMonthForDate(date);
    },
    switchMonths(date) {
      self.currentDate = date;
      monthData.loadForNavigation(date, self.loadMonth);
    },
    goToMonth(date) {
      self.monthLoading = true;
      self.switchMonths(date);
    },
    // The zone the SPA computes every time and "today" from comes
    // from a cookie written at login. A month payload carries the
    // community's current zone; when it differs, the admin changed it
    // since login, so take it, recompute today, and move the midnight
    // timer. Otherwise a tab kept the old zone until logout and login.
    adoptCommunityTimezone(timezone) {
      if (!timezone || timezone === Cookie.get("timezone")) return;
      Cookie.set("timezone", timezone, { expires: 7300 });
      self.recomputeCommunityToday();
      self.scheduleMidnightRecompute();
    },
    loadMonth(data) {
      if (typeof data === "string") {
        self.monthLoading = false;
        console.error("Error loading month data.", data);
        return true;
      }

      mark("loadMonth-start");

      self.adoptCommunityTimezone(data.timezone);

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
        self.loadMonthAsync();
      });

      // Names on chips and birthdays come from residents and units,
      // which have their own channel.
      self.ensureResidentsChannel();

      // Clean up previous adjacent month subscriptions
      self.adjacentChannels.forEach(function (ch) {
        window.Comeals.pusher.unsubscribe(ch.name);
      });
      self.adjacentChannels = [];

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
            monthData.invalidateMonth(communityId, adjYear, adjMonth);
          });
          self.adjacentChannels.push(channel);
        },
      );

      // Prefetch adjacent months for instant navigation
      monthData.prefetchMonth(
        current.subtract(1, "month").format("YYYY-MM-DD"),
      );
      monthData.prefetchMonth(current.add(1, "month").format("YYYY-MM-DD"));
    },
    clearCalendarEvents() {
      self.calendarEvents.clear();
      self.calendarEventsVersion += 1;
    },
    // The meal page calls this on mount (issue #38): the calendar's
    // channels must not keep firing month refetches from the meal page.
    teardownCalendarPage() {
      if (window.Comeals.calendarChannel !== null) {
        window.Comeals.pusher.unsubscribe(window.Comeals.calendarChannel.name);
        window.Comeals.calendarChannel = null;
      }
      self.adjacentChannels.forEach(function (ch) {
        window.Comeals.pusher.unsubscribe(ch.name);
      });
      self.adjacentChannels = [];
    },
  };
}
