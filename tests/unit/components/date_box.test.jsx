import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

// date_box.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { MEAL_EDIT_PATH } from "../../../app/frontend/src/routes.js";
import DateBox from "../../../app/frontend/src/components/meal/date_box.jsx";

// index.jsx registers this plugin at app startup; the "Do" ordinal in
// the top date needs it.
dayjs.extend(advancedFormat);

// The spy annotations stop MobX from wrapping them in actions, which
// would hide them from toHaveBeenCalled.
function makeStore(overrides = {}) {
  return observable(
    {
      mealLoading: false,
      communityToday: "2026-01-15",
      meal: {
        id: 42,
        date: new Date(2026, 0, 15),
        prevId: 41,
        nextId: 43,
        closed: false,
        reconciled: false,
      },
      goToMeal: vi.fn(),
      teardownCalendarPage: vi.fn(),
      ...overrides,
    },
    { goToMeal: false, teardownCalendarPage: false },
  );
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

function renderBox(store, path = "/meals/42/edit/") {
  return render(
    <StoreContext.Provider value={store}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path={MEAL_EDIT_PATH} element={<DateBox />} />
        </Routes>
        <LocationEcho />
      </MemoryRouter>
    </StoreContext.Provider>,
  );
}

describe("DateBox", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("tears down the calendar and loads the meal from the URL on mount", () => {
    const store = makeStore();
    renderBox(store);
    expect(store.teardownCalendarPage).toHaveBeenCalledTimes(1);
    expect(store.goToMeal).toHaveBeenCalledWith("42");
  });

  it("shows the meal date, Today, and the OPEN state", () => {
    renderBox(makeStore());
    expect(screen.getByText("Thu, Jan 15th")).toBeInTheDocument();
    expect(screen.getByText("Today")).toBeInTheDocument();
    expect(screen.getByText("OPEN")).toBeInTheDocument();
  });

  it("shows CLOSED and RECONCILED states", () => {
    const store = makeStore();
    store.meal.closed = true;
    const { unmount } = renderBox(store);
    expect(screen.getByText("CLOSED")).toBeInTheDocument();
    unmount();

    const reconciled = makeStore();
    reconciled.meal.closed = true;
    reconciled.meal.reconciled = true;
    renderBox(reconciled);
    expect(screen.getByText("RECONCILED")).toBeInTheDocument();
  });

  it("the arrows navigate to the neighbor meals", () => {
    renderBox(makeStore());
    fireEvent.click(screen.getByRole("button", { name: "Next meal" }));
    expect(screen.getByTestId("location")).toHaveTextContent("/meals/43/edit");
  });

  it("a null neighbor id never navigates", () => {
    const store = makeStore();
    store.meal.prevId = null;
    renderBox(store);
    const prev = screen.getByRole("button", { name: "Previous meal" });
    expect(prev).toHaveAttribute("aria-disabled", "true");
    fireEvent.click(prev);
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/meals\/42\/edit\/$/,
    );
  });

  it("opens the history modal on the history path", () => {
    renderBox(makeStore(), "/meals/42/edit/history/");
    expect(screen.getByLabelText("History Modal")).toBeInTheDocument();
  });

  it("the previous arrow navigates back, and a null next id never navigates", () => {
    const store = makeStore();
    store.meal.nextId = null;
    renderBox(store);

    fireEvent.click(screen.getByRole("button", { name: "Next meal" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/meals\/42\/edit\/$/,
    );

    fireEvent.click(screen.getByRole("button", { name: "Previous meal" }));
    expect(screen.getByTestId("location")).toHaveTextContent("/meals/41/edit");
  });

  it("the arrows answer Enter and Space, and no other key", () => {
    renderBox(makeStore());
    const next = screen.getByRole("button", { name: "Next meal" });
    const prev = screen.getByRole("button", { name: "Previous meal" });

    fireEvent.keyDown(next, { key: "a" });
    fireEvent.keyDown(prev, { key: "a" });
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/meals\/42\/edit\/$/,
    );

    fireEvent.keyDown(next, { key: "Enter" });
    expect(screen.getByTestId("location")).toHaveTextContent("/meals/43/edit");
    fireEvent.keyDown(prev, { key: " " });
    expect(screen.getByTestId("location")).toHaveTextContent("/meals/41/edit");
  });

  // A mousedown on an arrow must not move focus off whatever is being
  // edited, so the arrow swallows it.
  it("a mousedown on an arrow is swallowed", () => {
    renderBox(makeStore());
    const swallowed = !fireEvent.mouseDown(
      screen.getByRole("button", { name: "Next meal" }),
    );
    expect(swallowed).toBe(true);
    const swallowedPrev = !fireEvent.mouseDown(
      screen.getByRole("button", { name: "Previous meal" }),
    );
    expect(swallowedPrev).toBe(true);
  });

  it("says Yesterday and Tomorrow for the neighbor days", () => {
    const yesterday = makeStore();
    yesterday.meal.date = new Date(2026, 0, 14);
    const { unmount } = renderBox(yesterday);
    expect(screen.getByText("Yesterday")).toBeInTheDocument();
    unmount();

    const tomorrow = makeStore();
    tomorrow.meal.date = new Date(2026, 0, 16);
    renderBox(tomorrow);
    expect(screen.getByText("Tomorrow")).toBeInTheDocument();
  });

  it("Escape closes the history modal back to the meal", () => {
    renderBox(makeStore(), "/meals/42/edit/history/");
    fireEvent.keyDown(screen.getByRole("dialog"), {
      key: "Escape",
      keyCode: 27,
    });
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/meals\/42\/edit$/,
    );
  });

  it("loads nothing while the store has no meal", () => {
    const store = makeStore();
    renderBox(store);
    expect(store.goToMeal).toHaveBeenCalledTimes(1);

    act(() => {
      runInAction(() => {
        store.meal = null;
      });
    });
    expect(screen.getByText("loading...")).toBeInTheDocument();
    expect(store.goToMeal).toHaveBeenCalledTimes(1);
  });
});
