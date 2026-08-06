import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";

// events/edit renders ConfirmModal, which needs #root at import time.
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
import EventsEdit from "../../../app/frontend/src/components/events/edit.jsx";

const EVENT = {
  id: 70,
  title: "Community Meeting",
  description: "Monthly community meeting",
  start_date: "2026-01-28T19:00:00",
  end_date: "2026-01-28T21:00:00",
  allday: false,
};

function makeStore() {
  return observable(
    {
      invalidateMonthForDate: vi.fn(),
    },
    { invalidateMonthForDate: false },
  );
}

function renderForm({
  store = makeStore(),
  handleCloseModal = vi.fn(),
  setDirty = vi.fn(),
} = {}) {
  render(
    <StoreContext.Provider value={store}>
      <EventsEdit
        eventId={70}
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

describe("EventsEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    axios.get.mockResolvedValue({ status: 200, data: EVENT });
  });

  it("fetches the event and hydrates the form", async () => {
    renderForm();

    // Frozen until the payload lands.
    expect(screen.getByRole("button", { name: "Update" })).toBeDisabled();

    expect(await screen.findByDisplayValue("Community Meeting")).toBeVisible();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/events/70");
    // No timezone marker on the fixture date, so it reads as 19:00 in
    // the community's timezone.
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("7:00 PM");
    expect(screen.getByRole("button", { name: "Update" })).toBeEnabled();
  });

  it("Update patches the edited fields", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();

    const title = await screen.findByDisplayValue("Community Meeting");
    fireEvent.change(title, { target: { value: "Annual Meeting" } });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith(
      "/api/v1/events/70/update",
      expect.objectContaining({ title: "Annual Meeting" }),
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  it("Delete asks first, then deletes on confirm", async () => {
    axios.delete.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal } = renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(axios.delete).not.toHaveBeenCalled();
    expect(
      screen.getByText("Do you really want to delete this event?"),
    ).toBeInTheDocument();

    // ConfirmModal's confirm button says Delete; it is the one inside
    // the modal overlay.
    const buttons = screen.getAllByRole("button", { name: "Delete" });
    armAndClick(buttons[buttons.length - 1]);

    expect(axios.delete).toHaveBeenCalledWith("/api/v1/events/70/delete");
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
  });

  it("Cancel keeps the event", async () => {
    renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));

    expect(axios.delete).not.toHaveBeenCalled();
    expect(
      screen.queryByText("Do you really want to delete this event?"),
    ).not.toBeInTheDocument();
  });

  // Optional does not mean ignored: clearing a description the event
  // had is a real change someone could lose, so it reports dirty.
  it("clearing the optional description reports dirty", async () => {
    const { setDirty } = renderForm();
    await screen.findByDisplayValue("Community Meeting");
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("Description"), {
      target: { value: "" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);
  });

  // end_date is nullable and hydrates as an empty End Time. Setting a
  // time is dirty; clearing it again leaves nothing that differs from
  // the record, so it reports clean — null and "" must not read as a
  // difference.
  it("a null end time set and cleared again reports clean", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: { ...EVENT, end_date: null },
    });
    const { setDirty } = renderForm();
    await screen.findByDisplayValue("Community Meeting");
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(screen.getByLabelText("End Time"), {
      target: { value: "21:00" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(screen.getByLabelText("End Time"), {
      target: { value: "" },
    });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  // The discard gate (ADR 0006): the form compares its fields to the
  // fetched values, so an edit reports dirty and undoing it reports
  // clean again.
  it("reports dirty on an edit and clean when the edit is undone", async () => {
    const { setDirty } = renderForm();
    const title = await screen.findByDisplayValue("Community Meeting");
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(title, { target: { value: "Annual Meeting" } });
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(title, { target: { value: "Community Meeting" } });
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });
});
