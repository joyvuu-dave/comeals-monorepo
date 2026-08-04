import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import ConfirmBar from "../../../app/frontend/src/components/confirm_bar.jsx";

// The popup contract (see the comment in confirm_bar.jsx): the only
// answers are Yes and No, No is focused so Enter is a No, Escape and a
// click anywhere else are a No, and a Yes inside armMs bounces off.
describe("ConfirmBar", () => {
  let onYes;
  let onDismiss;

  beforeEach(() => {
    onYes = vi.fn();
    onDismiss = vi.fn();
  });

  function renderBar(props = {}) {
    return render(
      <ConfirmBar
        question="Erase this?"
        ariaLabel="Erase this?"
        onYes={onYes}
        onDismiss={onDismiss}
        {...props}
      />,
    );
  }

  it("shows the question in an alertdialog", () => {
    renderBar();
    const dialog = screen.getByRole("alertdialog", { name: "Erase this?" });
    expect(dialog).toHaveTextContent("Erase this?");
  });

  it("focuses No, so Enter is a No", () => {
    renderBar();
    expect(screen.getByRole("button", { name: "No" })).toHaveFocus();
  });

  it("Yes calls onYes", () => {
    renderBar();
    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    expect(onYes).toHaveBeenCalledTimes(1);
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it("No calls onDismiss and never onYes", () => {
    renderBar();
    fireEvent.click(screen.getByRole("button", { name: "No" }));
    expect(onDismiss).toHaveBeenCalledTimes(1);
    expect(onYes).not.toHaveBeenCalled();
  });

  it("Escape is a No", () => {
    renderBar();
    fireEvent.keyDown(document, { key: "Escape" });
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it("a click outside the bar is a No", () => {
    renderBar();
    fireEvent.mouseDown(document.body);
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it("a click inside the bar is not a No", () => {
    renderBar();
    fireEvent.mouseDown(screen.getByText("Erase this?"));
    expect(onDismiss).not.toHaveBeenCalled();
  });

  describe("armMs", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("a Yes inside armMs does nothing — the second tap of a double-tap cannot confirm", () => {
      renderBar({ armMs: 400 });
      fireEvent.click(screen.getByRole("button", { name: "Yes" }));
      expect(onYes).not.toHaveBeenCalled();
    });

    it("a Yes after armMs goes through", () => {
      renderBar({ armMs: 400 });
      vi.advanceTimersByTime(401);
      fireEvent.click(screen.getByRole("button", { name: "Yes" }));
      expect(onYes).toHaveBeenCalledTimes(1);
    });
  });
});
