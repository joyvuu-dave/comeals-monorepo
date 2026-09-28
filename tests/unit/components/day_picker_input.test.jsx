import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import DayPickerInput from "../../../app/frontend/src/components/common/day_picker_input.jsx";

describe("DayPickerInput", () => {
  it("shows the value as MM/DD/YYYY", () => {
    render(<DayPickerInput id="day" value="2026-01-15" />);
    expect(screen.getByDisplayValue("01/15/2026")).toBeInTheDocument();
  });

  // A placeholder is only a hint: in the value it would look like a
  // chosen day, and a screen reader would read it as the value.
  it("shows the placeholder as a hint, not as the value, when there is no value", () => {
    render(<DayPickerInput id="day" placeholder="Pick a day" />);
    const input = screen.getByPlaceholderText("Pick a day");
    expect(input).toHaveDisplayValue("");
    expect(input).toHaveAttribute("placeholder", "Pick a day");
  });

  it("is empty with no value and no placeholder", () => {
    render(<DayPickerInput id="day" />);
    const input = screen.getByRole("textbox");
    expect(input).toHaveDisplayValue("");
    expect(input).toHaveAttribute("placeholder", "");
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

  it("stays open on a click inside the picker", () => {
    render(<DayPickerInput id="day" value="2026-01-15" />);
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));

    fireEvent.mouseDown(screen.getByRole("grid"));
    expect(screen.getByRole("grid")).toBeInTheDocument();
  });

  it("clicking the chosen day again keeps the date and the picker open", () => {
    const onDayChange = vi.fn();
    render(
      <DayPickerInput id="day" value="2026-01-15" onDayChange={onDayChange} />,
    );
    fireEvent.click(screen.getByDisplayValue("01/15/2026"));

    fireEvent.click(screen.getByRole("button", { name: /January 15/ }));
    expect(onDayChange).not.toHaveBeenCalled();
    expect(screen.getByRole("grid")).toBeInTheDocument();
  });
});
