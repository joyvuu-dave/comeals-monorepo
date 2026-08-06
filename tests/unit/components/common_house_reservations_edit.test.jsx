import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
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

function renderForm({
  store = makeStore(),
  handleCloseModal = vi.fn(),
  setDirty = vi.fn(),
} = {}) {
  render(
    <StoreContext.Provider value={store}>
      <CommonHouseReservationsEdit
        eventId={50}
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
  const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 1000);
  fireEvent.click(button);
  nowSpy.mockRestore();
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

  // The title column is nullable. A null title must hydrate the input
  // as "", not null — a null value makes React drop the input to
  // uncontrolled (the warning-on-error guard in render_setup.js also
  // catches this, this test pins the fix itself).
  it("hydrates a null title as an empty string", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        event: { ...RESERVATION.event, title: null },
      },
    });
    renderForm();

    await vi.waitFor(() => {
      expect(screen.getByLabelText("Resident")).toHaveValue("1");
    });
    expect(screen.getByLabelText("Title")).toHaveValue("");
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
    armAndClick(buttons[buttons.length - 1]);

    expect(axios.delete).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50/delete",
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  // Optional does not mean ignored: clearing a title the reservation
  // had is a real change someone could lose, so it reports dirty.
  it("clearing the optional title reports dirty", async () => {
    const { setDirty } = renderForm();
    await screen.findByDisplayValue("Book Club");
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);
  });

  // The mirror case: the title column is nullable, and a null hydrates
  // as "". Typing into it and deleting it again leaves nothing that
  // differs from the record, so it reports clean — null and "" must
  // not read as a difference.
  it("a null title typed into and cleared again reports clean", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: { event: { ...RESERVATION.event, title: null } },
    });
    const { setDirty } = renderForm();
    await vi.waitFor(() => {
      expect(screen.getByLabelText("Resident")).toHaveValue("1");
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "Choir" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  // The discard gate (ADR 0006): the form compares its fields to the
  // fetched values, so an edit reports dirty and undoing it reports
  // clean again.
  it("reports dirty on an edit and clean when the edit is undone", async () => {
    const { setDirty } = renderForm();
    await screen.findByDisplayValue("Book Club");
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Resident"), {
      target: { value: "2" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("Resident"), {
      target: { value: "1" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  // A successful Update must report clean before it asks to close, or
  // the gate in calendar/show.jsx would raise the discard question on
  // a save. Call order, not final state: the mocked handleCloseModal
  // keeps the form mounted, so later renders report dirty again —
  // in the app the form unmounts instead.
  it("a successful Update reports clean before closing", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, setDirty } = renderForm();

    await screen.findByDisplayValue("Book Club");
    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "Choir" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });

    const closeOrder = handleCloseModal.mock.invocationCallOrder[0];
    const callsBeforeClose = setDirty.mock.calls.filter(
      (args, i) => setDirty.mock.invocationCallOrder[i] < closeOrder,
    );
    expect(callsBeforeClose.length).toBeGreaterThan(0);
    expect(callsBeforeClose[callsBeforeClose.length - 1]).toEqual([false]);
  });
});
