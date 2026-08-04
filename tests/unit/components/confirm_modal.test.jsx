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

describe("ConfirmModal", () => {
  it("renders nothing while closed", () => {
    render(
      <ConfirmModal
        isOpen={false}
        message="Really delete?"
        onCancel={vi.fn()}
        onConfirm={vi.fn()}
      />,
    );
    expect(screen.queryByText("Really delete?")).not.toBeInTheDocument();
  });

  it("shows the message with Cancel and Delete buttons", () => {
    render(
      <ConfirmModal
        isOpen={true}
        message="Really delete?"
        onCancel={vi.fn()}
        onConfirm={vi.fn()}
      />,
    );
    expect(screen.getByText("Really delete?")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Delete" })).toBeInTheDocument();
  });

  it("Cancel calls onCancel, Delete calls onConfirm", () => {
    const onCancel = vi.fn();
    const onConfirm = vi.fn();
    render(
      <ConfirmModal
        isOpen={true}
        message="Really delete?"
        onCancel={onCancel}
        onConfirm={onConfirm}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(onConfirm).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });
});
