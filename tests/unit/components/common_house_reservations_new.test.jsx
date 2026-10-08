import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { observable } from "mobx";
import { MemoryRouter, Routes, Route } from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { messagesShown } from "../helpers/form_messages.js";
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
          "/calendar/all/2026-01-15/common-house-reservations/new",
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

  // The day is picked two months after the calendar's month, so a form
  // that cleared the month on screen (params.date) instead of the new
  // reservation's month would fail here (issue #37).
  it("submitting posts the reservation", async () => {
    axios.post.mockResolvedValue({ status: 200, data: {} });
    const { store, handleCloseModal } = renderForm();

    fireEvent.change(screen.getByLabelText("Resident"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Title"), {
      target: { value: "Book Club" },
    });
    fireEvent.click(document.getElementById("ch-new-day"));
    fireEvent.click(
      screen.getByRole("button", { name: "Go to the Next Month" }),
    );
    fireEvent.click(
      screen.getByRole("button", { name: "Go to the Next Month" }),
    );
    fireEvent.click(screen.getByRole("button", { name: /March 20/ }));
    fireEvent.change(screen.getByLabelText("Start Time"), {
      target: { value: "19:00" },
    });
    fireEvent.change(screen.getByLabelText("End Time"), {
      target: { value: "21:15" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Create" }));

    expect(axios.post).toHaveBeenCalledWith(
      "/api/v1/common-house-reservations",
      {
        resident_id: "1",
        start_year: 2026,
        start_month: 3,
        start_day: 20,
        start_hours: "19",
        start_minutes: "00",
        end_hours: "21",
        end_minutes: "15",
        title: "Book Club",
      },
    );
    // Success clears the new reservation's month from the cache and
    // closes the modal.
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
    expect(store.invalidateMonthForDate).toHaveBeenCalledTimes(1);
    expect(store.invalidateMonthForDate).toHaveBeenCalledWith(
      new Date(2026, 2, 20),
    );
  });

  // The picker offers days up to six months after the calendar's day
  // (2026-01-15 here), and no later.
  it("the day picker stops six months after the calendar's day", () => {
    renderForm();
    fireEvent.click(document.getElementById("ch-new-day"));
    for (let i = 0; i < 6; i++) {
      fireEvent.click(
        screen.getByRole("button", { name: "Go to the Next Month" }),
      );
    }
    expect(screen.getByRole("button", { name: /July 15/ })).toBeEnabled();
    expect(screen.getByRole("button", { name: /July 16/ })).toBeDisabled();
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

  // An empty form has no day, and the server answers that before it
  // looks at any other field (ApiController#parse_start_end_params).
  it("a refused create shows the reason and keeps the form open", async () => {
    toastStore.clearAll();
    axios.post.mockRejectedValue({
      response: { status: 400, data: { message: "Error: Invalid date" } },
    });
    const { handleCloseModal } = renderForm();
    fireEvent.click(screen.getByRole("button", { name: "Create" }));

    await vi.waitFor(() => {
      expect(messagesShown()).toEqual({
        form: ["Error: Invalid date"],
        stack: [],
      });
    });
    expect(handleCloseModal).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Create" })).toBeEnabled();
  });

  it("an answer that lands after the form closed touches nothing", async () => {
    toastStore.clearAll();
    for (const settle of ["resolve", "reject"]) {
      let finish;
      axios.post.mockImplementationOnce(
        () =>
          new Promise((resolve, reject) => {
            finish = settle === "resolve" ? resolve : reject;
          }),
      );
      const { handleCloseModal } = renderForm();
      fireEvent.click(screen.getByRole("button", { name: "Create" }));
      cleanup();
      finish({ status: 200, data: { message: "Late." } });
      await new Promise((r) => setTimeout(r, 0));
      expect(handleCloseModal).not.toHaveBeenCalled();
    }
    expect(toastStore.toasts).toHaveLength(0);
  });
});
