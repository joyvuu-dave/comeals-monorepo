import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

// confirm_modal.jsx calls Modal.setAppElement("#root") at import time,
// so the element must exist before the import runs.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

import ConfirmModal from "../../../app/frontend/src/components/app/confirm_modal.jsx";

function renderModal(props = {}) {
  const onCancel = vi.fn();
  const onConfirm = vi.fn();
  render(
    <ConfirmModal
      isOpen={true}
      message="Really delete?"
      cancelLabel="Cancel"
      confirmLabel="Delete"
      onCancel={onCancel}
      onConfirm={onConfirm}
      {...props}
    />,
  );
  return { onCancel, onConfirm };
}

describe("ConfirmModal", () => {
  it("renders nothing while closed", () => {
    renderModal({ isOpen: false });
    expect(screen.queryByText("Really delete?")).not.toBeInTheDocument();
  });

  it("shows the message with the labels it was given", () => {
    renderModal({ cancelLabel: "Keep editing", confirmLabel: "Discard" });
    expect(screen.getByText("Really delete?")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Keep editing" }),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Discard" })).toBeInTheDocument();
  });

  it("the cancel button calls onCancel, the confirm button onConfirm", () => {
    const { onCancel, onConfirm } = renderModal();

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(onConfirm).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  // The popup contract (see confirm_bar.jsx): the safe answer takes
  // focus, so Enter is a no.
  it("focuses the cancel button when it opens", () => {
    renderModal();
    expect(screen.getByRole("button", { name: "Cancel" })).toHaveFocus();
  });

  it("Escape is a no", () => {
    const { onCancel, onConfirm } = renderModal();
    fireEvent.keyDown(screen.getByRole("dialog"), {
      key: "Escape",
      keyCode: 27,
    });
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(onConfirm).not.toHaveBeenCalled();
  });

  describe("armMs", () => {
    it("a confirm inside armMs does nothing — the second tap of a double-tap cannot confirm", () => {
      const { onConfirm } = renderModal({ armMs: 400 });
      fireEvent.click(screen.getByRole("button", { name: "Delete" }));
      expect(onConfirm).not.toHaveBeenCalled();
    });

    it("a confirm after armMs goes through", () => {
      const { onConfirm } = renderModal({ armMs: 400 });
      const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 1000);
      fireEvent.click(screen.getByRole("button", { name: "Delete" }));
      nowSpy.mockRestore();
      expect(onConfirm).toHaveBeenCalledTimes(1);
    });

    it("cancel is never delayed", () => {
      const { onCancel } = renderModal({ armMs: 400 });
      fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
      expect(onCancel).toHaveBeenCalledTimes(1);
    });
  });
});
