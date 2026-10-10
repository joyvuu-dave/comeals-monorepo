import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import watchDialogFocus from "../../../app/frontend/src/helpers/watch_dialog_focus";

// react-modal listens for Escape only on the dialog itself, so Escape
// closes a dialog only while focus is inside it. Focus moves to the
// page's <body> when the element that has it is removed, and in Chrome
// also when it is disabled (#148, #152). The watcher puts focus back
// on the dialog then.
describe("watchDialogFocus", () => {
  let dialog;
  let field;
  let button;

  beforeEach(() => {
    dialog = document.createElement("div");
    dialog.tabIndex = -1;
    field = document.createElement("input");
    button = document.createElement("button");
    dialog.append(field, button);
    document.body.append(dialog);
    watchDialogFocus(dialog);
  });

  afterEach(() => {
    vi.useRealTimers();
    dialog.remove();
  });

  // Chrome takes focus off a control that turns disabled, and the event
  // it sends is the same as for a blur.
  it("puts focus back on the dialog when a control loses it to the page", async () => {
    field.focus();

    field.blur();
    expect(document.body).toHaveFocus();

    await vi.waitFor(() => expect(dialog).toHaveFocus());
  });

  // WebKit, like jsdom, sends no event when the element that has focus
  // is removed.
  it("puts focus back on the dialog when the control that had it is removed", async () => {
    button.focus();

    button.remove();
    expect(document.body).toHaveFocus();

    await vi.waitFor(() => expect(dialog).toHaveFocus());
  });

  // While focusout runs, <body> has focus even when focus is moving to
  // another element, so the check waits until the move is done.
  it("leaves focus on the control it moved to", () => {
    vi.useFakeTimers();
    field.focus();

    button.focus();
    vi.runAllTimers();

    expect(button).toHaveFocus();
  });

  // react-modal calls it with null when the dialog closes.
  it("does nothing when the dialog closes", () => {
    expect(() => watchDialogFocus(null)).not.toThrow();
  });
});
