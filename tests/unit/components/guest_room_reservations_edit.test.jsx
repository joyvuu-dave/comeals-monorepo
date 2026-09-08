import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { observable } from "mobx";

// The edit form renders ConfirmModal, which needs #root at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";
cookies.current = { timezone: "America/Los_Angeles" };

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
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

function renderForm({
  store = makeStore(),
  handleCloseModal = vi.fn(),
  setDirty = vi.fn(),
} = {}) {
  render(
    <StoreContext.Provider value={store}>
      <GuestRoomReservationsEdit
        eventId={60}
        handleCloseModal={handleCloseModal}
        setDirty={setDirty}
      />
    </StoreContext.Provider>,
  );
  return { store, handleCloseModal, setDirty };
}

// ConfirmModal's confirm button is armed only after armMs; jump the
// clock past the delay so the click goes through.
function armAndClick(button) {
  const nowSpy = vi
    .spyOn(performance, "now")
    .mockReturnValue(performance.now() + 1000);
  fireEvent.click(button);
  nowSpy.mockRestore();
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
    armAndClick(buttons[buttons.length - 1]);

    expect(axios.delete).toHaveBeenCalledWith(
      "/api/v1/guest-room-reservations/60/delete",
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  // The discard gate (ADR 0006): the form compares its fields to the
  // fetched values, so an edit reports dirty and undoing it reports
  // clean again.
  it("reports dirty on an edit and clean when the edit is undone", async () => {
    const { setDirty } = renderForm();
    await vi.waitFor(() => {
      expect(screen.getByLabelText("Host")).toHaveValue("1");
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "2" } });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "1" } });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  it("stays frozen when the reservation fails to load", async () => {
    axios.get.mockRejectedValue({ response: { status: 404, data: {} } });
    renderForm();
    await vi.waitFor(() => {
      expect(axios.get).toHaveBeenCalled();
    });
    await new Promise((r) => setTimeout(r, 0));
    expect(screen.getByRole("button", { name: "Update" })).toBeDisabled();
  });

  it("a refused update shows the reason and keeps the form open", async () => {
    toastStore.clearAll();
    axios.patch.mockRejectedValue({
      response: {
        status: 400,
        data: { message: "Date has already been taken" },
      },
    });
    const { handleCloseModal } = renderForm();
    await vi.waitFor(() => {
      expect(screen.getByLabelText("Host")).toHaveValue("1");
    });

    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "Date has already been taken",
      ]);
    });
    expect(handleCloseModal).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Update" })).toBeEnabled();
  });

  it("answers that land after the form closed touch nothing", async () => {
    let deliver;
    axios.get.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          deliver = resolve;
        }),
    );
    renderForm();
    cleanup();
    deliver({ status: 200, data: RESERVATION });
    await new Promise((r) => setTimeout(r, 0));
    expect(document.body).not.toHaveTextContent("01/25/2026");

    for (const settle of ["resolve", "reject"]) {
      let finish;
      axios.patch.mockImplementationOnce(
        () =>
          new Promise((resolve, reject) => {
            finish = settle === "resolve" ? resolve : reject;
          }),
      );
      const { handleCloseModal } = renderForm();
      await vi.waitFor(() => {
        expect(screen.getByLabelText("Host")).toHaveValue("1");
      });
      fireEvent.click(screen.getByRole("button", { name: "Update" }));
      cleanup();
      finish({ status: 200, data: {} });
      await new Promise((r) => setTimeout(r, 0));
      expect(handleCloseModal).not.toHaveBeenCalled();
    }
  });
});
