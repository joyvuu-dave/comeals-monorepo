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
      frozen={false}
      addWaiting={false}
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

  it("disables the button once the meal is settled or cancelled", () => {
    renderDropdown({ frozen: true });
    expect(
      screen.getByLabelText("Add Guest of Jane Smith").closest("button"),
    ).toBeDisabled();
  });

  // A Pusher refresh can change the props while the menu is open: the
  // last seat went to someone else, or the meal was settled or cancelled. The
  // open menu closes, stays closed when a seat frees up again, and its
  // cow and carrot add nothing (issue #116).
  it("an open menu closes and adds no guest once guests cannot be added", () => {
    for (const blocked of [{ canAdd: false }, { frozen: true }]) {
      const resident = makeResident();
      const { container, rerender, unmount } = renderDropdown({ resident });
      fireEvent.click(screen.getByLabelText("Add Guest of Jane Smith"));
      expect(container.firstChild).toHaveClass("active");

      rerender(
        <GuestDropdown
          resident={resident}
          canAdd={true}
          frozen={false}
          {...blocked}
        />,
      );
      const label = JSON.stringify(blocked);
      expect(container.firstChild, label).not.toHaveClass("active");
      fireEvent.click(screen.getByAltText("cow-icon"));
      fireEvent.click(screen.getByAltText("carrot-icon"));
      expect(resident.addGuest, label).not.toHaveBeenCalled();

      rerender(
        <GuestDropdown resident={resident} canAdd={true} frozen={false} />,
      );
      expect(container.firstChild, label).not.toHaveClass("active");
      unmount();
    }
  });

  // The wrapper opens the menu on any click, and the disabled button's
  // 1rem right margin belongs to the wrapper, so a tap just beside the
  // grayed-out button reached it.
  it("the menu does not open while guests cannot be added", () => {
    for (const blocked of [{ canAdd: false }, { frozen: true }]) {
      const { container, unmount } = renderDropdown(blocked);
      fireEvent.click(container.firstChild);
      expect(container.firstChild, JSON.stringify(blocked)).not.toHaveClass(
        "active",
      );
      unmount();
    }
  });

  // The host's guest add is waiting for its answer (S4). A second tap
  // would send a second guest. The button keeps its look: the gray
  // disabled look says no guest can be added, which is not so.
  it("takes no taps while the host's guest add waits, and keeps its look", () => {
    const resident = makeResident();
    const { container } = renderDropdown({ resident, addWaiting: true });
    const button = screen
      .getByLabelText("Add Guest of Jane Smith")
      .closest("button");

    fireEvent.click(button);
    expect(container.firstChild).not.toHaveClass("active");
    fireEvent.click(screen.getByAltText("cow-icon"));
    fireEvent.click(screen.getByAltText("carrot-icon"));
    expect(resident.addGuest).not.toHaveBeenCalled();
    expect(button).toBeEnabled();
    expect(button).toHaveAttribute("aria-disabled", "true");
  });

  it("tells screen readers the button takes taps while nothing waits", () => {
    renderDropdown();
    expect(
      screen.getByLabelText("Add Guest of Jane Smith").closest("button"),
    ).toHaveAttribute("aria-disabled", "false");
  });

  it("stays open on a click inside the menu", () => {
    const { container } = renderDropdown();
    const dropdown = container.firstChild;
    fireEvent.click(screen.getByLabelText("Add Guest of Jane Smith"));

    fireEvent.mouseDown(screen.getByAltText("cow-icon"));
    expect(dropdown).toHaveClass("active");
  });

  // Keyboard use (challenge 32; tests/e2e/keyboard.spec.js drives the
  // same in a browser).
  describe("with the keyboard", () => {
    function openMenu() {
      const { container } = renderDropdown();
      const toggle = screen.getByRole("button", {
        name: "Add Guest of Jane Smith",
      });
      fireEvent.click(toggle);
      return { dropdown: container.firstChild, toggle };
    }

    it("says on + Guest whether the menu is open", () => {
      const { toggle } = openMenu();
      expect(toggle).toHaveAttribute("aria-expanded", "true");
      fireEvent.click(toggle);
      expect(toggle).toHaveAttribute("aria-expanded", "false");
    });

    it("names each menu item for a screen reader", () => {
      renderDropdown();
      expect(
        screen.getByRole("button", {
          name: "Add a guest of Jane Smith who eats meat",
        }),
      ).toBeInTheDocument();
      expect(
        screen.getByRole("button", {
          name: "Add a vegetarian guest of Jane Smith",
        }),
      ).toBeInTheDocument();
    });

    it("Escape closes the menu and puts the focus on + Guest", () => {
      const { dropdown, toggle } = openMenu();
      const veg = screen.getByRole("button", {
        name: "Add a vegetarian guest of Jane Smith",
      });
      veg.focus();
      fireEvent.keyDown(veg, { key: "Escape" });
      expect(dropdown).not.toHaveClass("active");
      expect(toggle).toHaveFocus();
    });

    it("Escape with the menu closed does nothing", () => {
      const { container } = renderDropdown();
      const toggle = screen.getByRole("button", {
        name: "Add Guest of Jane Smith",
      });
      const outside = document.createElement("button");
      document.body.append(outside);
      outside.focus();
      fireEvent.keyDown(toggle, { key: "Escape" });
      expect(container.firstChild).not.toHaveClass("active");
      expect(outside).toHaveFocus();
      outside.remove();
    });

    it("another key leaves the menu open", () => {
      const { dropdown, toggle } = openMenu();
      fireEvent.keyDown(toggle, { key: "a" });
      expect(dropdown).toHaveClass("active");
    });

    it("adding a guest puts the focus back on + Guest", () => {
      const { toggle } = openMenu();
      fireEvent.click(
        screen.getByRole("button", {
          name: "Add a guest of Jane Smith who eats meat",
        }),
      );
      expect(toggle).toHaveFocus();
    });

    it("closes when the focus moves to an element outside it", () => {
      const { dropdown, toggle } = openMenu();
      const outside = document.createElement("button");
      document.body.append(outside);
      fireEvent.blur(toggle, { relatedTarget: outside });
      expect(dropdown).not.toHaveClass("active");
      outside.remove();
    });

    it("stays open when the focus moves to a menu item", () => {
      const { dropdown, toggle } = openMenu();
      fireEvent.blur(toggle, {
        relatedTarget: screen.getByRole("button", {
          name: "Add a vegetarian guest of Jane Smith",
        }),
      });
      expect(dropdown).toHaveClass("active");
    });

    // Safari does not focus a clicked button, so a click on a menu item
    // can blur + Guest with no element to go to. Closing then would
    // hide the item before the click reached it.
    it("stays open when the focus goes to no element", () => {
      const { dropdown, toggle } = openMenu();
      fireEvent.blur(toggle, { relatedTarget: null });
      expect(dropdown).toHaveClass("active");
    });
  });
});
