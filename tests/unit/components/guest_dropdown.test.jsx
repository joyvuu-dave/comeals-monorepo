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
});
