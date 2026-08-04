import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { Provider } from "mobx-react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";
import LoadStatus from "../../../app/frontend/src/components/meal/load_status.jsx";

// The `retryMealLoadNow: false` annotation stops MobX from wrapping the
// spy in an action, which would hide it from toHaveBeenCalled.
function makeStore(overrides = {}) {
  return observable(
    {
      mealLoadFailed: false,
      mealLoadNotFound: false,
      retryMealLoadNow: vi.fn(),
      ...overrides,
    },
    { retryMealLoadNow: false },
  );
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

function renderStatus(store) {
  return render(
    <Provider store={store}>
      <MemoryRouter initialEntries={["/meals/5/edit"]}>
        <LoadStatus />
        <Routes>
          <Route path="*" element={<LocationEcho />} />
        </Routes>
      </MemoryRouter>
    </Provider>,
  );
}

describe("LoadStatus", () => {
  it("renders nothing while the meal loads normally", () => {
    renderStatus(makeStore());
    expect(screen.queryByRole("status")).not.toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("a retryable failure says it is retrying and offers Retry now", () => {
    const store = makeStore({ mealLoadFailed: true });
    renderStatus(store);

    const bar = screen.getByRole("status");
    expect(bar).toHaveTextContent("Trouble loading this meal. Retrying…");

    fireEvent.click(screen.getByRole("button", { name: "Retry now" }));
    expect(store.retryMealLoadNow).toHaveBeenCalledTimes(1);
  });

  it("a 404 is permanent: an alert with a way back, no retry", () => {
    renderStatus(makeStore({ mealLoadNotFound: true }));

    const bar = screen.getByRole("alert");
    expect(bar).toHaveTextContent("This meal could not be found.");
    expect(
      screen.queryByRole("button", { name: "Retry now" }),
    ).not.toBeInTheDocument();
  });

  it("Back to calendar leaves the dead meal page", () => {
    renderStatus(makeStore({ mealLoadNotFound: true }));
    fireEvent.click(screen.getByRole("button", { name: "Back to calendar" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/calendar\/all\/\d{4}-\d{2}-\d{2}$/,
    );
  });

  it("appears when a load fails after mount", () => {
    const store = makeStore();
    renderStatus(store);
    expect(screen.queryByRole("status")).not.toBeInTheDocument();

    act(() => {
      runInAction(() => {
        store.mealLoadFailed = true;
      });
    });
    expect(screen.getByRole("status")).toBeInTheDocument();
  });
});
