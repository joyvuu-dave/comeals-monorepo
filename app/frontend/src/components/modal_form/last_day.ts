import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";

dayjs.extend(utc);

// The last day a calendar form's day picker offers: six months after
// `day`, the community's day as "YYYY-MM-DD". The same day of the
// month, or the month's last day when that month is shorter (Aug 31
// gives Feb 28). Counted in UTC, so the device's zone takes no part.
export function sixMonthsAfter(day: string): string {
  return dayjs.utc(day).add(6, "month").format("YYYY-MM-DD");
}
