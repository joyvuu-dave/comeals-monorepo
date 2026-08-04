import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";

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
import CommonHouseReservationsEdit from "../../../app/frontend/src/components/common_house_reservations/edit.jsx";

const RESERVATION = {
  event: {
    id: 50,
    resident_id: 1,
    title: "Book Club",
    start_date: "2026-01-22T19:00:00",
    end_date: "2026-01-22T21:00:00",
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
    <StoreContext.Provider value={store}>
      <CommonHouseReservationsEdit
        eventId={50}
        handleCloseModal={handleCloseModal}
      />
    </StoreContext.Provider>,
  );
  return { store, handleCloseModal };
}

describe("CommonHouseReservationsEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    axios.get.mockResolvedValue({ status: 200, data: RESERVATION });
  });

  it("fetches the reservation and hydrates the form", async () => {
    const { store } = renderForm();

    expect(store.ensureHosts).toHaveBeenCalledTimes(1);
    expect(await screen.findByDisplayValue("Book Club")).toBeVisible();
    expect(axios.get).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50",
    );
    expect(screen.getByLabelText("Resident")).toHaveValue("1");
  });

  it("Update patches the edited reservation", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();

    await screen.findByDisplayValue("Book Club");
    fireEvent.change(screen.getByLabelText("Resident"), {
      target: { value: "2" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50/update",
      expect.objectContaining({ resident_id: "2", title: "Book Club" }),
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  it("Delete asks first, then deletes on confirm", async () => {
    axios.delete.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();
    await screen.findByDisplayValue("Book Club");

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(
      screen.getByText("Do you really want to delete this reservation?"),
    ).toBeInTheDocument();

    const buttons = screen.getAllByRole("button", { name: "Delete" });
    fireEvent.click(buttons[buttons.length - 1]);

    expect(axios.delete).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50/delete",
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });
});
