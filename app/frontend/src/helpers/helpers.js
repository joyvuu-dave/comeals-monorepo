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

// dayjs.tz(string, tz) interprets naive strings (no offset) as the
// target timezone — correct.  But for strings with offset info it
// stamps the UTC value as the target timezone instead of converting.
// For those we need dayjs(string).tz(tz).
export function toCommunityDayjs(dateString) {
  var tz = getCommunityTimezone();
  if (/Z|[+-]\d{2}:?\d{2}\s*$/.test(dateString)) {
    return dayjs(dateString).tz(tz);
  }
  return dayjs.tz(dateString, tz);
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

  CACHED_TIMES = Object.freeze(times);
  return CACHED_TIMES;
}
