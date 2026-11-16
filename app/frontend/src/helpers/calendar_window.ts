import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";

dayjs.extend(utc);

// The days a new dinner, event or booking may fall on, the same rule as
// CalendarWindow on the server (app/models/calendar_window.rb): from 10
// years before the community's today to 10 years after it, and never
// after December 31, 9999. The server refuses a day outside; this keeps
// the forms from offering one, and the calendar from going past the
// last month. Every day is the community's day, "YYYY-MM-DD", counted
// in UTC, so the device's zone takes no part.
//
// February 29 plus or minus 10 years is February 28, as on the server.

export const YEARS = 10;
export const LAST_DAY = "9999-12-31";

// A day as one number, 20261115 for "2026-11-15", so days compare as
// numbers. A string compare would put "10000-01-01" before "9999-12-31".
function asNumber(day: string): number {
  const [year, month, date] = day.split("-").map(Number);
  return year * 10000 + month * 100 + date;
}

export function earlier(a: string, b: string): string {
  return asNumber(a) <= asNumber(b) ? a : b;
}

export function firstDay(today: string): string {
  return dayjs.utc(today).subtract(YEARS, "year").format("YYYY-MM-DD");
}

export function lastDay(today: string): string {
  return earlier(
    dayjs.utc(today).add(YEARS, "year").format("YYYY-MM-DD"),
    LAST_DAY,
  );
}

// Whether `day` is in December 9999 or after, so the calendar has no
// next month to show or fetch.
export function inLastMonthOrAfter(day: string): boolean {
  return asNumber(day) >= asNumber("9999-12-01");
}
