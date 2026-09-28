// The instant, as a Date, at which the wall clock in `zone` shows
// `wallClock` ("2026-01-15T12:00"). The zone's offset comes from Intl,
// which knows each zone's rules. The zone of the machine running the
// tests takes no part: dayjs.tz does use it, and near a DST change on a
// machine in another zone its answer can be an hour off (#123).
//
// A time the zone skips, or one it shows twice, has no single instant.
// No test needs one, so this throws for both.

const DAY_MS = 24 * 60 * 60 * 1000;

// How far the wall clock in `zone` is ahead of UTC at the instant `ms`,
// in milliseconds.
function offsetAt(ms, zone) {
  const parts = {};
  new Intl.DateTimeFormat("en-US", {
    timeZone: zone,
    hourCycle: "h23",
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
    second: "numeric",
    fractionalSecondDigits: 3,
  })
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
    parts.second,
    parts.fractionalSecond,
  );
  return wall - ms;
}

function zonedInstant(wallClock, zone) {
  const wall = Date.parse(`${wallClock}Z`);
  // Try the zone's offset a day before and a day after: the offsets on
  // the two sides of any change near this time. Keep each instant at
  // which the zone's clock really shows the time.
  const instants = new Set(
    [wall - DAY_MS, wall + DAY_MS]
      .map((near) => wall - offsetAt(near, zone))
      .filter((instant) => instant + offsetAt(instant, zone) === wall),
  );
  if (instants.size !== 1) {
    throw new Error(
      `${wallClock} happens ${instants.size} times in ${zone}, not once`,
    );
  }
  return new Date([...instants][0]);
}

module.exports = { zonedInstant };
