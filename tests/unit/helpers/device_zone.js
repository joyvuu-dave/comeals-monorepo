// Run the tests of the enclosing describe block on a device whose own
// time zone is `zone`. Node reads process.env.TZ again each time it is
// set, so Date and Intl follow it at once; afterEach puts the machine's
// zone back. beforeEach also checks that the device really is in that
// zone, by comparing the device's offset with the zone's own offset on
// a winter and a summer day. So a test in the block cannot pass only
// because of the zone of the machine that runs it.
import { beforeEach, afterEach, expect } from "vitest";

const minuteFormats = new Map();

// How far the clock in `zone` is ahead of UTC at the instant `ms`, in
// minutes, straight from Intl. `ms` must be on a whole minute: the
// format leaves out seconds.
export function zoneOffsetMinutes(ms, zone) {
  if (!minuteFormats.has(zone)) {
    minuteFormats.set(
      zone,
      new Intl.DateTimeFormat("en-US", {
        timeZone: zone,
        hourCycle: "h23",
        year: "numeric",
        month: "numeric",
        day: "numeric",
        hour: "numeric",
        minute: "numeric",
      }),
    );
  }
  const parts = {};
  minuteFormats
    .get(zone)
    .formatToParts(new Date(ms))
    .forEach((part) => {
      parts[part.type] = Number(part.value);
    });
  const wall = Date.UTC(
    parts.year,
    parts.month - 1,
    parts.day,
    parts.hour,
    parts.minute,
  );
  return (wall - ms) / 60000;
}

export function useDeviceZone(zone) {
  let machineZone;

  beforeEach(() => {
    machineZone = process.env.TZ;
    process.env.TZ = zone;
    for (const day of [Date.UTC(2026, 0, 15, 12), Date.UTC(2026, 6, 15, 12)]) {
      // getTimezoneOffset counts minutes behind UTC, so the sum is 0.
      // (A sum, not a negation: -0 and 0 are different to toBe.)
      expect(
        new Date(day).getTimezoneOffset() + zoneOffsetMinutes(day, zone),
        `device zone ${zone}`,
      ).toBe(0);
    }
  });

  afterEach(() => {
    if (machineZone === undefined) {
      delete process.env.TZ;
    } else {
      process.env.TZ = machineZone;
    }
  });
}
