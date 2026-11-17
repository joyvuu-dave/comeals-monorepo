import type { MouseEvent, ReactNode } from "react";
import { Link } from "react-router";

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
export default function CalendarChip({
  event,
  title,
}: {
  event: { url?: string };
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
    </Link>
  );
}

// react-big-calendar marks each week as a table row (role="row") and
// puts the entries straight in it, outside any cell. A link there
// breaks the table: a row may only hold cells, and a screen reader
// reads the week wrong. So each entry is wrapped in a cell.
export function CalendarChipCell({ children }: { children?: ReactNode }) {
  return <div role="cell">{children}</div>;
}
