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

// Both providers so the test holds across the inject() → useStore()
// conversion.
function renderForm({ store = makeStore(), handleCloseModal = vi.fn() } = {}) {
  render(
    <StoreContext.Provider value={store}>
      <EventsEdit eventId={70} handleCloseModal={handleCloseModal} />
    </StoreContext.Provider>,
  );
  return { store, handleCloseModal };
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
    fireEvent.click(buttons[buttons.length - 1]);

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
});
