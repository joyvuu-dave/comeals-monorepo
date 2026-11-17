import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import CalendarChip, {
  CalendarChipCell,
} from "../../../app/frontend/src/components/calendar/calendar_chip.tsx";

// The chip inside react-big-calendar's entry div. The entry's own
// onClick opens the entry (calendar/show.jsx); here a plain div stands
// in for it.
function renderChip(event) {
  const onEntryClick = vi.fn();
  render(
    <MemoryRouter>
      <div onClick={onEntryClick}>
        <CalendarChip event={event} title="Dinner" />
      </div>
    </MemoryRouter>,
  );
  return onEntryClick;
}

describe("CalendarChip", () => {
  it("draws an entry with an address as a link to it", () => {
    renderChip({ url: "/meals/42/edit" });
    expect(screen.getByRole("link", { name: "Dinner" })).toHaveAttribute(
      "href",
      "/meals/42/edit",
    );
  });

  it("draws an entry with no address (a birthday) as plain text", () => {
    renderChip({});
    expect(screen.queryByRole("link")).toBeNull();
    expect(screen.getByText("Dinner")).toBeInTheDocument();
  });

  it("leaves a plain click to the entry, which opens it", () => {
    const onEntryClick = renderChip({ url: "/meals/42/edit" });
    const click = fireEvent.click(screen.getByRole("link"));
    // false: the link stopped the browser from following it itself.
    expect(click).toBe(false);
    expect(onEntryClick).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["Cmd", { metaKey: true }],
    ["Ctrl", { ctrlKey: true }],
    ["Shift", { shiftKey: true }],
    ["Option", { altKey: true }],
    ["the middle button", { button: 1 }],
  ])(
    "leaves a click with %s to the browser, and the calendar stays",
    (_, options) => {
      const onEntryClick = renderChip({ url: "/meals/42/edit" });
      fireEvent.click(screen.getByRole("link"), options);
      expect(onEntryClick).not.toHaveBeenCalled();
    },
  );
});

describe("CalendarChipCell", () => {
  it("wraps the entry in a table cell", () => {
    render(
      <div role="row">
        <CalendarChipCell>
          <span>Dinner</span>
        </CalendarChipCell>
      </div>,
    );
    expect(screen.getByRole("cell", { name: "Dinner" })).toBeInTheDocument();
  });
});
