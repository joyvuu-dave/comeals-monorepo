import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { Provider } from "mobx-react";
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

// Both providers and both routing paths (match prop + real router) so
// the test holds across the conversion.
function renderForm({ store = makeStore(), handleCloseModal = vi.fn() } = {}) {
  const match = { params: { date: "2026-01-15", type: "all" } };
  render(
    <Provider store={store}>
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
                  match={match}
                />
              }
            />
          </Routes>
        </MemoryRouter>
      </StoreContext.Provider>
    </Provider>,
  );
  return { store, handleCloseModal };
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
});
