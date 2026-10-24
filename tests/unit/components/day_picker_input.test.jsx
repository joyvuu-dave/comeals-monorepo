import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import DayPickerInput from "../../../app/frontend/src/components/common/day_picker_input.tsx";
import { useDeviceZone } from "../helpers/device_zone.js";
import { pickerButton } from "../helpers/day_picker.js";

// The picker marks the community's today, which it reads in the store.
function renderPicker(props, communityToday = "2026-01-15") {
  return render(
    <StoreContext.Provider value={observable({ communityToday })}>
      <DayPickerInput id="day" {...props} />
    </StoreContext.Provider>,
  );
}

describe("DayPickerInput", () => {
  it("shows the value as MM/DD/YYYY", () => {
    renderPicker({ value: "2026-01-15" });
    expect(screen.getByDisplayValue("01/15/2026")).toBeInTheDocument();
  });

  // A placeholder is only a hint: in the value it would look like a
  // chosen day, and a screen reader would read it as the value.
  it("shows the placeholder as a hint, not as the value, when there is no value", () => {
    renderPicker({ placeholder: "Pick a day" });
    const input = screen.getByPlaceholderText("Pick a day");
    expect(input).toHaveDisplayValue("");
    expect(input).toHaveAttribute("placeholder", "Pick a day");
  });

  it("is empty with no value and no placeholder", () => {
    renderPicker({});
    const input = screen.getByRole("textbox");
    expect(input).toHaveDisplayValue("");
    expect(input).toHaveAttribute("placeholder", "");
  });

  it("opens the picker on click and reports the chosen day", () => {
    const onDayChange = vi.fn();
    renderPicker({ value: "2026-01-15", onDayChange });

    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));
    expect(screen.getByRole("grid")).toBeInTheDocument();

    fireEvent.click(pickerButton(/January 20/));
    expect(onDayChange.mock.calls).toEqual([["2026-01-20"]]);

    // Choosing a day closes the picker.
    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
  });

  it("closes when clicking outside", () => {
    renderPicker({ value: "2026-01-15" });
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));
    expect(screen.getByRole("grid")).toBeInTheDocument();

    fireEvent.mouseDown(document.body);
    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
  });

  it("does not open while disabled", () => {
    renderPicker({ value: "2026-01-15", inputDisabled: true });
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));
    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
  });

  it("stays open on a click inside the picker", () => {
    renderPicker({ value: "2026-01-15" });
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));

    fireEvent.mouseDown(screen.getByRole("grid"));
    expect(screen.getByRole("grid")).toBeInTheDocument();
  });

  it("clicking the chosen day again keeps the date and the picker open", () => {
    const onDayChange = vi.fn();
    renderPicker({ value: "2026-01-15", onDayChange });
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));

    fireEvent.click(pickerButton(/January 15/));
    expect(onDayChange).not.toHaveBeenCalled();
    expect(screen.getByRole("grid")).toBeInTheDocument();
  });

  // Today is the community's, from the store: not the device's, and
  // not UTC's.
  it("marks the community's today", () => {
    renderPicker({ value: "2026-01-15" }, "2026-01-17");
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));

    expect(pickerButton(/^Today, Saturday, January 17th/)).toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: /^Today/ })).toHaveLength(1);
  });

  // A new form has no day yet, and opens on the calendar's month.
  it("opens on the month of defaultMonth when there is no value", () => {
    renderPicker({ defaultMonth: "2026-03-20" });
    fireEvent.click(screen.getByRole("textbox"));

    expect(screen.getByRole("grid", { name: "March 2026" })).toBeVisible();
  });

  it("opens on today's month with no value and no defaultMonth", () => {
    renderPicker({}, "2026-05-02");
    fireEvent.click(screen.getByRole("textbox"));

    expect(screen.getByRole("grid", { name: "May 2026" })).toBeVisible();
  });

  it("offers no day after lastDay", () => {
    renderPicker({ value: "2026-01-15", lastDay: "2026-01-20" });
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));

    expect(pickerButton(/January 20th/)).toBeEnabled();
    expect(pickerButton(/January 21st/)).toBeDisabled();
  });

  // The device's zone cannot move a day (#129). Havana's clocks skip
  // from midnight to 01:00 on Sunday, Mar 8, 2026, so in Havana that day
  // has no midnight. Tokyo is far ahead of UTC, and Honolulu far behind.
  describe.each(["America/Havana", "Asia/Tokyo", "Pacific/Honolulu"])(
    "on a device in %s",
    (zone) => {
      useDeviceZone(zone);

      it("shows each day of March 2026 once, and gives the day chosen", () => {
        const onDayChange = vi.fn();
        renderPicker({ value: "2026-03-08", onDayChange }, "2026-03-08");
        fireEvent.click(screen.getByDisplayValue("03/08/2026"));

        for (let day = 1; day <= 31; day++) {
          expect(
            screen.getAllByRole("button", {
              name: new RegExp(`March ${day}(st|nd|rd|th), 2026`),
            }),
          ).toHaveLength(1);
        }
        expect(
          screen.getByRole("button", {
            name: "Today, Sunday, March 8th, 2026, selected",
          }),
        ).toBeInTheDocument();

        fireEvent.click(pickerButton(/March 9th/));
        expect(onDayChange.mock.calls).toEqual([["2026-03-09"]]);
      });
    },
  );
});
