// Where react-big-calendar drew a chip in its month grid, read from the
// DOM the way a person reads the screen: the day number above the
// chip's column, in the chip's week, and the chip's row in that week.
//
// Each week is a .rbc-month-row. Its first .rbc-row holds the seven
// date cells. Each later .rbc-row is one line of chips, made of
// .rbc-row-segment boxes: a chip's box, or an empty box for a gap. A
// box's flex-basis is its width as a share of the week, so the boxes
// before a chip say which of the seven columns the chip starts in.

const DAYS_IN_WEEK = 7;

function chipBox(container, title) {
  const matches = [...container.querySelectorAll(".rbc-event")].filter(
    (chip) => chip.textContent === title,
  );
  if (matches.length !== 1) {
    throw new Error(`${matches.length} chips say "${title}", not 1`);
  }
  return matches[0].closest(".rbc-row-segment");
}

// How many columns a box covers.
function columns(box) {
  return Math.round((parseFloat(box.style.flexBasis) * DAYS_IN_WEEK) / 100);
}

function columnOf(box) {
  let column = 0;
  for (const before of box.parentElement.children) {
    if (before === box) return column;
    column += columns(before);
  }
  throw new Error("the box is not in its own row");
}

// The day number ("28") above the chip's first column.
export function chipDay(container, title) {
  const box = chipBox(container, title);
  const week = box.closest(".rbc-month-row");
  const cells = week.querySelectorAll(".rbc-date-cell");
  return cells[columnOf(box)].textContent;
}

// The chip's line in its week: 0 for the top line of chips.
export function chipLine(container, title) {
  const box = chipBox(container, title);
  const lines = [
    ...box.closest(".rbc-row-content").querySelectorAll(":scope > .rbc-row"),
  ].slice(1);
  return lines.indexOf(box.parentElement);
}

// The day number of the cell the calendar marks as today.
export function todayCell(container) {
  const marked = container.querySelectorAll(".rbc-date-cell.rbc-now");
  if (marked.length !== 1) {
    throw new Error(`${marked.length} date cells are marked today, not 1`);
  }
  return marked[0].textContent;
}
