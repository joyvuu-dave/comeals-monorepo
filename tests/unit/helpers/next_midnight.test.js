import { describe, it, expect } from "vitest";
import { msUntilNextMidnight } from "../../../app/frontend/src/helpers/helpers.js";
import { useDeviceZone, zoneOffsetMinutes } from "./device_zone.js";

// The midnight timer waits msUntilNextMidnight (plus one second) and
// then sets itself again (#122). So in every zone and at every instant
// the wait must be more than zero, and it must end exactly where the
// zone's date changes: the instant before is still today there, and
// the instant itself is tomorrow. The hard instants are the ones near a
// clock change, including zones whose clocks skip midnight (Havana,
// Cairo, Santiago in September) or go back from midnight to 23:00
// (Beirut, Santiago in April). This checks every zone Intl knows, every
// 20 minutes from 26 hours before to 26 hours after each change in
// 2026, and one ordinary instant a week.

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const START = Date.UTC(2026, 0, 1);
const END = Date.UTC(2027, 0, 1);

const dayFormats = new Map();

// "YYYY-MM-DD" in `zone` at the instant `ms`, straight from Intl (en-CA
// writes dates that way).
function dateIn(ms, zone) {
  if (!dayFormats.has(zone)) {
    dayFormats.set(zone, new Intl.DateTimeFormat("en-CA", { timeZone: zone }));
  }
  return dayFormats.get(zone).format(new Date(ms));
}

function dayAfter(date) {
  return new Date(Date.parse(`${date}T00:00:00Z`) + DAY)
    .toISOString()
    .slice(0, 10);
}

// The minutes at which the zone's offset changes in 2026.
function changesIn2026(zone) {
  const changes = [];
  for (let t = START; t < END; t += 6 * HOUR) {
    if (zoneOffsetMinutes(t, zone) === zoneOffsetMinutes(t + 6 * HOUR, zone)) {
      continue;
    }
    let low = t;
    let high = t + 6 * HOUR;
    while (high - low > MINUTE) {
      const mid = low + Math.floor((high - low) / 2 / MINUTE) * MINUTE;
      if (zoneOffsetMinutes(mid, zone) === zoneOffsetMinutes(low, zone)) {
        low = mid;
      } else {
        high = mid;
      }
    }
    changes.push(high);
  }
  return changes;
}

function instantsToCheck(zone) {
  const instants = [];
  for (let t = START + 13 * HOUR + 37 * MINUTE; t < END; t += 7 * DAY) {
    instants.push(t);
  }
  for (const change of changesIn2026(zone)) {
    for (
      let t = change - 26 * HOUR;
      t <= change + 26 * HOUR;
      t += 20 * MINUTE
    ) {
      instants.push(t);
    }
  }
  return instants;
}

// What is wrong with the wait at `now` in `zone`, or null.
function problemWith(now, zone) {
  const wait = msUntilNextMidnight(now, zone);
  const today = dateIn(now, zone);
  const at = new Date(now).toISOString();
  if (!(wait > 0)) return `${zone} ${at}: wait ${wait}`;
  const before = dateIn(now + wait - 1, zone);
  const after = dateIn(now + wait, zone);
  if (before !== today || after !== dayAfter(today)) {
    return `${zone} ${at}: ${today} ends at ${new Date(now + wait).toISOString()}, which shows ${before} then ${after}`;
  }
  return null;
}

const ZONES = [...Intl.supportedValuesOf("timeZone"), "UTC"];

describe.each(["America/Chicago", "Asia/Tokyo"])(
  "msUntilNextMidnight on a device in %s",
  (deviceZone) => {
    useDeviceZone(deviceZone);

    it("covers the zones with the hard midnights", () => {
      for (const zone of [
        "America/Havana",
        "Asia/Beirut",
        "America/Santiago",
        "Africa/Cairo",
        "Australia/Lord_Howe",
        "America/Los_Angeles",
      ]) {
        expect(ZONES).toContain(zone);
        expect(changesIn2026(zone)).toHaveLength(2);
      }
    });

    it("ends every wait exactly where the date changes, in every zone", () => {
      const problems = [];
      for (const zone of ZONES) {
        for (const now of instantsToCheck(zone)) {
          const problem = problemWith(now, zone);
          if (problem) problems.push(problem);
        }
      }
      expect(problems).toEqual([]);
    }, 60000);
  },
);
