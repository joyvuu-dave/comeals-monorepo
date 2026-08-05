import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { MemoryRouter, Routes, Route } from "react-router";

vi.mock("axios", () => ({
  default: {
    get: vi.fn(),
    post: vi.fn(),
  },
}));

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => (name === "community_id" ? "7" : undefined)),
    set: vi.fn(),
  },
}));

import axios from "axios";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { CALENDAR_PATH } from "../../../app/frontend/src/routes.js";
import GuestRoomReservationsNew from "../../../app/frontend/src/components/guest_room_reservations/new.jsx";

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

// Both providers and both routing paths (match prop + real router) so
// the test holds across the conversion.
function renderForm({
  store = makeStore(),
  handleCloseModal = vi.fn(),
  setDirty = vi.fn(),
} = {}) {
  const match = { params: { date: "2026-01-15", type: "all" } };
  render(
    <StoreContext.Provider value={store}>
      <MemoryRouter
        initialEntries={[
          "/calendar/all/2026-01-15/guest_room_reservations/new",
        ]}
      >
        <Routes>
          <Route
            path={CALENDAR_PATH}
            element={
              <GuestRoomReservationsNew
                handleCloseModal={handleCloseModal}
                match={match}
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

describe("GuestRoomReservationsNew", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("asks the store for the hosts list on mount", () => {
    const { store } = renderForm();
    expect(store.ensureHosts).toHaveBeenCalledTimes(1);
  });

  it("keeps Create disabled until the hosts arrive", () => {
    renderForm({ store: makeStore({ hosts: [], hostsLoaded: false }) });
    expect(screen.getByRole("button", { name: "Create" })).toBeDisabled();
  });

  it("submitting posts the chosen host and day", async () => {
    axios.post.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();

    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "2" } });

    // Pick a day through the picker so the payload's date comes from
    // real day selection.
    fireEvent.click(document.getElementById("guest-room-new-day"));
    fireEvent.click(screen.getByRole("button", { name: /January 20/ }));

    fireEvent.click(screen.getByRole("button", { name: "Create" }));

    expect(axios.post).toHaveBeenCalledWith(
      "/api/v1/guest-room-reservations?community_id=7",
      { resident_id: "2", date: "2026-01-20" },
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  // The discard gate (ADR 0006): an untouched New form is clean, so
  // dismissing it stays free; filling a field makes it dirty.
  it("reports clean while untouched and dirty once a field is filled", () => {
    const { setDirty } = renderForm();
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "2" } });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "" } });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });
});
