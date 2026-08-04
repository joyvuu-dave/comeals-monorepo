import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { Provider } from "mobx-react";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import Extras from "../../../app/frontend/src/components/meal/extras.jsx";

// The `setExtras: false` annotation stops MobX from wrapping the spy
// in an action, which would hide it from toHaveBeenCalled.
function makeStore(mealOverrides = {}) {
  const meal = observable(
    {
      closed: true,
      reconciled: false,
      extras: null,
      extrasPending: false,
      setExtras: vi.fn(),
      ...mealOverrides,
    },
    { setExtras: false },
  );
  return observable({ meal });
}

// Both providers so the test holds across the inject() → useStore()
// conversion.
function renderExtras(store) {
  return render(
    <Provider store={store}>
      <StoreContext.Provider value={store}>
        <Extras />
      </StoreContext.Provider>
    </Provider>,
  );
}

describe("Extras", () => {
  it("shows radio buttons 0 through 8 on a closed meal", () => {
    renderExtras(makeStore());
    for (let val = 0; val <= 8; val++) {
      expect(screen.getByLabelText(`Set Extras to ${val}`)).toBeInTheDocument();
    }
  });

  it("checks the box matching the meal's extras", () => {
    renderExtras(makeStore({ extras: 3 }));
    expect(screen.getByLabelText("Set Extras to 3")).toBeChecked();
    expect(screen.getByLabelText("Set Extras to 2")).not.toBeChecked();
  });

  it("clicking a box calls setExtras with its value", () => {
    const store = makeStore();
    renderExtras(store);
    fireEvent.click(screen.getByLabelText("Set Extras to 5"));
    expect(store.meal.setExtras).toHaveBeenCalledWith("5");
  });

  it("disables the boxes once the meal is reconciled", () => {
    renderExtras(makeStore({ reconciled: true }));
    expect(screen.getByLabelText("Set Extras to 1")).toBeDisabled();
  });

  it("disables the boxes while an extras save is pending", () => {
    renderExtras(makeStore({ extrasPending: true }));
    expect(screen.getByLabelText("Set Extras to 1")).toBeDisabled();
  });
});
