// The wire format the events and common-house endpoints expect for a
// start/end pair: the day split into calendar parts plus "HH:MM" times
// split into hours and minutes. `day` is a Date or null; times are
// "HH:MM" strings or "".
export function buildStartEndPayload(day, startTime, endTime) {
  return {
    start_year: day && day.getFullYear(),
    start_month: day && day.getMonth() + 1,
    start_day: day && day.getDate(),
    start_hours: startTime && startTime.split(":")[0],
    start_minutes: startTime && startTime.split(":")[1],
    end_hours: endTime && endTime.split(":")[0],
    end_minutes: endTime && endTime.split(":")[1],
  };
}

// "HH:MM" in the community timezone from a dayjs value, for hydrating
// the TimeSelect state from a fetched record.
export function toTimeString(d) {
  return `${d.hour().toString().padStart(2, "0")}:${d
    .minute()
    .toString()
    .padStart(2, "0")}`;
}
