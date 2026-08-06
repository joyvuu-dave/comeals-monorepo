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
import CommonHouseReservationsNew from "../../../app/frontend/src/components/common_house_reservations/new.jsx";

function makeStore(overrides = {}) {
  return observable(
    {
      hosts: [
        { id: 1, name: "Jane Smith", unitName: "A1" },
        { id: 2, name: "Bob Johnson", unitName: "B2" },
      ],
      hostsLoaded: true,
      ensureHosts: vi.fn(),
      invalidateMonthForDate: vi.fn(),
      ...overrides,
    },
    { ensureHosts: false, invalidateMonthForDate: false },
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
      <MemoryRouter
        initialEntries={[
          "/calendar/all/2026-01-15/common_house_reservations/new",
        ]}
      >
        <Routes>
          <Route
            path={CALENDAR_PATH}
            element={
              <CommonHouseReservationsNew
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

describe("CommonHouseReservationsNew", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("asks the store for the hosts list on mount", () => {
    const { store } = renderForm();
    expect(store.ensureHosts).toHaveBeenCalledTimes(1);
  });

  it("lists hosts as unit - name options", () => {
    renderForm();
    expect(
      screen.getByRole("option", { name: "A1 - Jane Smith" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("option", { name: "B2 - Bob Johnson" }),
    ).toBeInTheDocument();
  });

  it("keeps Create disabled until the hosts arrive", () => {
    renderForm({ store: makeStore({ hosts: [], hostsLoaded: false }) });
    expect(screen.getByRole("button", { name: "Create" })).toBeDisabled();
  });

  it("submitting posts the reservation", async () => {
    axios.post.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();

    fireEvent.change(screen.getByLabelText("Resident"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Start Time"), {
      target: { value: "19:00" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Create" }));

    expect(axios.post).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations?community_id=7",
      expect.objectContaining({
        resident_id: "1",
        start_hours: "19",
        start_minutes: "00",
      }),
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  // The discard gate (ADR 0006): an untouched New form is clean, so
  // dismissing it stays free; typing makes it dirty, clearing the
  // field makes it clean again.
  it("reports clean while untouched and dirty once a field is filled", () => {
    const { setDirty } = renderForm();
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "Book Club" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });
});
