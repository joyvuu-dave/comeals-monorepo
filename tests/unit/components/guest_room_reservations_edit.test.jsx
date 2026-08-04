import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { Provider } from "mobx-react";

// The edit form renders ConfirmModal, which needs #root at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

vi.mock("axios", () => ({
  default: {
    get: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
  },
}));

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) =>
      name === "timezone" ? "America/Los_Angeles" : undefined,
    ),
    set: vi.fn(),
  },
}));

import axios from "axios";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import GuestRoomReservationsEdit from "../../../app/frontend/src/components/guest_room_reservations/edit.jsx";

const RESERVATION = {
  event: {
    id: 60,
    resident_id: 1,
    date: "2026-01-25T00:00:00",
  },
};

function makeStore() {
  return observable(
    {
      hosts: [
        { id: 1, name: "Jane Smith", unitName: "A1" },
        { id: 2, name: "Bob Johnson", unitName: "B2" },
      ],
      hostsLoaded: true,
      ensureHosts: vi.fn(),
      invalidateMonthForDate: vi.fn(),
    },
    { ensureHosts: false, invalidateMonthForDate: false },
  );
}

// Both providers so the test holds across the inject() → useStore()
// conversion.
function renderForm({ store = makeStore(), handleCloseModal = vi.fn() } = {}) {
  render(
    <Provider store={store}>
      <StoreContext.Provider value={store}>
        <GuestRoomReservationsEdit
          eventId={60}
          handleCloseModal={handleCloseModal}
        />
      </StoreContext.Provider>
    </Provider>,
  );
  return { store, handleCloseModal };
}

describe("GuestRoomReservationsEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    axios.get.mockResolvedValue({ status: 200, data: RESERVATION });
  });

  it("fetches the reservation and hydrates the form", async () => {
    const { store } = renderForm();

    expect(store.ensureHosts).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => {
      expect(screen.getByLabelText("Host")).toHaveValue("1");
    });
    expect(axios.get).toHaveBeenCalledWith(
      "/api/v1/guest-room-reservations/60",
    );
    expect(screen.getByDisplayValue("01/25/2026")).toBeInTheDocument();
  });

  it("Update patches the edited reservation", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();

    await vi.waitFor(() => {
      expect(screen.getByLabelText("Host")).toHaveValue("1");
    });
    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "2" } });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith(
      "/api/v1/guest-room-reservations/60/update",
      { resident_id: "2", date: "2026-01-25" },
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  it("Delete asks first, then deletes on confirm", async () => {
    axios.delete.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();
    await vi.waitFor(() => {
      expect(screen.getByLabelText("Host")).toHaveValue("1");
    });

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(
      screen.getByText("Do you really want to delete this reservation?"),
    ).toBeInTheDocument();

    const buttons = screen.getAllByRole("button", { name: "Delete" });
    fireEvent.click(buttons[buttons.length - 1]);

    expect(axios.delete).toHaveBeenCalledWith(
      "/api/v1/guest-room-reservations/60/delete",
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });
});
