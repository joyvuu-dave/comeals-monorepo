import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import Cookie from "js-cookie";

dayjs.extend(utc);
dayjs.extend(timezone);

// The community's IANA timezone (e.g. "America/Los_Angeles", "Europe/Berlin")
// is written to a cookie at login from community.timezone on the backend. Read
// it lazily on every call so that a login within the same SPA session picks
// up the new tz without a reload. If the cookie is missing (pre-login pages,
// cookies disabled), fall back to the browser's tz — never a hardcoded region.
export function getCommunityTimezone() {
  var tz = Cookie.get("timezone");
  if (tz) return tz;
  return dayjs.tz.guess();
}

var DAY_MS = 24 * 60 * 60 * 1000;

// Zone math here uses Intl, which knows each zone's rules, and plain
// UTC arithmetic. It never goes through the device's own zone. dayjs's
// timezone plugin does: it builds and reads times as Dates in the
// device's zone, so on a device in another zone it can be an hour off
// near a DST change, on either zone's change (#122, #123).

// One Intl.DateTimeFormat per zone: building one is slow, and the
// calendar reads every chip's times through here.
var wallClockFormats = new Map();

function wallClockFormat(tz) {
  var format = wallClockFormats.get(tz);
  if (format === undefined) {
    format = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
      fractionalSecondDigits: 3,
    });
    wallClockFormats.set(tz, format);
  }
  return format;
}

// How far the wall clock in tz is ahead of UTC at the instant ms, in
// milliseconds (negative west of UTC).
export function zoneOffsetMs(ms, tz) {
  var parts = {};
  wallClockFormat(tz)
    .formatToParts(new Date(ms))
    .forEach(function (part) {
      parts[part.type] = Number(part.value);
    });
  var wall = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
    parts.second,
    parts.fractionalSecond,
  );
  return wall - ms;
}

// The instant at which the wall clock in tz shows the time `wall`, where
// `wall` is that time's fields counted as if they were UTC
// (dayjs.utc("2026-03-08T19:00").valueOf()). Two kinds of time have no
// single instant. A time that happens twice, in the hour repeated when
// the clocks go back, gives the first one. A time that never happens,
// in the hour skipped when the clocks go forward, moves forward by the
// skip: 02:30 becomes 03:30. Rails' Time.zone.local on the server does
// the same with both.
export function wallClockToInstant(wall, tz) {
  // The zone's offset a day before and a day after: the offsets on the
  // two sides of any change near this time.
  var before = zoneOffsetMs(wall - DAY_MS, tz);
  var after = zoneOffsetMs(wall + DAY_MS, tz);
  var first = wall - before;
  if (zoneOffsetMs(first, tz) === before) return first;
  var second = wall - after;
  if (zoneOffsetMs(second, tz) === after) return second;
  return first;
}

// A dayjs in UTC mode whose fields are the wall clock in tz at the
// instant ms. UTC has no DST, so its fields, and what it formats, are
// the same on every device. Its own instant is not ms: use it to show a
// time, never to compare one with the clock.
function wallClockAt(ms, tz) {
  return dayjs.utc(ms + zoneOffsetMs(ms, tz));
}

// Milliseconds from the instant `now` until the next midnight in tz:
// the first instant whose date there is after the date at `now`. That
// instant is after `now`, so the answer is always more than zero. On
// a day the clocks change the day is 23 or 25 hours long, and in a zone
// whose clocks skip midnight the next day starts at 01:00.
export function msUntilNextMidnight(now, tz) {
  var tomorrow = wallClockAt(now, tz).startOf("day").add(1, "day");
  return wallClockToInstant(tomorrow.valueOf(), tz) - now;
}

// A time from the server, as the community's wall clock (a dayjs from
// wallClockAt). A string with an offset or a Z names an instant. A
// string without one ("2026-03-08", "2026-03-08T19:00:00") is already a
// wall-clock time in the community's zone. A string dayjs cannot read
// gives back an invalid dayjs.
export function toCommunityDayjs(dateString) {
  var tz = getCommunityTimezone();
  if (/Z|[+-]\d{2}:?\d{2}\s*$/.test(dateString)) {
    var at = dayjs(dateString);
    return at.isValid() ? wallClockAt(at.valueOf(), tz) : at;
  }
  var wall = dayjs.utc(dateString);
  return wall.isValid()
    ? wallClockAt(wallClockToInstant(wall.valueOf(), tz), tz)
    : wall;
}

// "Now" in the community's timezone. Prefer this over dayjs() whenever the
// value is user-visible — a resident travelling out of tz must see the same
// meal-day rollover as anyone at home.
export function communityNow() {
  return dayjs().tz(getCommunityTimezone());
}

// The value space is a compile-time constant (~56 15-minute slots, 8am–10pm),
// so we build the array once and freeze it. Callers map over it to render
// <option> elements on every modal render; returning the same frozen
// reference lets React skip reconciliation work for the options list and
// makes accidental mutation a hard error instead of a silent one.
// See tests/e2e/perf-modals.spec.js for the benchmark harness.
let CACHED_TIMES = null;
export function generateTimes() {
  if (CACHED_TIMES) return CACHED_TIMES;
  var times = [];
  var ending = "AM";

  for (var half = 0; half < 2; half++) {
    for (var hour = 0; hour < 12; hour++) {
      for (var min = 0; min < 4; min++) {
        // Start at 8am
        if (half === 0 && hour < 8) {
          continue;
        }

        // End at 10pm
        if (half === 1 && hour === 10 && min === 1) {
          CACHED_TIMES = Object.freeze(times);
          return CACHED_TIMES;
        }

        var valueHour = hour;

        if (half === 1) {
          ending = "PM";
          valueHour += 12;
        }

        var minutes = `${(min * 15).toString().padStart(2, "0")}`;
        var display =
          hour === 0
            ? `12:${minutes} ${ending}`
            : `${hour}:${minutes} ${ending}`;
        var value = `${valueHour.toString().padStart(2, "0")}:${minutes}`;

        times.push(Object.freeze({ display, value }));
      }
    }
  }
}

// How long a save waits after the last edit before firing, for every
// debounced autosave field (bill amounts, meal description). Blur flushes
// a pending bill save immediately, so this only spans pauses while the
// field still has focus. One constant so the fields cannot drift apart.
export const SAVE_DEBOUNCE_MS = 500;
