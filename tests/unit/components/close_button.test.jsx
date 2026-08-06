import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import CloseButton from "../../../app/frontend/src/components/meal/close_button.jsx";

function makeStore(overrides = {}) {
  return observable(
    {
      mealLoading: false,
      closedPending: false,
      cooksMissingCost: [],
      meal: { closed: false, reconciled: false },
      toggleClosed: vi.fn(),
      ...overrides,
    },
    { toggleClosed: false },
  );
}

function renderButton(store) {
  return render(
    <StoreContext.Provider value={store}>
      <CloseButton />
    </StoreContext.Provider>,
  );
}

describe("CloseButton", () => {
  it("is green while the meal is open, red once closed", () => {
    const store = makeStore();
    renderButton(store);
    const button = screen.getByRole("button", { name: "Open / Close Meal" });
    expect(button).toHaveClass("button-success");

    act(() => {
      runInAction(() => {
        store.meal.closed = true;
      });
    });
    expect(button).toHaveClass("button-danger");
  });

  it("closes right away when every cook has a cost", () => {
    const store = makeStore();
    renderButton(store);
    fireEvent.click(screen.getByRole("button", { name: "Open / Close Meal" }));
    expect(store.toggleClosed).toHaveBeenCalledTimes(1);
  });

  it("asks first when a cook's cost is blank", () => {
    const store = makeStore({ cooksMissingCost: ["Bob Johnson"] });
    renderButton(store);
    fireEvent.click(screen.getByRole("button", { name: "Open / Close Meal" }));

    expect(store.toggleClosed).not.toHaveBeenCalled();
    expect(
      screen.getByText(/hasn’t entered a cost yet\. Close the meal anyway\?/),
    ).toBeInTheDocument();
  });

  it("Yes on the confirm closes the meal", () => {
    const store = makeStore({ cooksMissingCost: ["Bob Johnson"] });
    renderButton(store);
    fireEvent.click(screen.getByRole("button", { name: "Open / Close Meal" }));

    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    expect(store.toggleClosed).toHaveBeenCalledTimes(1);
  });

  it("is disabled once the meal is reconciled", () => {
    const store = makeStore({ meal: { closed: true, reconciled: true } });
    renderButton(store);
    expect(
      screen.getByRole("button", { name: "Open / Close Meal" }),
    ).toBeDisabled();
  });
});
