import { describe, it, expect } from "vitest";

import * as local from "../../../app/frontend/src/components/calendar/wall_clock_localizer";
import { useDeviceZone } from "../helpers/device_zone.js";

const {
  add,
  ceil,
  continuesAfter,
  continuesPrior,
  daySpan,
  diff,
  endOf,
  eq,
  firstOfWeek,
  firstVisibleDay,
  format,
  formats,
  getDstOffset,
  getMinutesFromMidnight,
  getSlotDate,
  getTimezoneOffset,
  getTotalMin,
  gt,
  gte,
  inEventRange,
  inRange,
  isSameDate,
  lastVisibleDay,
  lt,
  lte,
  max,
  merge,
  min,
  minutes,
  neq,
  range,
  sortEvents,
  startAndEndAreDateOnly,
  startOf,
  visibleDays,
  wallClockLocalizer,
} = local;

// The calendar's date math (#129). Each Date here is a wall-clock Date:
// its UTC fields are the community's wall clock. w("2026-03-08T19:00")
// is 19:00 on Mar 8 on the community's clock.
function w(wallClock: string): Date {
  return new Date(`${wallClock}Z`);
}

// A wall-clock Date as its wall clock, "2026-03-08T19:00:00.000".
function shown(date: Date): string {
  return date.toISOString().slice(0, -1);
}

describe("startOf", () => {
  const at = w("2026-03-11T19:42:31.250");

  it.each([
    [undefined, "2026-03-11T19:42:31.250"],
    ["milliseconds", "2026-03-11T19:42:31.250"],
    ["seconds", "2026-03-11T19:42:31.000"],
    ["minutes", "2026-03-11T19:42:00.000"],
    ["hours", "2026-03-11T19:00:00.000"],
    ["day", "2026-03-11T00:00:00.000"],
    // Weeks start on Sunday: Wednesday, Mar 11 is in the week of Mar 8.
    ["week", "2026-03-08T00:00:00.000"],
    ["month", "2026-03-01T00:00:00.000"],
    ["year", "2026-01-01T00:00:00.000"],
  ] as const)("of %s", (unit, start) => {
    expect(shown(startOf(at, unit))).toBe(start);
  });

  it("gives a new Date, so the caller's is never changed", () => {
    expect(startOf(at)).not.toBe(at);
  });

  it("puts a Sunday at the start of its own week", () => {
    expect(shown(startOf(w("2026-03-08T19:00"), "week"))).toBe(
      "2026-03-08T00:00:00.000",
    );
    expect(shown(startOf(w("2026-03-07T23:59"), "week"))).toBe(
      "2026-03-01T00:00:00.000",
    );
  });

  it("counts days before 1970 too", () => {
    expect(shown(startOf(w("1969-12-31T18:30"), "day"))).toBe(
      "1969-12-31T00:00:00.000",
    );
  });

  // Date.UTC would read the year 50 as 1950.
  it("keeps a year below 100", () => {
    const year50 = new Date(Date.parse("0050-06-15T12:00:00Z"));
    expect(startOf(year50, "year").getUTCFullYear()).toBe(50);
    expect(startOf(year50, "month").getUTCFullYear()).toBe(50);
  });
});

describe("add", () => {
  it.each([
    ["milliseconds", 5, "2026-03-08T19:00:00.005"],
    ["seconds", 5, "2026-03-08T19:00:05.000"],
    ["minutes", -30, "2026-03-08T18:30:00.000"],
    ["hours", 6, "2026-03-09T01:00:00.000"],
    ["day", 1, "2026-03-09T19:00:00.000"],
    ["week", -1, "2026-03-01T19:00:00.000"],
    ["month", 1, "2026-04-08T19:00:00.000"],
    ["month", 10, "2027-01-08T19:00:00.000"],
    ["year", -1, "2025-03-08T19:00:00.000"],
  ] as const)("%s %s", (unit, amount, result) => {
    expect(shown(add(w("2026-03-08T19:00"), amount, unit))).toBe(result);
  });

  // Every day is 24 hours, including the day the community's clocks go
  // forward (Mar 8, 2026 in Los Angeles) and the day they go back.
  it("adds a whole day on the days a zone changes its clocks", () => {
    expect(shown(add(w("2026-03-08T00:00"), 1, "day"))).toBe(
      "2026-03-09T00:00:00.000",
    );
    expect(shown(add(w("2026-11-01T00:00"), 1, "day"))).toBe(
      "2026-11-02T00:00:00.000",
    );
  });

  it("takes the last day of a shorter month", () => {
    expect(shown(add(w("2026-01-31T18:00"), 1, "month"))).toBe(
      "2026-02-28T18:00:00.000",
    );
    expect(shown(add(w("2026-03-31T18:00"), -1, "month"))).toBe(
      "2026-02-28T18:00:00.000",
    );
    expect(shown(add(w("2028-01-31T18:00"), 1, "month"))).toBe(
      "2028-02-29T18:00:00.000",
    );
    expect(shown(add(w("2028-02-29T18:00"), 1, "year"))).toBe(
      "2029-02-28T18:00:00.000",
    );
  });
});

describe("endOf", () => {
  it.each([
    ["day", "2026-03-11T23:59:59.999"],
    ["week", "2026-03-14T23:59:59.999"],
    ["month", "2026-03-31T23:59:59.999"],
  ] as const)("of %s", (unit, end) => {
    expect(shown(endOf(w("2026-03-11T19:00"), unit))).toBe(end);
  });
});

describe("diff", () => {
  it("counts milliseconds when no unit is given", () => {
    expect(diff(w("2026-03-08T19:00"), w("2026-03-08T19:00:01"))).toBe(1000);
  });

  it("counts from the start of each date's unit, either way round", () => {
    const late = w("2026-03-08T23:00");
    const early = w("2026-03-09T01:00");
    expect(diff(late, early, "day")).toBe(1);
    expect(diff(early, late, "day")).toBe(1);
    expect(diff(late, early, "minutes")).toBe(120);
    expect(diff(w("2026-03-07T12:00"), w("2026-03-08T12:00"), "week")).toBe(1);
  });
});

describe("the comparisons", () => {
  const evening = w("2026-03-08T19:00");
  const night = w("2026-03-08T23:30");
  const nextDay = w("2026-03-09T00:30");

  it("compare the instants when no unit is given", () => {
    expect(eq(evening, w("2026-03-08T19:00"))).toBe(true);
    expect(neq(evening, night)).toBe(true);
    expect(lt(evening, night)).toBe(true);
    expect(gt(night, evening)).toBe(true);
  });

  it("compare the starts of the unit when one is given", () => {
    expect(eq(evening, night, "day")).toBe(true);
    expect(neq(evening, night, "day")).toBe(false);
    expect(lt(night, nextDay, "day")).toBe(true);
    expect(lte(evening, night, "day")).toBe(true);
    expect(lte(nextDay, night, "day")).toBe(false);
    expect(gt(nextDay, night, "day")).toBe(true);
    expect(gte(evening, night, "day")).toBe(true);
    expect(gte(evening, nextDay, "day")).toBe(false);
  });

  it("inRange includes both ends, by day unless told otherwise", () => {
    const first = w("2026-03-08T12:00");
    const last = w("2026-03-10T12:00");
    expect(inRange(w("2026-03-08T00:00"), first, last)).toBe(true);
    expect(inRange(w("2026-03-10T23:59"), first, last)).toBe(true);
    expect(inRange(w("2026-03-11T00:00"), first, last)).toBe(false);
    expect(inRange(w("2026-03-08T11:00"), first, last, "hours")).toBe(false);
  });

  it("min and max give the earlier and the later", () => {
    expect(min(night, evening)).toEqual(evening);
    expect(max(night, evening)).toEqual(night);
  });
});

describe("range", () => {
  it("lists each day from the first to the last, both included", () => {
    expect(
      range(w("2026-03-07T18:00"), w("2026-03-09T01:00")).map(shown),
    ).toEqual([
      "2026-03-07T18:00:00.000",
      "2026-03-08T18:00:00.000",
      "2026-03-09T18:00:00.000",
    ]);
  });

  it("lists other units too", () => {
    expect(
      range(w("2026-01-15T00:00"), w("2026-03-01T00:00"), "month").map(shown),
    ).toEqual([
      "2026-01-15T00:00:00.000",
      "2026-02-15T00:00:00.000",
      "2026-03-15T00:00:00.000",
    ]);
  });
});

describe("ceil", () => {
  it("keeps a date at the start of its unit", () => {
    expect(shown(ceil(w("2026-03-08T00:00"), "day"))).toBe(
      "2026-03-08T00:00:00.000",
    );
  });

  it("moves any other date to the start of the next unit", () => {
    expect(shown(ceil(w("2026-03-08T00:01"), "day"))).toBe(
      "2026-03-09T00:00:00.000",
    );
  });
});

describe("the time grid's helpers", () => {
  it("merge puts one date's time on the other's day", () => {
    expect(shown(merge(w("2026-03-08T00:00"), w("2026-01-01T02:30")))).toBe(
      "2026-03-08T02:30:00.000",
    );
  });

  it("minutes reads the wall clock's minutes", () => {
    expect(minutes(w("2026-03-08T02:30"))).toBe(30);
  });

  it("getSlotDate counts minutes from the day's midnight", () => {
    expect(shown(getSlotDate(w("2026-03-08T19:00"), 150, 15))).toBe(
      "2026-03-08T02:45:00.000",
    );
  });

  // 02:30 on Mar 8, 2026 never happens in Los Angeles, and the calendar
  // must still be able to show the hours around it. In UTC no hour is
  // skipped or repeated.
  it("has no offset and no daylight saving time", () => {
    expect(getTimezoneOffset()).toBe(0);
    expect(getDstOffset()).toBe(0);
    expect(getTotalMin(w("2026-03-08T00:00"), w("2026-03-09T00:00"))).toBe(
      24 * 60,
    );
    expect(getMinutesFromMidnight(w("2026-03-08T03:00"))).toBe(180);
  });
});

describe("the month grid", () => {
  it("shows the whole weeks of March 2026, Sunday to Saturday", () => {
    const march = w("2026-03-15T12:00");
    expect(shown(firstVisibleDay(march))).toBe("2026-03-01T00:00:00.000");
    expect(shown(lastVisibleDay(march))).toBe("2026-04-04T23:59:59.999");
    const days = visibleDays(march);
    expect(days).toHaveLength(35);
    expect(shown(days[7])).toBe("2026-03-08T00:00:00.000");
    expect(shown(days[34])).toBe("2026-04-04T00:00:00.000");
  });

  it("shows four weeks for February 2026, which starts on a Sunday", () => {
    const days = visibleDays(w("2026-02-10T00:00"));
    expect(days).toHaveLength(28);
    expect(shown(days[0])).toBe("2026-02-01T00:00:00.000");
  });

  it("isSameDate compares days", () => {
    expect(isSameDate(w("2026-03-28T23:30"), w("2026-03-28T00:00"))).toBe(true);
    expect(isSameDate(w("2026-03-28T23:30"), w("2026-03-29T00:30"))).toBe(
      false,
    );
  });

  it("a chip continues before the first day or after the last", () => {
    const first = w("2026-03-08T00:00");
    const last = w("2026-03-15T00:00");
    expect(continuesPrior(w("2026-03-07T23:00"), first)).toBe(true);
    expect(continuesPrior(w("2026-03-08T01:00"), first)).toBe(false);
    expect(
      continuesAfter(w("2026-03-14T20:00"), w("2026-03-15T00:30"), last),
    ).toBe(true);
    expect(continuesAfter(w("2026-03-14T20:00"), last, last)).toBe(false);
    // A chip with no length that ends right at the last moment.
    expect(continuesAfter(last, last, last)).toBe(true);
  });

  it("daySpan counts the days between the start's day and the end's", () => {
    expect(daySpan(w("2026-01-13T00:01"), w("2026-01-17T23:59"))).toBe(4);
    expect(daySpan(w("2026-03-08T19:00"), w("2026-03-08T21:00"))).toBe(0);
    // Across the end of a month too.
    expect(daySpan(w("2026-01-30T19:00"), w("2026-02-02T09:00"))).toBe(3);
  });

  it("startAndEndAreDateOnly is true when both are at midnight", () => {
    const midnight = w("2026-03-08T00:00");
    expect(startAndEndAreDateOnly(midnight, w("2026-03-09T00:00"))).toBe(true);
    expect(startAndEndAreDateOnly(midnight, w("2026-03-09T00:01"))).toBe(false);
    expect(startAndEndAreDateOnly(w("2026-03-08T00:01"), midnight)).toBe(false);
  });
});

describe("sortEvents", () => {
  function chip(start: string, end: string, allDay?: boolean) {
    return { start: w(start), end: w(end), allDay };
  }

  function sign(
    a: ReturnType<typeof chip>,
    b: ReturnType<typeof chip>,
  ): number {
    return Math.sign(sortEvents({ evtA: a, evtB: b }));
  }

  it("puts the earlier day first", () => {
    expect(
      sign(
        chip("2026-03-08T23:00", "2026-03-08T23:30"),
        chip("2026-03-09T00:30", "2026-03-09T01:00"),
      ),
    ).toBe(-1);
  });

  it("puts a chip that spans more days first on the same day", () => {
    expect(
      sign(
        chip("2026-03-08T19:00", "2026-03-08T20:00"),
        chip("2026-03-08T21:00", "2026-03-10T09:00"),
      ),
    ).toBe(1);
  });

  it("puts an all-day chip before a timed one", () => {
    expect(
      sign(
        chip("2026-03-08T19:00", "2026-03-08T20:00"),
        chip("2026-03-08T19:00", "2026-03-08T20:00", true),
      ),
    ).toBe(1);
  });

  it("then sorts by start, then by end", () => {
    expect(
      sign(
        chip("2026-03-08T00:30", "2026-03-08T00:45"),
        chip("2026-03-08T01:00", "2026-03-08T01:15"),
      ),
    ).toBe(-1);
    expect(
      sign(
        chip("2026-03-08T19:00", "2026-03-08T21:00"),
        chip("2026-03-08T19:00", "2026-03-08T20:00"),
      ),
    ).toBe(1);
    expect(
      sign(
        chip("2026-03-08T19:00", "2026-03-08T20:00"),
        chip("2026-03-08T19:00", "2026-03-08T20:00"),
      ),
    ).toBe(0);
  });
});

describe("inEventRange", () => {
  const week = { start: w("2026-03-08T00:00"), end: w("2026-03-14T00:00") };

  function inWeek(start: string, end: string): boolean {
    return inEventRange({
      event: { start: w(start), end: w(end) },
      range: week,
    });
  }

  it("takes a chip that starts on or before the last day", () => {
    expect(inWeek("2026-03-14T23:00", "2026-03-14T23:30")).toBe(true);
    expect(inWeek("2026-03-15T00:00", "2026-03-15T01:00")).toBe(false);
  });

  it("takes a chip that ends after the first moment", () => {
    expect(inWeek("2026-03-07T20:00", "2026-03-08T01:00")).toBe(true);
    expect(inWeek("2026-03-07T20:00", "2026-03-08T00:00")).toBe(false);
  });

  // A chip with no length ends when it starts, so it counts at the
  // range's first moment too.
  it("takes a chip with no length right at the first moment", () => {
    expect(inWeek("2026-03-08T00:00", "2026-03-08T00:00")).toBe(true);
  });
});

describe("format", () => {
  it("shows the wall clock in the date-fns localizer's formats", () => {
    const skipped = w("2026-03-08T02:30");
    expect(format(skipped, formats.dateFormat)).toBe("08");
    expect(format(skipped, formats.weekdayFormat)).toBe("Sun");
    expect(format(skipped, formats.monthHeaderFormat)).toBe("March 2026");
    expect(format(skipped, formats.dayHeaderFormat)).toBe("Sunday Mar 08");
    expect(format(skipped, formats.timeGutterFormat)).toBe("2:30 AM");
  });

  const span = { start: w("2026-03-08T19:00"), end: w("2026-03-08T21:30") };
  const longSpan = { start: w("2026-03-29T00:00"), end: w("2026-04-04T00:00") };

  it("joins the times of a span", () => {
    expect(formats.eventTimeRangeFormat(span, undefined, { format })).toBe(
      "7:00 PM – 9:30 PM",
    );
    expect(formats.eventTimeRangeStartFormat(span, undefined, { format })).toBe(
      "7:00PM – ",
    );
    expect(formats.eventTimeRangeEndFormat(span, undefined, { format })).toBe(
      " – 9:30PM",
    );
  });

  it("joins the days of a span", () => {
    expect(formats.dayRangeHeaderFormat(span, undefined, { format })).toBe(
      "March 08 – 08",
    );
    expect(formats.dayRangeHeaderFormat(longSpan, undefined, { format })).toBe(
      "March 29 – April 04",
    );
    expect(formats.agendaHeaderFormat(longSpan, undefined, { format })).toBe(
      "03/29/2026 – 04/04/2026",
    );
  });

  it("starts weeks on Sunday", () => {
    expect(firstOfWeek()).toBe(0);
  });
});

// react-big-calendar's DateLocalizer takes these by name. Any it is not
// given, it does in the device's zone, which is the bug this file fixes.
it("hands react-big-calendar every piece of date math it can take", () => {
  expect(Object.keys(wallClockLocalizer).sort()).toEqual(
    [
      "add",
      "ceil",
      "continuesAfter",
      "continuesPrior",
      "daySpan",
      "diff",
      "endOf",
      "eq",
      "firstOfWeek",
      "firstVisibleDay",
      "format",
      "formats",
      "getDstOffset",
      "getMinutesFromMidnight",
      "getSlotDate",
      "getTimezoneOffset",
      "getTotalMin",
      "gt",
      "gte",
      "inEventRange",
      "inRange",
      "isSameDate",
      "lastVisibleDay",
      "lt",
      "lte",
      "max",
      "merge",
      "min",
      "minutes",
      "neq",
      "range",
      "sortEvents",
      "startAndEndAreDateOnly",
      "startOf",
      "visibleDays",
    ].sort(),
  );
});

// The math reads only UTC fields, so the device's zone takes no part.
// Each of these zones skips an hour in March 2026: Havana at midnight on
// Mar 8, Los Angeles at 02:00 that day, London at 01:00 on Mar 29, and
// Greenland at 23:00 on Mar 28.
describe.each([
  "America/Havana",
  "America/Los_Angeles",
  "Europe/London",
  "America/Nuuk",
  "Asia/Tokyo",
])("on a device in %s", (zone) => {
  useDeviceZone(zone);

  it("lays out March 2026 the same way", () => {
    const days = visibleDays(w("2026-03-15T12:00"));
    expect(days.map((day) => format(day, "D")).join(" ")).toBe(
      "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 1 2 3 4",
    );
    expect(
      days.every((day, i) => i === 0 || +day - +days[i - 1] === 86400000),
    ).toBe(true);
  });

  it("keeps each skipped time on its own day, in its own hour", () => {
    for (const wallClock of [
      "2026-03-08T00:30",
      "2026-03-08T02:30",
      "2026-03-29T01:30",
      "2026-03-28T23:30",
    ]) {
      const at = w(wallClock);
      expect(format(at, "YYYY-MM-DDTHH:mm")).toBe(wallClock);
      expect(shown(startOf(at, "day")).slice(0, 10)).toBe(
        wallClock.slice(0, 10),
      );
    }
  });
});
