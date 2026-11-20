import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import CalendarChip, {
  CalendarChipCell,
  spokenDates,
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

// Wall-clock Dates: their UTC fields are the community's wall clock.
describe("the date a screen reader hears", () => {
  it("is part of the link's name", () => {
    renderChip({
      url: "/meals/42/edit",
      start: new Date("2026-01-15T00:01:00Z"),
      end: new Date("2026-01-15T00:01:00Z"),
    });
    expect(
      screen.getByRole("link", { name: "Dinner, Thursday, January 15" }),
    ).toBeInTheDocument();
  });

  it("is left out for an entry with no address", () => {
    renderChip({ start: new Date("2026-01-15T00:01:00Z") });
    expect(screen.queryByText(/January/)).toBeNull();
  });

  it("is nothing for an entry with no start", () => {
    expect(spokenDates(undefined)).toBe("");
    renderChip({ url: "/meals/42/edit" });
    expect(screen.getByRole("link", { name: "Dinner" })).toBeInTheDocument();
  });

  it("is one day for an entry with no end", () => {
    expect(spokenDates(new Date("2026-01-15T19:00:00Z"))).toBe(
      ", Thursday, January 15",
    );
  });

  it("reads the UTC fields, whatever the device's zone", () => {
    // 23:30 on the 15th is the 16th in any zone east of UTC+0:30; the
    // calendar draws it on the 15th, so it must be read on the 15th.
    expect(
      spokenDates(
        new Date("2026-01-15T23:30:00Z"),
        new Date("2026-01-15T23:45:00Z"),
      ),
    ).toBe(", Thursday, January 15");
  });

  it("is a range for a rotation over many days", () => {
    expect(
      spokenDates(
        new Date("2026-01-05T00:01:00Z"),
        new Date("2026-01-17T23:59:00Z"),
      ),
    ).toBe(", Monday, January 5 to Saturday, January 17");
  });

  it("is a range for a booking past midnight", () => {
    expect(
      spokenDates(
        new Date("2026-01-15T22:00:00Z"),
        new Date("2026-01-16T01:00:00Z"),
      ),
    ).toBe(", Thursday, January 15 to Friday, January 16");
  });

  it("is one day for an event that ends at midnight", () => {
    expect(
      spokenDates(
        new Date("2026-01-15T22:00:00Z"),
        new Date("2026-01-16T00:00:00Z"),
      ),
    ).toBe(", Thursday, January 15");
  });
});
