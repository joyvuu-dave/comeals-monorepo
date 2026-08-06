import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { MemoryRouter, Routes, Route } from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";
cookies.current = { community_id: "7" };

import axios from "axios";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { CALENDAR_PATH } from "../../../app/frontend/src/routes.js";
import EventsNew from "../../../app/frontend/src/components/events/new.jsx";

function makeStore() {
  return observable(
    {
      invalidateMonthForDate: vi.fn(),
    },
    { invalidateMonthForDate: false },
  );
}

// The component reads the calendar date from the router.
function renderForm({
  store = makeStore(),
  handleCloseModal = vi.fn(),
  setDirty = vi.fn(),
} = {}) {
  render(
    <StoreContext.Provider value={store}>
      <MemoryRouter initialEntries={["/calendar/all/2026-01-15/events/new"]}>
        <Routes>
          <Route
            path={CALENDAR_PATH}
            element={
              <EventsNew
                handleCloseModal={handleCloseModal}
                setDirty={setDirty}
              />
            }
          />
        </Routes>
      </MemoryRouter>
    </StoreContext.Provider>,
  );
  return { store, handleCloseModal, setDirty };
}

describe("EventsNew", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("renders the empty form", () => {
    renderForm();
    expect(screen.getByLabelText("Title")).toHaveDisplayValue("");
    expect(screen.getByLabelText("Description")).toHaveDisplayValue("");
    expect(screen.getByLabelText("Start Time")).toBeEnabled();
    expect(screen.getByRole("button", { name: "Create" })).toBeEnabled();
  });

  it("All Day clears and disables the time selects", () => {
    renderForm();
    fireEvent.change(screen.getByLabelText("Start Time"), {
      target: { value: "18:00" },
    });
    fireEvent.click(screen.getByLabelText("All Day"));

    expect(screen.getByLabelText("Start Time")).toBeDisabled();
    expect(screen.getByLabelText("End Time")).toBeDisabled();
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("");
  });

  it("submitting posts the form to the community's events", async () => {
    axios.post.mockResolvedValue({ status: 200, data: {} });
    const { store, handleCloseModal } = renderForm();

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "Movie Night" },
    });
    fireEvent.change(screen.getByLabelText("Start Time"), {
      target: { value: "18:00" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Create" }));

    expect(axios.post).toHaveBeenCalledWith(
      "/api/v1/events?community_id=7",
      expect.objectContaining({
        title: "Movie Night",
        start_hours: "18",
        start_minutes: "00",
        all_day: false,
      }),
    );

    // Success invalidates the month cache and closes the modal.
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
    expect(store.invalidateMonthForDate).toHaveBeenCalled();
  });

  it("the close icon closes the modal", () => {
    const { handleCloseModal } = renderForm();
    fireEvent.click(screen.getByLabelText("Close"));
    expect(handleCloseModal).toHaveBeenCalledTimes(1);
  });

  // The discard gate (ADR 0006): an untouched New form is clean, so
  // dismissing it stays free; typing makes it dirty, clearing the
  // field makes it clean again.
  it("reports clean while untouched and dirty once a field is filled", () => {
    const { setDirty } = renderForm();
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "Movie Night" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });
});
