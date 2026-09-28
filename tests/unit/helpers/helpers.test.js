import {
  describe,
  it,
  expect,
  beforeEach,
  afterEach,
  afterAll,
  vi,
} from "vitest";
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import Cookie from "js-cookie";
import {
  communityNow,
  generateTimes,
  getCommunityTimezone,
  toCommunityDayjs,
  wallClockToInstant,
  zoneOffsetMs,
} from "../../../app/frontend/src/helpers/helpers.js";
import { useDeviceZone } from "./device_zone.js";

dayjs.extend(advancedFormat);

// The app pins the community's IANA tz in a cookie at login. Tests exercise
// multiple communities across hemispheres, so we set/clear the cookie per
// test instead of relying on the jsdom default.
function setCommunityTimezone(tz) {
  Cookie.set("timezone", tz);
}

function clearCommunityTimezone() {
  Cookie.remove("timezone");
}

beforeEach(() => {
  clearCommunityTimezone();
});

afterAll(() => {
  clearCommunityTimezone();
});

describe("generateTimes", () => {
  // generateTimes produces time picker options for reservation/event forms

  it("starts at 8:00 AM", () => {
    const times = generateTimes();
    expect(times[0]).toEqual({ display: "8:00 AM", value: "08:00" });
  });

  it("ends at 10:00 PM", () => {
    const times = generateTimes();
    const last = times[times.length - 1];
    expect(last).toEqual({ display: "10:00 PM", value: "22:00" });
  });

  it("displays noon correctly as 12:00 PM (not 0:00 PM)", () => {
    // hour=0 in the PM half should display as 12, not 0
    const times = generateTimes();
    const noon = times.find((t) => t.value === "12:00");
    expect(noon).toBeDefined();
    expect(noon.display).toBe("12:00 PM");
  });

  it("uses 24-hour format for values", () => {
    const times = generateTimes();
    const onePM = times.find((t) => t.display === "1:00 PM");
    expect(onePM).toBeDefined();
    expect(onePM.value).toBe("13:00");
  });

  it("generates only 15-minute intervals", () => {
    const times = generateTimes();
    times.forEach((t) => {
      const minutes = t.value.split(":")[1];
      expect(["00", "15", "30", "45"]).toContain(minutes);
    });
  });

  it("generates 57 time slots (8:00 AM to 10:00 PM in 15-min intervals)", () => {
    // 8am-11:45am = 16 slots, 12:00pm-10:00pm = 41 slots
    const times = generateTimes();
    expect(times).toHaveLength(57);
  });

  it("transitions correctly from 11:45 AM to 12:00 PM", () => {
    // Boundary: AM/PM crossover at noon
    const times = generateTimes();
    const lastAM = times.find((t) => t.value === "11:45");
    const firstPM = times.find((t) => t.value === "12:00");
    expect(lastAM.display).toBe("11:45 AM");
    expect(firstPM.display).toBe("12:00 PM");
  });

  it("pads single-digit minutes with leading zero in value", () => {
    // value should be "08:00" not "8:00"
    const times = generateTimes();
    const eight = times.find((t) => t.display === "8:00 AM");
    expect(eight.value).toBe("08:00");
  });
});

describe("getCommunityTimezone", () => {
  // The tz should come from the backend cookie, NOT a hardcoded region.

  it("reads the current cookie value", () => {
    setCommunityTimezone("Europe/Berlin");
    expect(getCommunityTimezone()).toBe("Europe/Berlin");
  });

  it("reads the cookie lazily so mid-session changes take effect", () => {
    setCommunityTimezone("America/Los_Angeles");
    expect(getCommunityTimezone()).toBe("America/Los_Angeles");
    setCommunityTimezone("Australia/Sydney");
    expect(getCommunityTimezone()).toBe("Australia/Sydney");
  });

  it("falls back to the browser tz when no cookie is present (not a hardcoded region)", () => {
    // Pre-login state. Must NOT be hardcoded Pacific — every community has
    // its own tz, and pre-login we have no community context at all.
    const fallback = getCommunityTimezone();
    expect(fallback).toBe(dayjs.tz.guess());
  });
});

describe("toCommunityDayjs", () => {
  // Exercised with a Pacific community; tz-specific expected hours below
  // assume PDT (UTC-7) unless the test sets a different tz.
  beforeEach(() => {
    setCommunityTimezone("America/Los_Angeles");
  });

  it("converts offset string (-07:00) to the community timezone", () => {
    // 4 PM Pacific expressed with offset
    const d = toCommunityDayjs("2026-05-11T16:00:00.000-07:00");
    expect(d.hour()).toBe(16);
    expect(d.date()).toBe(11);
    expect(d.month()).toBe(4); // May, 0-indexed
  });

  it("converts UTC string (Z) to the community timezone", () => {
    // 2026-05-11T23:00:00Z = 4 PM Pacific (PDT is UTC-7)
    const d = toCommunityDayjs("2026-05-11T23:00:00Z");
    expect(d.hour()).toBe(16);
    expect(d.date()).toBe(11);
  });

  it("converts offset string that crosses date boundary", () => {
    // 10 PM Pacific = next day 05:00 UTC
    const d = toCommunityDayjs("2026-05-12T05:00:00.000Z");
    expect(d.hour()).toBe(22);
    expect(d.date()).toBe(11);
  });

  it("interprets naive string as the community timezone (no conversion)", () => {
    const d = toCommunityDayjs("2026-05-11T16:00:00");
    expect(d.hour()).toBe(16);
    expect(d.date()).toBe(11);
  });

  it("handles +00:00 offset", () => {
    // Midnight UTC = 5 PM previous day Pacific (PDT)
    const d = toCommunityDayjs("2026-05-12T00:00:00+00:00");
    expect(d.hour()).toBe(17);
    expect(d.date()).toBe(11);
  });

  it("handles compact offset without colon (+0000)", () => {
    const d = toCommunityDayjs("2026-05-12T00:00:00+0000");
    expect(d.hour()).toBe(17);
    expect(d.date()).toBe(11);
  });

  it("honors a non-Pacific community tz", () => {
    // Same UTC instant, different community: this should NOT be stuck in
    // Pacific. A Berlin co-housing sees the same timestamp at 09:00 local.
    setCommunityTimezone("Europe/Berlin");
    const d = toCommunityDayjs("2026-05-11T07:00:00Z");
    expect(d.hour()).toBe(9); // CEST is UTC+2 in May
    expect(d.date()).toBe(11);
  });

  it("honors a Southern Hemisphere community tz", () => {
    // May is southern-hemisphere winter, so Sydney is on AEST (UTC+10), not
    // AEDT. The point of the test is that we resolve to Sydney local time,
    // not a hardcoded Pacific offset.
    setCommunityTimezone("Australia/Sydney");
    const d = toCommunityDayjs("2026-05-11T00:00:00Z");
    expect(d.hour()).toBe(10); // AEST = UTC+10
    expect(d.date()).toBe(11);
  });
});

// What a community time reads as must not depend on the device's own
// zone (#123). Each block runs on one device zone, set by the test
// itself. Los Angeles, the community: clocks go forward on Mar 8, 2026
// at 2am and back on Nov 1, 2026 at 2am.
describe.each([
  // Central and Eastern: dayjs.tz put a time after midnight on a switch
  // day an hour early, and the spring-forward Sunday on the Saturday.
  "America/Chicago",
  "America/New_York",
  // The community's own zone, and the zone CI runs in.
  "America/Los_Angeles",
  "UTC",
  // East of UTC, with and without DST.
  "Asia/Tokyo",
  "Europe/Berlin",
  // On UTC in winter: dayjs.tz read an offset of 0 as "no offset" and
  // put a Saturday dinner in October an hour late.
  "Europe/London",
  // Its clocks skip from 23:00 to midnight on Saturday, Mar 28, 2026, so
  // a device-local Date cannot hold 23:30 that night.
  "America/Nuuk",
  "Pacific/Honolulu",
])("toCommunityDayjs on a device in %s", (deviceZone) => {
  useDeviceZone(deviceZone);

  beforeEach(() => {
    setCommunityTimezone("America/Los_Angeles");
  });

  it.each([
    ["2026-03-07T23:30:00", "2026-03-07 23:30"],
    ["2026-03-08", "2026-03-08 00:00"],
    ["2026-03-08T00:30:00", "2026-03-08 00:30"],
    ["2026-03-08T01:59:00", "2026-03-08 01:59"],
    ["2026-03-08T03:00:00", "2026-03-08 03:00"],
    ["2026-03-08T19:00:00", "2026-03-08 19:00"],
    ["2026-03-28T23:30:00", "2026-03-28 23:30"],
    ["2026-10-24T19:00:00", "2026-10-24 19:00"],
    ["2026-10-31T23:30:00", "2026-10-31 23:30"],
    ["2026-11-01", "2026-11-01 00:00"],
    ["2026-11-01T01:30:00", "2026-11-01 01:30"],
    ["2026-11-01T02:30:00", "2026-11-01 02:30"],
    ["2026-11-01T19:00:00", "2026-11-01 19:00"],
  ])("reads the wall-clock time %s as %s", (input, wallClock) => {
    expect(toCommunityDayjs(input).format("YYYY-MM-DD HH:mm")).toBe(wallClock);
  });

  it.each([
    ["2026-03-08T08:00:00Z", "2026-03-08 00:00"],
    ["2026-03-08T09:59:00Z", "2026-03-08 01:59"],
    ["2026-03-08T10:00:00Z", "2026-03-08 03:00"],
    ["2026-03-29T06:30:00Z", "2026-03-28 23:30"],
    ["2026-10-25T02:00:00Z", "2026-10-24 19:00"],
    // The hour that happens twice: first in daylight time, then in
    // standard time.
    ["2026-11-01T08:30:00Z", "2026-11-01 01:30"],
    ["2026-11-01T09:30:00Z", "2026-11-01 01:30"],
    ["2026-11-01T02:00:00.000-05:00", "2026-11-01 00:00"],
  ])("reads the instant %s as %s", (input, wallClock) => {
    expect(toCommunityDayjs(input).format("YYYY-MM-DD HH:mm")).toBe(wallClock);
  });

  // The server never sends a time that the clocks skip (it saves one an
  // hour later, the way Time.zone.local moves it). This keeps what the
  // app did before on a device in the community's own zone: the time
  // moves forward by the skip.
  it("moves 02:30 on the spring-forward day to 03:30", () => {
    expect(
      toCommunityDayjs("2026-03-08T02:30:00").format("YYYY-MM-DD HH:mm"),
    ).toBe("2026-03-08 03:30");
  });

  it("gives the meal page and the history modal the right day", () => {
    const d = toCommunityDayjs("2026-03-08");
    expect([d.year(), d.month(), d.date(), d.hour(), d.minute()]).toEqual([
      2026, 2, 8, 0, 0,
    ]);
    expect(d.format("ddd, MMM Do")).toBe("Sun, Mar 8th");
  });

  it("gives back an invalid dayjs for a string it cannot read", () => {
    expect(toCommunityDayjs("not a date").isValid()).toBe(false);
    expect(toCommunityDayjs("not a date Z").isValid()).toBe(false);
  });
});

// The two zone functions under the time helpers. Every expected instant
// below was read from the zone's rules (Intl), with the offset written
// out, and each block runs on devices east and west of the zones.
describe.each(["America/Chicago", "UTC", "Asia/Tokyo"])(
  "zone math on a device in %s",
  (deviceZone) => {
    useDeviceZone(deviceZone);

    function instantOf(wallClock, zone) {
      return new Date(
        wallClockToInstant(Date.parse(`${wallClock}Z`), zone),
      ).toISOString();
    }

    it.each([
      // An ordinary time.
      ["America/Los_Angeles", "2026-01-15T12:00", "2026-01-15T20:00:00.000Z"],
      // Los Angeles, clocks forward at 02:00 on Mar 8: the hour before,
      // the skipped hour (moved forward by the skip), the hour after.
      ["America/Los_Angeles", "2026-03-08T01:30", "2026-03-08T09:30:00.000Z"],
      ["America/Los_Angeles", "2026-03-08T02:30", "2026-03-08T10:30:00.000Z"],
      ["America/Los_Angeles", "2026-03-08T03:30", "2026-03-08T10:30:00.000Z"],
      // Clocks back at 02:00 on Nov 1: 01:30 happens twice, and the
      // first one (daylight time) is the answer.
      ["America/Los_Angeles", "2026-11-01T00:30", "2026-11-01T07:30:00.000Z"],
      ["America/Los_Angeles", "2026-11-01T01:30", "2026-11-01T08:30:00.000Z"],
      ["America/Los_Angeles", "2026-11-01T02:30", "2026-11-01T10:30:00.000Z"],
      // Havana skips its midnight (00:00 to 01:00 on Mar 8), and repeats
      // 00:00 to 01:00 on Nov 1.
      ["America/Havana", "2026-03-08T00:00", "2026-03-08T05:00:00.000Z"],
      ["America/Havana", "2026-11-01T00:30", "2026-11-01T04:30:00.000Z"],
      // Beirut goes back from 00:00 to 23:00 on Oct 24: midnight comes
      // after the repeated hour, and 23:30 is first the one before it.
      ["Asia/Beirut", "2026-10-25T00:00", "2026-10-24T22:00:00.000Z"],
      ["Asia/Beirut", "2026-10-24T23:30", "2026-10-24T20:30:00.000Z"],
      // Lord Howe moves its clocks by half an hour.
      ["Australia/Lord_Howe", "2026-10-04T02:15", "2026-10-03T15:45:00.000Z"],
      ["Australia/Lord_Howe", "2026-04-05T01:45", "2026-04-04T14:45:00.000Z"],
      // A quarter-hour offset, and no DST.
      ["Asia/Kathmandu", "2026-06-01T12:00", "2026-06-01T06:15:00.000Z"],
    ])("wallClockToInstant: %s %s is %s", (zone, wallClock, instant) => {
      expect(instantOf(wallClock, zone)).toBe(instant);
    });

    it.each([
      ["2026-03-08T09:59:59.999Z", -8 * 60],
      ["2026-03-08T10:00:00.000Z", -7 * 60],
      ["2026-11-01T08:59:59.999Z", -7 * 60],
      ["2026-11-01T09:00:00.000Z", -8 * 60],
      // Before 1970 the count of milliseconds is negative.
      ["1969-12-31T23:59:59.500Z", -8 * 60],
    ])(
      "zoneOffsetMs in Los Angeles at %s is %i minutes",
      (instant, minutes) => {
        expect(zoneOffsetMs(Date.parse(instant), "America/Los_Angeles")).toBe(
          minutes * 60 * 1000,
        );
      },
    );

    it("keeps the milliseconds of a time from the server", () => {
      setCommunityTimezone("America/Los_Angeles");
      expect(
        toCommunityDayjs("2026-05-11T23:00:00.500Z").format("HH:mm:ss.SSS"),
      ).toBe("16:00:00.500");
    });
  },
);

describe("communityNow", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-08T10:00:00Z"));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("reads the community's clock", () => {
    setCommunityTimezone("Europe/Berlin");
    expect(communityNow().format("YYYY-MM-DD HH:mm")).toBe("2026-07-08 12:00");
  });

  it("reflects a cookie change without needing a reimport", () => {
    setCommunityTimezone("America/Los_Angeles");
    expect(communityNow().format("YYYY-MM-DD HH:mm")).toBe("2026-07-08 03:00");

    setCommunityTimezone("Australia/Sydney");
    expect(communityNow().format("YYYY-MM-DD HH:mm")).toBe("2026-07-08 20:00");
  });
});

// "Now" must read the community's clock on every device. A device-local
// Date cannot hold a time that the device's own clock skips, so a clock
// built as one was an hour off in that hour, and in Greenland a day off.
describe.each([
  "America/Chicago",
  "America/New_York",
  "America/Los_Angeles",
  "UTC",
  "Asia/Tokyo",
  "Europe/Berlin",
  "Europe/London",
  "America/Nuuk",
  "Pacific/Honolulu",
])("communityNow on a device in %s", (deviceZone) => {
  useDeviceZone(deviceZone);

  beforeEach(() => {
    setCommunityTimezone("America/Los_Angeles");
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it.each([
    // Greenland's clocks skip from 23:00 to midnight that night.
    ["2026-03-28T23:30:00-07:00", "2026-03-28 23:30"],
    // London's skip from 01:00 to 02:00 on Mar 29, Berlin's from 02:00
    // to 03:00.
    ["2026-03-29T01:30:00-07:00", "2026-03-29 01:30"],
    ["2026-03-29T02:30:00-07:00", "2026-03-29 02:30"],
    // The community's own changes.
    ["2026-03-08T01:59:00-08:00", "2026-03-08 01:59"],
    ["2026-03-08T03:00:00-07:00", "2026-03-08 03:00"],
    ["2026-11-01T01:30:00-07:00", "2026-11-01 01:30"],
    ["2026-11-01T01:30:00-08:00", "2026-11-01 01:30"],
    ["2026-11-01T23:59:00-08:00", "2026-11-01 23:59"],
  ])("at %s reads %s", (instant, wallClock) => {
    vi.setSystemTime(new Date(instant));
    expect(communityNow().format("YYYY-MM-DD HH:mm")).toBe(wallClock);
  });
});

describe("history modal time formatting", () => {
  // The history modal renders audit timestamps with format "ddd MMM D, h:mm a"
  // and the meal date with "ddd, MMM Do". Both must display in the community
  // timezone regardless of the viewer's browser timezone — residents travelling
  // out of tz (or admins in a different tz) must see the same times as anyone
  // at home. Regression guard for app/frontend/src/components/history/show.jsx.

  it("renders audit timestamp in community tz for UTC input", () => {
    setCommunityTimezone("America/Los_Angeles");
    // 22:30 UTC on Apr 23 2026 = 15:30 PDT
    const formatted = toCommunityDayjs("2026-04-23T22:30:00Z").format(
      "ddd MMM D, h:mm a",
    );
    expect(formatted).toBe("Thu Apr 23, 3:30 pm");
  });

  it("renders audit timestamp in community tz when UTC crosses date boundary", () => {
    setCommunityTimezone("America/Los_Angeles");
    // 05:00 UTC on Apr 24 = 22:00 PDT on Apr 23 — displaying in the browser's
    // tz would push this to Apr 24 for anyone east of Pacific.
    const formatted = toCommunityDayjs("2026-04-24T05:00:00.000Z").format(
      "ddd MMM D, h:mm a",
    );
    expect(formatted).toBe("Thu Apr 23, 10:00 pm");
  });

  it("renders audit timestamp in community tz for explicit-offset input", () => {
    setCommunityTimezone("America/Los_Angeles");
    // Server may send either "Z" or an offset; both must round-trip to
    // community tz identically.
    const formatted = toCommunityDayjs("2026-04-23T18:30:00.000-04:00").format(
      "ddd MMM D, h:mm a",
    );
    expect(formatted).toBe("Thu Apr 23, 3:30 pm");
  });

  it("renders meal date header without date drift for date-only input", () => {
    setCommunityTimezone("America/Los_Angeles");
    // Rails serializes Date as "YYYY-MM-DD"; bare dayjs() parses that as UTC,
    // which would shift by a day for anyone west of UTC. toCommunityDayjs
    // must anchor it at community-tz midnight.
    const formatted = toCommunityDayjs("2026-04-23").format("ddd, MMM Do");
    expect(formatted).toBe("Thu, Apr 23rd");
  });

  it("renders the same UTC instant differently for different communities", () => {
    // A single audit row created at 22:30 UTC on Apr 23 must display as
    // evening Pacific for a California community and early morning next-day
    // Berlin for a German community. This is the core reason we read tz from
    // the backend — communities anywhere should see their own local time.
    const iso = "2026-04-23T22:30:00Z";

    setCommunityTimezone("America/Los_Angeles");
    expect(toCommunityDayjs(iso).format("ddd MMM D, h:mm a")).toBe(
      "Thu Apr 23, 3:30 pm",
    );

    setCommunityTimezone("Europe/Berlin");
    expect(toCommunityDayjs(iso).format("ddd MMM D, h:mm a")).toBe(
      "Fri Apr 24, 12:30 am",
    );
  });
});
