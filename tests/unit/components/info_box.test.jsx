import { describe, it, expect, vi } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { Provider } from "mobx-react";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import InfoBox from "../../../app/frontend/src/components/meal/info_box.jsx";

// InfoBox renders CloseButton and Extras too, so the stub carries
// their fields as well.
function makeStore(overrides = {}) {
  return observable(
    {
      attendeesCount: 3,
      vegetarianCount: 1,
      lateCount: 2,
      mealLoading: false,
      closedPending: false,
      cooksMissingCost: [],
      meal: {
        closed: false,
        reconciled: false,
        extras: null,
        extrasPending: false,
        setExtras: vi.fn(),
      },
      toggleClosed: vi.fn(),
      ...overrides,
    },
    { toggleClosed: false },
  );
}

// Both providers so the test holds across the inject() → useStore()
// conversion.
function renderBox(store) {
  return render(
    <Provider store={store}>
      <StoreContext.Provider value={store}>
        <InfoBox />
      </StoreContext.Provider>
    </Provider>,
  );
}

describe("InfoBox", () => {
  it("shows the three count circles from the store", () => {
    renderBox(makeStore());
    expect(screen.getByText("Total").parentElement).toHaveTextContent("Total3");
    expect(screen.getByText("Veg").parentElement).toHaveTextContent("Veg1");
    expect(screen.getByText("Late").parentElement).toHaveTextContent("Late2");
  });

  it("updates the counts when the store changes", () => {
    const store = makeStore();
    renderBox(store);

    act(() => {
      runInAction(() => {
        store.attendeesCount = 7;
      });
    });
    expect(screen.getByText("Total").parentElement).toHaveTextContent("Total7");
  });

  it("renders the close button and the extras block", () => {
    renderBox(makeStore());
    expect(
      screen.getByRole("button", { name: "Open / Close Meal" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Extras")).toBeInTheDocument();
  });
});
