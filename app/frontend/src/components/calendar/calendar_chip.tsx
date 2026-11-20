import type { MouseEvent, ReactNode } from "react";
import { Link } from "react-router";
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";

dayjs.extend(utc);

// The inside of one calendar entry (a dinner, an event, a booking, a
// rotation). react-big-calendar draws the entry as a div that Tab
// cannot reach, and its eventPropGetter passes only a class and a
// style, so the title is drawn here as a link to the entry's address.
// Tab reaches the link, and Enter opens the entry.
//
// The whole entry still takes the click: react-big-calendar's own
// onClick calls onSelectEvent (calendar/show.jsx), which opens it. So
// the link does not open the address itself; it lets the click go on
// to the entry. A click with a key held (Cmd, Ctrl, Shift) or with the
// middle button is left to the browser, which opens a new tab or
// window, and stops there, so this tab stays on the calendar.
//
// The link also says the entry's date, in text only a screen reader
// reads. A person who sees the calendar knows the day from the box the
// entry is in. A VoiceOver user who moves from link to link hears only
// the link, and before this heard "Dinner 2 attending" with no day
// (tests/voiceover/sign_up.spec.js).
export default function CalendarChip({
  event,
  title,
}: {
  event: { url?: string; start?: Date; end?: Date };
  title: ReactNode;
}) {
  if (!event.url) return title;
  return (
    <Link
      to={event.url}
      className="calendar-chip-link"
      onClick={function (e: MouseEvent<HTMLAnchorElement>) {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button) {
          e.stopPropagation();
          return;
        }
        e.preventDefault();
      }}
    >
      {/* One box for the title's lines, so the link can center them
          from top to bottom (styles.css). */}
      <span>{title}</span>
      <span className="visually-hidden">
        {spokenDates(event.start, event.end)}
      </span>
    </Link>
  );
}

// ", Thursday, January 15", or for an entry over more than one day (a
// rotation) ", Monday, January 5 to Saturday, January 17". The dates
// are wall-clock Dates, whose UTC fields are the community's wall clock
// (wall_clock_localizer.ts), so they are read in UTC. A rotation's end
// is the last minute of its last day (RotationSerializer#end), so the
// end's own date is its last day. An event or booking that ends at
// midnight (10pm to 12am) ends on the day it started: midnight is the
// end of that day, not a minute of the next one.
export function spokenDates(start?: Date, end?: Date): string {
  if (!start) return "";
  const first = dayjs.utc(start);
  let last = end ? dayjs.utc(end) : first;
  if (last.isAfter(first) && last.isSame(last.startOf("day"))) {
    last = last.subtract(1, "millisecond");
  }
  const format = "dddd, MMMM D";
  if (last.isSame(first, "day")) return `, ${first.format(format)}`;
  return `, ${first.format(format)} to ${last.format(format)}`;
}

// react-big-calendar marks each week as a table row (role="row") and
// puts the entries straight in it, outside any cell. A link there
// breaks the table: a row may only hold cells, and a screen reader
// reads the week wrong. So each entry is wrapped in a cell.
export function CalendarChipCell({ children }: { children?: ReactNode }) {
  return <div role="cell">{children}</div>;
}
