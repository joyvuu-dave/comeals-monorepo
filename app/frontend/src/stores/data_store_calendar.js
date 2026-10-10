// The calendar page: rendering a month's events and managing its
// Pusher subscriptions. The cache/fetch machinery lives in
// ./month_fetch; this file is the render side. One of the DataStore's
// subsystem files — see data_store.js, which composes them.
import Cookie from "js-cookie";
import dayjs from "dayjs";

import * as monthData from "./month_fetch";
import { toCommunityDayjs } from "../helpers/helpers";
import { communityId as sessionCommunityId } from "../helpers/session";
import { mark } from "../helpers/nav_trace";

export function calendarVolatile() {
  return {
    // The Pusher channels of the two months next to the one on screen.
    adjacentChannels: [],
  };
}

function monthChannelName(communityId, month) {
  return `community-${communityId}-calendar-${month.format("YYYY")}-${month.format("M")}`;
}

export function calendarActions(self) {
  // Whether a channel is the one for the month on screen. Read when a
  // handler fires: the month on screen changes as soon as a navigation
  // starts (switchMonths), before its answer arrives.
  function isOnScreen(name) {
    return (
      name ===
      monthChannelName(Cookie.get("community_id"), dayjs(self.currentDate))
    );
  }

  // Open one month's channel. A month can move between roles (the month
  // on screen, a neighbour) while its channel stays open, so the
  // handlers check the role when they fire, not when they are bound.
  function subscribeMonth(communityId, month) {
    var name = monthChannelName(communityId, month);
    var channel = window.Comeals.pusher.subscribe(name);
    // The month changed on the server. The month on screen is fetched
    // again. A neighbour's copies are only dropped, so the next visit
    // fetches it.
    channel.bind("update", function () {
      if (isOnScreen(name)) {
        self.loadMonthAsync();
      } else {
        monthData.invalidateMonth(
          communityId,
          month.format("YYYY"),
          month.format("M"),
        );
      }
    });
    // Pusher confirmed the subscription. A push sent before this reached
    // no one, and the month on screen may have been read before it, so
    // it is fetched once more (#112). A neighbour is not: that would
    // drop the prefetch made a moment ago, and a visit more than 5
    // seconds after a prefetch fetches the month again anyway.
    channel.bind("pusher:subscription_succeeded", function () {
      if (isOnScreen(name)) self.loadMonthAsync();
    });
    return channel;
  }

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
    // from a cookie written at login. A month the server sends carries
    // the community's current zone; when it differs, the admin changed
    // it since login, so take it, recompute today, and move the
    // midnight timer. Otherwise a tab kept the old zone until logout
    // and login. Only a month that just came from the server reaches
    // here (onServerZone in month_fetch.js), never a copy, because a
    // copy can hold the zone from before the change.
    adoptCommunityTimezone(timezone) {
      if (!timezone || timezone === Cookie.get("timezone")) return;
      Cookie.set("timezone", timezone, { expires: 7300 });
      self.recomputeCommunityToday();
      self.scheduleMidnightRecompute();
      // The month on screen was drawn in the old zone, and the answer
      // that brought the new one can be for a month next to it. So its
      // events are drawn again from its copy in memory. A copy holds
      // exact instants, so it shows the right times in the new zone.
      // Only the events: the answer can come after the person went to
      // a meal page, which closed the calendar's channels (#38), and
      // loadMonth would open them again and fetch the months next to
      // this one again.
      var onScreen = monthData.copyInMemory(self.currentDate);
      if (onScreen !== undefined) self.drawEvents(onScreen);
    },
    loadMonth(data) {
      if (typeof data === "string") {
        self.monthLoading = false;
        console.error("Error loading month data.", data);
        return true;
      }

      mark("loadMonth-start");

      self.drawEvents(data);

      self.monthLoading = false;

      self.watchMonthChannels();

      // Names on chips and birthdays come from residents and units,
      // which have their own channel.
      self.ensureResidentsChannel();

      // Prefetch adjacent months for instant navigation
      var current = dayjs(self.currentDate);
      monthData.prefetchMonth(
        current.subtract(1, "month").format("YYYY-MM-DD"),
      );
      monthData.prefetchMonth(current.add(1, "month").format("YYYY-MM-DD"));
    },
    // Turn a month's events into the calendar's events, in the zone the
    // cookie has now.
    drawEvents(data) {
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
    },
    // Keep this page subscribed to the month on screen and its two
    // neighbours. A channel that is open under a name still wanted stays
    // open as it is, whatever its role was. pusherClient hands every
    // caller the same channel for a name, so closing the old neighbours
    // closed the month that had just come on screen (#112). And a
    // channel closed and opened again on every refetch would miss any
    // push sent in between, and fetch again on every confirmation.
    //
    // With no session, no channel is opened: a copy of the month read
    // from the device can be drawn after a logout, just before the page
    // loads "/" again (#153).
    watchMonthChannels() {
      var communityId = sessionCommunityId();
      if (communityId === null) return;
      var current = dayjs(self.currentDate);
      var open = new Map();
      [window.Comeals.calendarChannel]
        .concat(self.adjacentChannels)
        .forEach(function (channel) {
          if (channel !== null) open.set(channel.name, channel);
        });
      var channels = [
        current,
        current.subtract(1, "month"),
        current.add(1, "month"),
      ].map(function (month) {
        var name = monthChannelName(communityId, month);
        var channel = open.get(name);
        open.delete(name);
        return channel || subscribeMonth(communityId, month);
      });
      open.forEach(function (_channel, name) {
        window.Comeals.pusher.unsubscribe(name);
      });
      window.Comeals.calendarChannel = channels[0];
      self.adjacentChannels = channels.slice(1);
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
