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

// The two time menus' values for a stored entry: "HH:MM" in the
// community's zone, or "" for an empty menu. `end` may be null.
//
// An entry that starts and ends at the same midnight is a notice. The
// API saves one when both menus are left empty (7c66ade4). So it opens
// with both menus empty, the way the New form makes one, and a save of
// only a new title sends both empty, which the server saves as the same
// notice (#147). Two other entries look like a notice but are not one,
// so their menus show their times. One runs from midnight to the next
// midnight, which admin can make. The other ends when it starts at a
// time that is not midnight, saved before #141. Sent empty, it would
// move to midnight.
export function storedTimes(start, end) {
  var startTime = toTimeString(start);
  var endTime = end ? toTimeString(end) : "";
  if (startTime === "00:00" && end && start.isSame(end)) {
    return { startTime: "", endTime: "" };
  }
  return { startTime, endTime };
}
