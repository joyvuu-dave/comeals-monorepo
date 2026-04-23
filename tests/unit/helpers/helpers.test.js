import { describe, it, expect, beforeEach, afterAll } from "vitest";
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import Cookie from "js-cookie";
import {
  communityNow,
  generateTimes,
  getCommunityTimezone,
  toCommunityDayjs,
} from "../../../app/frontend/src/helpers/helpers.js";

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

  it("honors a Southern Hemisphere community tz across the DST flip", () => {
    // Sydney is UTC+11 during southern-summer AEDT (observed in May 2026).
    // Wait — Sydney is UTC+10 (AEST) in May. Ensure we pick up AEST not PDT.
    setCommunityTimezone("Australia/Sydney");
    const d = toCommunityDayjs("2026-05-11T00:00:00Z");
    expect(d.hour()).toBe(10); // AEST = UTC+10
    expect(d.date()).toBe(11);
  });
});

describe("communityNow", () => {
  it("produces a dayjs anchored to the community tz", () => {
    setCommunityTimezone("Europe/Berlin");
    const now = communityNow();
    // Offset in minutes from UTC. CET = +60, CEST = +120.
    expect([60, 120]).toContain(now.utcOffset());
  });

  it("reflects a cookie change without needing a reimport", () => {
    setCommunityTimezone("America/Los_Angeles");
    const la = communityNow();
    // PST = -480, PDT = -420
    expect([-480, -420]).toContain(la.utcOffset());

    setCommunityTimezone("Australia/Sydney");
    const syd = communityNow();
    // AEST = +600, AEDT = +660
    expect([600, 660]).toContain(syd.utcOffset());
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
