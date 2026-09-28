import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
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
import CommonHouseReservationsEdit from "../../../app/frontend/src/components/common_house_reservations/edit.jsx";
// What GET /api/v1/common-house-reservations/:id sends, made by the
// Rails app (rake test:generate_fixtures): resident 1's "Book Club",
// 7 to 9 PM on January 22, 2026, with the community's -08:00 offset.
import RESERVATION from "../../fixtures/common_house_reservation.json";

// What the server answers for an id it does not have
// (ApiController#not_found_api).
const NOT_FOUND = {
  response: {
    status: 404,
    data: {
      message:
        "The page you were looking for doesn't exist. You may have " +
        "mistyped the address or the page may have moved.",
    },
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
  const nowSpy = vi
    .spyOn(performance, "now")
    .mockReturnValue(performance.now() + 1000);
  fireEvent.click(button);
  nowSpy.mockRestore();
}

describe("CommonHouseReservationsEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    axios.get.mockResolvedValue({ status: 200, data: RESERVATION });
    // The computer's zone is not the community's, so a date read in the
    // computer's zone shows the wrong day and hour on every machine.
    vi.stubEnv("TZ", "UTC");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("fetches the reservation and hydrates the form", async () => {
    const { store } = renderForm();

    expect(store.ensureHosts).toHaveBeenCalledTimes(1);
    expect(await screen.findByDisplayValue("Book Club")).toBeVisible();
    expect(axios.get).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50",
    );
    expect(screen.getByLabelText("Resident")).toHaveValue("1");
    // Read in the community's zone, not the computer's (UTC here, where
    // the same instant is 3 AM on January 23).
    expect(screen.getByLabelText("Day")).toHaveDisplayValue("01/22/2026");
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("7:00 PM");
    expect(screen.getByLabelText("End Time")).toHaveDisplayValue("9:00 PM");
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

  // Only the resident changed, so every other field goes back as it
  // came: an edit must not move the booking's day or hours.
  it("Update patches the edited reservation and clears its month", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, store } = renderForm();

    await screen.findByDisplayValue("Book Club");
    fireEvent.change(screen.getByLabelText("Resident"), {
      target: { value: "2" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50/update",
      {
        resident_id: "2",
        start_year: 2026,
        start_month: 1,
        start_day: 22,
        start_hours: "19",
        start_minutes: "00",
        end_hours: "21",
        end_minutes: "00",
        title: "Book Club",
      },
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
    // The cached month the booking was in is stale now (issue #37).
    expect(store.invalidateMonthForDate.mock.calls).toEqual([
      [RESERVATION.event.start_date],
      [new Date(2026, 0, 22)],
    ]);
  });

  // Months far from the one on screen get no live update, so an edit
  // that moves the booking clears the month it left and the month it
  // joined.
  it("an Update that moves the reservation to another month clears both months", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, store } = renderForm();
    await screen.findByDisplayValue("Book Club");

    fireEvent.click(screen.getByLabelText("Day"));
    fireEvent.click(
      screen.getByRole("button", { name: "Go to the Next Month" }),
    );
    fireEvent.click(screen.getByRole("button", { name: /February 3rd/ }));
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations/50/update",
      expect.objectContaining({
        start_year: 2026,
        start_month: 2,
        start_day: 3,
      }),
    );
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
    expect(store.invalidateMonthForDate.mock.calls).toEqual([
      [RESERVATION.event.start_date],
      [new Date(2026, 1, 3)],
    ]);
  });

  it("Delete asks first, then deletes on confirm", async () => {
    axios.delete.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, store } = renderForm();
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
    expect(store.invalidateMonthForDate.mock.calls).toEqual([
      [RESERVATION.event.start_date],
    ]);
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

  // The body not_found_api in api_controller.rb always sends. Someone
  // deleted the reservation, or an old link names one that is gone. The
  // form stays locked, so no PATCH can go out with empty fields.
  it("tells the person why when the reservation cannot be loaded", async () => {
    toastStore.clearAll();
    axios.get.mockRejectedValue(NOT_FOUND);
    renderForm();
    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        NOT_FOUND.response.data.message,
      ]);
    });
    expect(screen.getByRole("button", { name: "Update" })).toBeDisabled();
  });

  it("a refused update shows the reason and keeps the form open", async () => {
    toastStore.clearAll();
    axios.patch.mockRejectedValue({
      response: { status: 400, data: { message: "Those hours are taken" } },
    });
    const { handleCloseModal } = renderForm();
    await screen.findByDisplayValue("Book Club");

    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    await vi.waitFor(() => {
      expect(toastStore.toasts.map((t) => t.message)).toEqual([
        "Those hours are taken",
      ]);
    });
    expect(handleCloseModal).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Update" })).toBeEnabled();
  });

  // A late answer must not reach a form that is gone: no toast over
  // the calendar, and no second close.
  it("answers that land after the form closed touch nothing", async () => {
    toastStore.clearAll();

    // The fetch, answered late. React shows no sign when it drops a
    // state update on a form that is gone, so this part only checks
    // that nothing throws.
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
    expect(document.body).not.toHaveTextContent("Book Club");

    // The fetch, refused late.
    let refuse;
    axios.get.mockImplementationOnce(
      () =>
        new Promise((_resolve, reject) => {
          refuse = reject;
        }),
    );
    renderForm();
    cleanup();
    refuse(NOT_FOUND);
    await new Promise((r) => setTimeout(r, 0));

    // The update, resolved late and refused late.
    for (const settle of ["resolve", "reject"]) {
      let finish;
      axios.patch.mockImplementationOnce(
        () =>
          new Promise((resolve, reject) => {
            finish = settle === "resolve" ? resolve : reject;
          }),
      );
      const { handleCloseModal } = renderForm();
      await screen.findByDisplayValue("Book Club");
      fireEvent.click(screen.getByRole("button", { name: "Update" }));
      cleanup();
      finish({ status: 200, data: {} });
      await new Promise((r) => setTimeout(r, 0));
      expect(handleCloseModal).not.toHaveBeenCalled();
    }
    expect(toastStore.toasts).toHaveLength(0);
  });
});
