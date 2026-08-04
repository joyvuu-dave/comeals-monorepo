import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { Provider } from "mobx-react";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import MenuBox from "../../../app/frontend/src/components/meal/menu_box.jsx";
import { SAVE_DEBOUNCE_MS } from "../../../app/frontend/src/helpers/helpers.js";

function makeStore(overrides = {}, mealOverrides = {}) {
  return observable(
    {
      meal: {
        id: 42,
        description: "Pasta night",
        descriptionNotSaved: false,
        closed: false,
        ...mealOverrides,
      },
      editDescriptionMode: true,
      mealLoading: false,
      setDescriptionOn: vi.fn(),
      noteMenuTyping: vi.fn(),
      ...overrides,
    },
    { setDescriptionOn: false, noteMenuTyping: false },
  );
}

// Both providers so the test holds across the inject() → useStore()
// conversion.
function renderBox(store) {
  return render(
    <Provider store={store}>
      <StoreContext.Provider value={store}>
        <MenuBox />
      </StoreContext.Provider>
    </Provider>,
  );
}

describe("MenuBox", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("shows the meal description", () => {
    renderBox(makeStore());
    expect(screen.getByLabelText("Enter meal description")).toHaveDisplayValue(
      "Pasta night",
    );
  });

  it("delivers typed text after the save debounce, not before", () => {
    vi.useFakeTimers();
    const store = makeStore();
    renderBox(store);

    const textarea = screen.getByLabelText("Enter meal description");
    fireEvent.change(textarea, { target: { value: "Tacos" } });

    expect(store.noteMenuTyping).toHaveBeenCalledWith(store.meal);
    expect(store.setDescriptionOn).not.toHaveBeenCalled();

    act(() => {
      vi.advanceTimersByTime(SAVE_DEBOUNCE_MS + 50);
    });
    expect(store.setDescriptionOn).toHaveBeenCalledWith(store.meal, "Tacos");
  });

  it("delivers undelivered text when the textarea unmounts", () => {
    vi.useFakeTimers();
    const store = makeStore();
    const { unmount } = renderBox(store);

    fireEvent.change(screen.getByLabelText("Enter meal description"), {
      target: { value: "Tacos" },
    });
    unmount();

    expect(store.setDescriptionOn).toHaveBeenCalledWith(store.meal, "Tacos");
  });

  it("shows the not-saved warning when a save is failing", () => {
    const store = makeStore();
    renderBox(store);
    expect(screen.queryByRole("status")).not.toBeInTheDocument();

    act(() => {
      runInAction(() => {
        store.meal.descriptionNotSaved = true;
      });
    });
    expect(screen.getByRole("status")).toHaveTextContent(
      "Not saved — will retry",
    );
  });

  it("freezes the textarea while the meal loads or is closed", () => {
    const loading = makeStore({ mealLoading: true });
    const { unmount } = renderBox(loading);
    expect(screen.getByLabelText("Enter meal description")).toBeDisabled();
    unmount();

    const closed = makeStore({}, { closed: true });
    renderBox(closed);
    expect(screen.getByLabelText("Enter meal description")).toBeDisabled();
  });
});
