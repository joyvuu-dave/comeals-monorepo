import { screen } from "@testing-library/react";

// A button of the open day picker (common/day_picker_input.tsx): a day,
// or "Go to the Next Month" and "Go to the Previous Month". react-day-
// picker gives each of them an aria-label, so they are found by it.
//
// Not getByRole("button", { name }): to find one button that way,
// Testing Library works out the accessible name of every button on the
// page, and an open picker has more than 40. In jsdom that costs about
// 35 ms after each change to the page, so a test that moves the picker
// six months spent most of its half second there. With six Vitest runs
// at once, such tests went past Vitest's limit of 5 seconds (#247).
// This query reads one attribute per element.
export function pickerButton(label) {
  return screen.getByLabelText(label, { selector: "button" });
}
