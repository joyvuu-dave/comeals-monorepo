import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import DayPickerInput from "../../../app/frontend/src/components/common/day_picker_input.jsx";

describe("DayPickerInput", () => {
  it("shows the value as MM/DD/YYYY", () => {
    render(<DayPickerInput id="day" value="2026-01-15" />);
    expect(screen.getByDisplayValue("01/15/2026")).toBeInTheDocument();
  });

  it("shows the placeholder text when there is no value", () => {
    // The component puts the placeholder into the input's value, not
    // only the placeholder attribute. Pinned as-is.
    render(<DayPickerInput id="day" placeholder="Pick a day" />);
    expect(screen.getByPlaceholderText("Pick a day")).toHaveDisplayValue(
      "Pick a day",
    );
  });

  it("opens the picker on click and reports the chosen day", () => {
    const onDayChange = vi.fn();
    render(
      <DayPickerInput id="day" value="2026-01-15" onDayChange={onDayChange} />,
    );

    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));
    expect(screen.getByRole("grid")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /January 20/ }));
    expect(onDayChange).toHaveBeenCalledTimes(1);
    const chosen = onDayChange.mock.calls[0][0];
    expect(chosen).toBeInstanceOf(Date);
    expect(chosen.getDate()).toBe(20);

    // Choosing a day closes the picker.
    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
  });

  it("closes when clicking outside", () => {
    render(<DayPickerInput id="day" value="2026-01-15" />);
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));
    expect(screen.getByRole("grid")).toBeInTheDocument();

    fireEvent.mouseDown(document.body);
    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
  });

  it("does not open while disabled", () => {
    render(<DayPickerInput id="day" value="2026-01-15" inputDisabled={true} />);
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));
    expect(screen.queryByRole("grid")).not.toBeInTheDocument();
  });
});
