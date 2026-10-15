import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import CancelButton from "../../../app/frontend/src/components/meal/cancel_button.tsx";

// Cancel and Restore on the meal page (ADR 0011 rule 11). The store's
// setCancelled is a spy: what it sends is tested in meal_page.test.js.
// The spy annotations stop MobX from wrapping them in actions, which
// would hide them from toHaveBeenCalled.
function makeStore(overrides = {}) {
  return observable(
    {
      mealLoading: false,
      cancelledPending: false,
      meal: { id: 42, date: "2026-01-15", reconciled: false, cancelled: false },
      billsPendingFor: vi.fn(() => false),
      setCancelled: vi.fn(),
      ...overrides,
    },
    { billsPendingFor: false, setCancelled: false },
  );
}

function renderButton(store) {
  return render(
    <StoreContext.Provider value={store}>
      <CancelButton />
    </StoreContext.Provider>,
  );
}

const cancelButton = () =>
  screen.getByRole("button", { name: "Cancel this dinner" });
const restoreButton = () =>
  screen.getByRole("button", { name: "Restore this dinner" });
const question = () => screen.queryByRole("alertdialog");

function change(fn) {
  act(() => {
    runInAction(fn);
  });
}

describe("CancelButton", () => {
  it("asks before it cancels, and a No sends nothing", () => {
    const store = makeStore();
    renderButton(store);
    expect(cancelButton()).toHaveTextContent(/^Cancel$/);

    fireEvent.click(cancelButton());
    expect(question()).toHaveAccessibleName("Cancel this dinner?");
    expect(question()).toHaveTextContent(
      "Sign-ups stay, and nobody is charged. It can be restored until it is settled.",
    );
    fireEvent.click(screen.getByRole("button", { name: "No" }));
    expect(question()).not.toBeInTheDocument();
    expect(store.setCancelled).not.toHaveBeenCalled();

    fireEvent.click(cancelButton());
    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    expect(question()).not.toBeInTheDocument();
    expect(store.setCancelled).toHaveBeenCalledExactlyOnceWith(42, true);
  });

  it("offers Restore on a cancelled dinner, and asks before it restores", () => {
    const store = makeStore({
      meal: { id: 42, date: "2026-01-15", reconciled: false, cancelled: true },
    });
    renderButton(store);
    expect(restoreButton()).toHaveTextContent(/^Restore$/);

    fireEvent.click(restoreButton());
    expect(question()).toHaveAccessibleName("Restore this dinner?");
    expect(question()).toHaveTextContent(
      "Sign-ups, guests and costs can change again.",
    );
    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    expect(store.setCancelled).toHaveBeenCalledExactlyOnceWith(42, false);
  });

  it("shows nothing on a settled dinner, cancelled or not, or before a meal's data arrives", () => {
    for (const meal of [
      { id: 42, date: "2026-01-15", reconciled: true, cancelled: false },
      { id: 42, date: "2026-01-15", reconciled: true, cancelled: true },
      { id: 42, date: null, reconciled: false, cancelled: false },
      null,
    ]) {
      const { container, unmount } = renderButton(makeStore({ meal }));
      expect(container, JSON.stringify(meal)).toBeEmptyDOMElement();
      unmount();
    }
  });

  it("takes no tap while the meal loads or a Cancel or Restore is on its way", () => {
    for (const flags of [{ mealLoading: true }, { cancelledPending: true }]) {
      const { unmount } = renderButton(makeStore(flags));
      expect(cancelButton(), JSON.stringify(flags)).toBeDisabled();
      unmount();
    }
  });

  // A cost typed on the page waits 2 seconds before its save. The
  // Cancel waits for that save, so the server sees the cost first.
  // Restore has nothing to wait for: a cancelled dinner's costs can't be
  // typed.
  it("waits for a cost save on this meal before it can cancel", () => {
    const store = makeStore({ billsPendingFor: vi.fn((id) => id === 42) });
    const { unmount } = renderButton(store);
    expect(cancelButton()).toBeDisabled();
    unmount();

    store.meal.cancelled = true;
    renderButton(store);
    expect(restoreButton()).toBeEnabled();
  });

  // The Yes sends what the question asked, so the question must go once
  // it is about something already done or not on screen. Coming back
  // must not bring it back: nobody asked it about the new state.
  it("closes the question for good when a live update cancels the dinner first", () => {
    const store = makeStore();
    renderButton(store);
    fireEvent.click(cancelButton());
    expect(question()).toBeInTheDocument();

    change(() => {
      store.meal.cancelled = true;
    });
    expect(question()).not.toBeInTheDocument();
    expect(restoreButton()).toBeInTheDocument();

    change(() => {
      store.meal.cancelled = false;
    });
    expect(question()).not.toBeInTheDocument();
  });

  it("closes the question for good when the dinner is settled under it", () => {
    const store = makeStore();
    const { container } = renderButton(store);
    fireEvent.click(cancelButton());

    change(() => {
      store.meal.reconciled = true;
    });
    expect(container).toBeEmptyDOMElement();

    change(() => {
      store.meal.reconciled = false;
    });
    expect(question()).not.toBeInTheDocument();
  });

  it("closes the question for good when the page moves to another meal", () => {
    const store = makeStore();
    renderButton(store);
    fireEvent.click(cancelButton());
    const first = store.meal;

    change(() => {
      store.meal = {
        id: 43,
        date: "2026-01-16",
        reconciled: false,
        cancelled: false,
      };
    });
    expect(question()).not.toBeInTheDocument();

    change(() => {
      store.meal = first;
    });
    expect(question()).not.toBeInTheDocument();
    expect(store.setCancelled).not.toHaveBeenCalled();
  });
});
