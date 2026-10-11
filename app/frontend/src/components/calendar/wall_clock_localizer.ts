// The date math react-big-calendar runs on, for a calendar that shows
// every time in the community's zone, on every device (#129).
//
// react-big-calendar takes each time as a JavaScript Date. A Date is an
// instant, and the date-fns localizer the app used read its fields (day,
// hour) in the device's zone. So the app handed it each community time
// as a Date in the device's zone, new Date(year, month, day, hour,
// minute). But a time that the device's own clock skips, in the hour
// its clocks go forward, cannot be such a Date: it moves forward by the
// skip. On a phone in Greenland, whose clocks skip from 23:00 to
// midnight on Saturday, Mar 28, 2026, an event at 23:30 that Saturday in
// Los Angeles was drawn at 00:30 on Sunday.
//
// So the calendar gets wall-clock Dates instead: a Date whose UTC fields
// are the community's wall clock. 19:00 on Mar 8 in Los Angeles is
// 2026-03-08T19:00:00Z, whatever the instant. UTC has no daylight
// saving time, so every wall-clock time is exactly one such Date, every
// day is 24 hours long, and every day starts at midnight. This file does
// all of the calendar's date math with the UTC fields alone, so neither
// the device's zone nor the community's takes part in it. The
// community's zone is read once, where a time from the server becomes
// wall-clock fields (toCommunityDayjs and communityNow in
// helpers/helpers.js).
//
// A wall-clock Date is not the instant it names. Never compare one with
// the clock (Date.now()) or send one to the server.
//
// react-big-calendar's own localizers cannot do this. Its date-fns
// localizer does the math in the device's zone. Its luxon and dayjs
// localizers can work in another zone, but when that zone is ahead of
// the device's they draw every chip that spans days one day short
// (browserTZOffset): with luxon set to Los Angeles, a phone in Hawaii
// draws a rotation from Tuesday to Saturday as Tuesday to Friday. The
// dayjs one also goes through the device's zone (#122, #123).
//
// The calendar shows only its month view. The week and day views would
// also need the min, max and scrollToTime props: by default they read
// the device's clock with new Date().

import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";

dayjs.extend(utc);

// The units react-big-calendar asks for.
export type Unit =
  | "milliseconds"
  | "seconds"
  | "minutes"
  | "hours"
  | "day"
  | "week"
  | "month"
  | "year";

// The units with a fixed length. In UTC that is every unit up to a week.
type FixedUnit = Exclude<Unit, "month" | "year">;

const MINUTE_MS = 60 * 1000;
const DAY_MS = 24 * 60 * MINUTE_MS;

const UNIT_MS: Record<FixedUnit, number> = {
  milliseconds: 1,
  seconds: 1000,
  minutes: MINUTE_MS,
  hours: 60 * MINUTE_MS,
  day: DAY_MS,
  week: 7 * DAY_MS,
};

// Weeks start on Sunday, as they do in en-US.
const SUNDAY = 0;

// Midnight UTC at the start of a day. setUTCFullYear, not Date.UTC:
// Date.UTC reads the years 0 to 99 as 1900 to 1999. A month or day
// past the end carries over, as Date.UTC's do.
function utcDay(year: number, month: number, day: number): Date {
  const date = new Date(0);
  date.setUTCFullYear(year, month, day);
  return date;
}

// Milliseconds since the start of the date's day.
function timeOfDay(date: Date): number {
  return +date - +startOf(date, "day");
}

export function startOf(date: Date, unit?: Unit): Date {
  switch (unit) {
    case undefined:
    case "milliseconds":
      return new Date(+date);
    case "year":
      return utcDay(date.getUTCFullYear(), 0, 1);
    case "month":
      return utcDay(date.getUTCFullYear(), date.getUTCMonth(), 1);
    case "week": {
      const day = startOf(date, "day");
      return add(day, -((day.getUTCDay() - SUNDAY + 7) % 7), "day");
    }
    default:
      // The UTC count starts at a midnight, so every second, minute,
      // hour and day starts at a whole multiple of its length.
      return new Date(Math.floor(+date / UNIT_MS[unit]) * UNIT_MS[unit]);
  }
}

// A month or a year later keeps the day of the month, or takes the
// month's last day when it is shorter: Jan 31 and one month is Feb 28.
export function add(date: Date, amount: number, unit: Unit): Date {
  if (unit === "month" || unit === "year") {
    const months = unit === "year" ? amount * 12 : amount;
    const first = utcDay(date.getUTCFullYear(), date.getUTCMonth() + months, 1);
    const daysInMonth = utcDay(
      first.getUTCFullYear(),
      first.getUTCMonth() + 1,
      0,
    ).getUTCDate();
    const day = Math.min(date.getUTCDate(), daysInMonth);
    return new Date(+first + (day - 1) * DAY_MS + timeOfDay(date));
  }
  return new Date(+date + amount * UNIT_MS[unit]);
}

// The last millisecond of the date's unit.
export function endOf(date: Date, unit: Unit): Date {
  return new Date(+add(startOf(date, unit), 1, unit) - 1);
}

// How many units apart the starts of the two dates' units are, always
// zero or more, as react-big-calendar's own diff counts.
export function diff(a: Date, b: Date, unit: FixedUnit = "milliseconds") {
  return Math.abs(+startOf(b, unit) - +startOf(a, unit)) / UNIT_MS[unit];
}

// Below zero when a's unit is before b's, zero when it is the same.
function compare(a: Date, b: Date, unit?: Unit): number {
  return +startOf(a, unit) - +startOf(b, unit);
}

export function eq(a: Date, b: Date, unit?: Unit): boolean {
  return compare(a, b, unit) === 0;
}

export function neq(a: Date, b: Date, unit?: Unit): boolean {
  return compare(a, b, unit) !== 0;
}

export function lt(a: Date, b: Date, unit?: Unit): boolean {
  return compare(a, b, unit) < 0;
}

export function lte(a: Date, b: Date, unit?: Unit): boolean {
  return compare(a, b, unit) <= 0;
}

export function gt(a: Date, b: Date, unit?: Unit): boolean {
  return compare(a, b, unit) > 0;
}

export function gte(a: Date, b: Date, unit?: Unit): boolean {
  return compare(a, b, unit) >= 0;
}

export function inRange(
  date: Date,
  min: Date,
  max: Date,
  unit: Unit = "day",
): boolean {
  return gte(date, min, unit) && lte(date, max, unit);
}

export function min(a: Date, b: Date): Date {
  return new Date(Math.min(+a, +b));
}

export function max(a: Date, b: Date): Date {
  return new Date(Math.max(+a, +b));
}

// Each unit from start's to end's, both included.
export function range(start: Date, end: Date, unit: Unit = "day"): Date[] {
  const dates = [];
  for (let current = start; lte(current, end, unit);) {
    dates.push(current);
    current = add(current, 1, unit);
  }
  return dates;
}

// The start of the unit, or of the next one when the date is past it.
export function ceil(date: Date, unit: Unit): Date {
  const floor = startOf(date, unit);
  return eq(floor, date) ? floor : add(floor, 1, unit);
}

// date's day at time's time of day.
export function merge(date: Date, time: Date): Date {
  return new Date(+startOf(date, "day") + timeOfDay(time));
}

export function minutes(date: Date): number {
  return date.getUTCMinutes();
}

// The month grid: whole weeks, from the week of the month's first day
// to the week of its last.
export function firstVisibleDay(date: Date): Date {
  return startOf(startOf(date, "month"), "week");
}

export function lastVisibleDay(date: Date): Date {
  return endOf(endOf(date, "month"), "week");
}

export function visibleDays(date: Date): Date[] {
  return range(firstVisibleDay(date), lastVisibleDay(date), "day");
}

// The time grid of the week and day views.
export function getSlotDate(
  date: Date,
  minutesFromMidnight: number,
  offset: number,
): Date {
  return add(startOf(date, "day"), minutesFromMidnight + offset, "minutes");
}

// UTC has no offset and no daylight saving time.
export function getTimezoneOffset(): number {
  return 0;
}

export function getDstOffset(): number {
  return 0;
}

export function getTotalMin(start: Date, end: Date): number {
  return diff(start, end, "minutes");
}

export function getMinutesFromMidnight(date: Date): number {
  return diff(startOf(date, "day"), date, "minutes");
}

// A chip that starts before the first day on screen, or ends after the
// last.
export function continuesPrior(start: Date, first: Date): boolean {
  return lt(start, first, "day");
}

export function continuesAfter(start: Date, end: Date, last: Date): boolean {
  return eq(start, end, "minutes")
    ? gte(end, last, "minutes")
    : gt(end, last, "minutes");
}

// How many days after the start's day the end's day is.
export function daySpan(start: Date, end: Date): number {
  return diff(start, end, "day");
}

interface CalendarEvent {
  start: Date;
  end: Date;
  allDay?: boolean;
}

// The order of the chips: by day, then the ones that span more days,
// then all-day ones, then by start and end. react-big-calendar's own
// order, with this file's days.
export function sortEvents({
  evtA,
  evtB,
}: {
  evtA: CalendarEvent;
  evtB: CalendarEvent;
}): number {
  return (
    compare(evtA.start, evtB.start, "day") ||
    daySpan(evtB.start, evtB.end) - daySpan(evtA.start, evtA.end) ||
    Number(Boolean(evtB.allDay)) - Number(Boolean(evtA.allDay)) ||
    +evtA.start - +evtB.start ||
    +evtA.end - +evtB.end
  );
}

// Whether a chip belongs in the range on screen: it starts on or before
// the range's last day and ends after the range starts. A chip with no
// length ends when it starts, so it counts when it ends right at the
// range's start, too.
export function inEventRange({
  event,
  range,
}: {
  event: CalendarEvent;
  range: { start: Date; end: Date };
}): boolean {
  const startDay = startOf(event.start, "day");
  const startsBeforeEnd = lte(startDay, range.end, "day");
  const endsAfterStart = neq(startDay, event.end, "minutes")
    ? gt(event.end, range.start, "minutes")
    : gte(event.end, range.start, "minutes");
  return startsBeforeEnd && endsAfterStart;
}

export function isSameDate(a: Date, b: Date): boolean {
  return eq(a, b, "day");
}

export function startAndEndAreDateOnly(start: Date, end: Date): boolean {
  return eq(start, startOf(start, "day")) && eq(end, startOf(end, "day"));
}

// dayjs in UTC mode reads the UTC fields of a plain Date. Not date-fns
// with @date-fns/tz: its TZDate is a subclass of Date, and under
// Playwright's frozen clock (page.clock) a subclass of Date comes out as
// a plain Date, so every browser test would format in the device's zone.
export function format(value: Date, formatString: string): string {
  return dayjs.utc(value).format(formatString);
}

export function firstOfWeek(): number {
  return SUNDAY;
}

// The formats react-big-calendar's date-fns localizer uses, in dayjs's
// tokens, so the screen reads as it did.
interface Formatter {
  format(value: Date, formatString: string): string;
}

interface Span {
  start: Date;
  end: Date;
}

function timeRange({ start, end }: Span, _culture: unknown, local: Formatter) {
  return `${local.format(start, "h:mm A")} – ${local.format(end, "h:mm A")}`;
}

export const formats = {
  dateFormat: "DD",
  dayFormat: "DD ddd",
  weekdayFormat: "ddd",
  selectRangeFormat: timeRange,
  eventTimeRangeFormat: timeRange,
  eventTimeRangeStartFormat(
    { start }: Span,
    _culture: unknown,
    local: Formatter,
  ) {
    return `${local.format(start, "h:mmA")} – `;
  },
  eventTimeRangeEndFormat({ end }: Span, _culture: unknown, local: Formatter) {
    return ` – ${local.format(end, "h:mmA")}`;
  },
  timeGutterFormat: "h:mm A",
  monthHeaderFormat: "MMMM YYYY",
  dayHeaderFormat: "dddd MMM DD",
  dayRangeHeaderFormat(
    { start, end }: Span,
    _culture: unknown,
    local: Formatter,
  ) {
    const endFormat = eq(start, end, "month") ? "DD" : "MMMM DD";
    return `${local.format(start, "MMMM DD")} – ${local.format(end, endFormat)}`;
  },
  agendaHeaderFormat(
    { start, end }: Span,
    _culture: unknown,
    local: Formatter,
  ) {
    return `${local.format(start, "MM/DD/YYYY")} – ${local.format(end, "MM/DD/YYYY")}`;
  },
  agendaDateFormat: "ddd MMM DD",
  agendaTimeFormat: "h:mm A",
  agendaTimeRangeFormat: timeRange,
};

// Everything react-big-calendar's DateLocalizer takes, for
// `new DateLocalizer(wallClockLocalizer)` in calendar/show.jsx.
export const wallClockLocalizer = {
  format,
  formats,
  firstOfWeek,
  startOf,
  endOf,
  add,
  diff,
  eq,
  neq,
  lt,
  lte,
  gt,
  gte,
  inRange,
  min,
  max,
  range,
  ceil,
  merge,
  minutes,
  firstVisibleDay,
  lastVisibleDay,
  visibleDays,
  getSlotDate,
  getTimezoneOffset,
  getDstOffset,
  getTotalMin,
  getMinutesFromMidnight,
  continuesPrior,
  continuesAfter,
  daySpan,
  sortEvents,
  inEventRange,
  isSameDate,
  startAndEndAreDateOnly,
};
