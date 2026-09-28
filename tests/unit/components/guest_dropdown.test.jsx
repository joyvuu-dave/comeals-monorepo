import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import GuestDropdown from "../../../app/frontend/src/components/meal/guest_dropdown.jsx";

function makeResident(overrides = {}) {
  return {
    id: 1,
    name: "Jane Smith",
    addGuest: vi.fn(),
    ...overrides,
  };
}

function renderDropdown(props = {}) {
  return render(
    <GuestDropdown
      resident={makeResident()}
      canAdd={true}
      reconciled={false}
      {...props}
    />,
  );
}

describe("GuestDropdown", () => {
  it("starts closed and opens on click", () => {
    const { container } = renderDropdown();
    const dropdown = container.firstChild;
    expect(dropdown).not.toHaveClass("active");

    fireEvent.click(screen.getByLabelText("Add Guest of Jane Smith"));
    expect(dropdown).toHaveClass("active");
  });

  it("closes on a click outside", () => {
    const { container } = renderDropdown();
    const dropdown = container.firstChild;
    fireEvent.click(screen.getByLabelText("Add Guest of Jane Smith"));
    expect(dropdown).toHaveClass("active");

    fireEvent.mouseDown(document.body);
    expect(dropdown).not.toHaveClass("active");
  });

  it("cow adds a meat guest, carrot a vegetarian one", () => {
    const resident = makeResident();
    renderDropdown({ resident });

    fireEvent.click(screen.getByAltText("cow-icon"));
    expect(resident.addGuest).toHaveBeenCalledWith({ vegetarian: false });

    fireEvent.click(screen.getByAltText("carrot-icon"));
    expect(resident.addGuest).toHaveBeenCalledWith({ vegetarian: true });
  });

  it("disables the button when guests cannot be added", () => {
    renderDropdown({ canAdd: false });
    expect(
      screen.getByLabelText("Add Guest of Jane Smith").closest("button"),
    ).toBeDisabled();
  });

  it("disables the button once the meal is reconciled", () => {
    renderDropdown({ reconciled: true });
    expect(
      screen.getByLabelText("Add Guest of Jane Smith").closest("button"),
    ).toBeDisabled();
  });

  // A Pusher refresh can change the props while the menu is open: the
  // last seat went to someone else, or the meal was reconciled. The
  // open menu closes, stays closed when a seat frees up again, and its
  // cow and carrot add nothing (issue #116).
  it("an open menu closes and adds no guest once guests cannot be added", () => {
    for (const blocked of [{ canAdd: false }, { reconciled: true }]) {
      const resident = makeResident();
      const { container, rerender, unmount } = renderDropdown({ resident });
      fireEvent.click(screen.getByLabelText("Add Guest of Jane Smith"));
      expect(container.firstChild).toHaveClass("active");

      rerender(
        <GuestDropdown
          resident={resident}
          canAdd={true}
          reconciled={false}
          {...blocked}
        />,
      );
      const label = JSON.stringify(blocked);
      expect(container.firstChild, label).not.toHaveClass("active");
      fireEvent.click(screen.getByAltText("cow-icon"));
      fireEvent.click(screen.getByAltText("carrot-icon"));
      expect(resident.addGuest, label).not.toHaveBeenCalled();

      rerender(
        <GuestDropdown resident={resident} canAdd={true} reconciled={false} />,
      );
      expect(container.firstChild, label).not.toHaveClass("active");
      unmount();
    }
  });

  // The wrapper opens the menu on any click, and the disabled button's
  // 1rem right margin belongs to the wrapper, so a tap just beside the
  // grayed-out button reached it.
  it("the menu does not open while guests cannot be added", () => {
    for (const blocked of [{ canAdd: false }, { reconciled: true }]) {
      const { container, unmount } = renderDropdown(blocked);
      fireEvent.click(container.firstChild);
      expect(container.firstChild, JSON.stringify(blocked)).not.toHaveClass(
        "active",
      );
      unmount();
    }
  });

  it("stays open on a click inside the menu", () => {
    const { container } = renderDropdown();
    const dropdown = container.firstChild;
    fireEvent.click(screen.getByLabelText("Add Guest of Jane Smith"));

    fireEvent.mouseDown(screen.getByAltText("cow-icon"));
    expect(dropdown).toHaveClass("active");
  });
});
