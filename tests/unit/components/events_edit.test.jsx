import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  within,
} from "@testing-library/react";
import { observable } from "mobx";

// events/edit renders ConfirmModal, which needs #root at import time.
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
import { messagesShown } from "../helpers/form_messages.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import EventsEdit from "../../../app/frontend/src/components/events/edit.jsx";
// What GET /api/v1/events/:id sends, made by the Rails app
// (rake test:generate_fixtures): 7 to 9 PM on January 28, 2026, with
// the community's -08:00 offset.
import EVENT from "../../fixtures/event.json";

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
  const nowSpy = vi
    .spyOn(performance, "now")
    .mockReturnValue(performance.now() + 1000);
  fireEvent.click(button);
  nowSpy.mockRestore();
}

describe("EventsEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    axios.get.mockResolvedValue({ status: 200, data: EVENT });
    // The computer's zone is not the community's, so a date read in the
    // computer's zone shows the wrong day and hour on every machine.
    vi.stubEnv("TZ", "UTC");
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("fetches the event and hydrates the form", async () => {
    renderForm();

    // Frozen until the payload lands.
    expect(screen.getByRole("button", { name: "Update" })).toBeDisabled();

    expect(await screen.findByDisplayValue("Community Meeting")).toBeVisible();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/events/70");
    // Read in the community's zone, not the computer's (UTC here, where
    // the same instant is 3 AM on January 29).
    expect(screen.getByLabelText("Description")).toHaveValue(
      "Monthly community meeting",
    );
    expect(screen.getByLabelText("Day")).toHaveDisplayValue("01/28/2026");
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("7:00 PM");
    expect(screen.getByLabelText("End Time")).toHaveDisplayValue("9:00 PM");
    expect(screen.getByLabelText("All Day")).not.toBeChecked();
    expect(screen.getByRole("button", { name: "Update" })).toBeEnabled();
  });

  // Only the title changed, so every other field goes back as it came:
  // an edit must not move the event's day or time.
  it("Update patches the edited fields and clears the event's month", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, store } = renderForm();

    const title = await screen.findByDisplayValue("Community Meeting");
    fireEvent.change(title, { target: { value: "Annual Meeting" } });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith("/api/v1/events/70/update", {
      title: "Annual Meeting",
      description: "Monthly community meeting",
      start_year: 2026,
      start_month: 1,
      start_day: 28,
      start_hours: "19",
      start_minutes: "00",
      end_hours: "21",
      end_minutes: "00",
      all_day: false,
    });
    await vi.waitFor(() => {
      expect(handleCloseModal).toHaveBeenCalledTimes(1);
    });
    // The cached month the event was in is stale now (issue #37).
    expect(store.invalidateMonthForDate.mock.calls).toEqual([
      [EVENT.start_date],
      [new Date(2026, 0, 28)],
    ]);
  });

  // Months far from the one on screen get no live update, so an edit
  // that moves the event clears the month it left and the month it
  // joined.
  it("an Update that moves the event to another month clears both months", async () => {
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, store } = renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByLabelText("Day"));
    fireEvent.click(
      screen.getByRole("button", { name: "Go to the Next Month" }),
    );
    fireEvent.click(screen.getByRole("button", { name: /February 3rd/ }));
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(axios.patch).toHaveBeenCalledWith(
      "/api/v1/events/70/update",
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
      [EVENT.start_date],
      [new Date(2026, 1, 3)],
    ]);
  });

  it("Delete asks first, then deletes on confirm", async () => {
    axios.delete.mockResolvedValue({ status: 200, data: {} });
    const { handleCloseModal, store } = renderForm();
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
    expect(store.invalidateMonthForDate.mock.calls).toEqual([
      [EVENT.start_date],
    ]);
  });

  it("a refused delete shows the reason and keeps the form open", async () => {
    toastStore.clearAll();
    axios.delete.mockRejectedValue({
      response: { data: { message: "This event already happened." } },
    });
    const { handleCloseModal } = renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    const buttons = screen.getAllByRole("button", { name: "Delete" });
    armAndClick(buttons[buttons.length - 1]);

    await vi.waitFor(() => {
      expect(messagesShown()).toEqual({
        form: ["This event already happened."],
        stack: [],
      });
    });
    expect(handleCloseModal).not.toHaveBeenCalled();
    expect(screen.getByDisplayValue("Community Meeting")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Update" })).toBeEnabled();
  });

  it("a delete that lands after the form closed touches nothing", async () => {
    let finish;
    axios.delete.mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const { handleCloseModal } = renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    const buttons = screen.getAllByRole("button", { name: "Delete" });
    armAndClick(buttons[buttons.length - 1]);
    cleanup();
    finish({ status: 200, data: {} });
    await new Promise((r) => setTimeout(r, 0));

    expect(handleCloseModal).not.toHaveBeenCalled();
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

  it("All Day clears the times; unchecking it leaves them empty", async () => {
    renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByLabelText("All Day"));
    expect(screen.getByLabelText("All Day")).toBeChecked();
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("");
    expect(screen.getByLabelText("Start Time")).toBeDisabled();

    fireEvent.click(screen.getByLabelText("All Day"));
    expect(screen.getByLabelText("All Day")).not.toBeChecked();
    expect(screen.getByLabelText("Start Time")).toBeEnabled();
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("");
  });

  // The body not_found_api in api_controller.rb always sends. Someone
  // deleted the event, or an old link names one that is gone. The
  // form stays locked, so no PATCH can go out with empty fields.
  it("tells the person why when the event cannot be loaded", async () => {
    toastStore.clearAll();
    axios.get.mockRejectedValue(NOT_FOUND);
    renderForm();
    await vi.waitFor(() => {
      expect(messagesShown()).toEqual({
        form: [NOT_FOUND.response.data.message],
        stack: [],
      });
    });
    expect(screen.getByRole("button", { name: "Update" })).toBeDisabled();
  });

  it("a refused update shows the reason and keeps the form open", async () => {
    toastStore.clearAll();
    axios.patch.mockRejectedValue({
      response: { status: 400, data: { message: "Title can't be blank" } },
    });
    const { handleCloseModal } = renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    await vi.waitFor(() => {
      expect(messagesShown()).toEqual({
        form: ["Title can't be blank"],
        stack: [],
      });
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
    deliver({ status: 200, data: EVENT });
    await new Promise((r) => setTimeout(r, 0));
    expect(document.body).not.toHaveTextContent("Community Meeting");

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
      await screen.findByDisplayValue("Community Meeting");
      fireEvent.click(screen.getByRole("button", { name: "Update" }));
      cleanup();
      finish({ status: 200, data: {} });
      await new Promise((r) => setTimeout(r, 0));
      expect(handleCloseModal).not.toHaveBeenCalled();
    }
    expect(toastStore.toasts).toHaveLength(0);
  });
});

// #147. The time menus list 8:00 AM to 10:00 PM in 15-minute steps. A
// menu must show what the form will send: before, a stored time that
// was not on the menu showed as the empty choice, while the form still
// held that time and sent it.
describe("EventsEdit: a stored time that is not on the menu", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubEnv("TZ", "UTC");
  });
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  function stored(start_date, end_date, allday = false) {
    axios.get.mockResolvedValue({
      status: 200,
      data: { ...EVENT, start_date, end_date, allday },
    });
  }

  function sent() {
    const body = axios.patch.mock.calls[0][1];
    return {
      start_hours: body.start_hours,
      start_minutes: body.start_minutes,
      end_hours: body.end_hours,
      end_minutes: body.end_minutes,
    };
  }

  const BOTH_EMPTY = {
    start_hours: "",
    start_minutes: "",
    end_hours: "",
    end_minutes: "",
  };

  // A notice: both menus left empty save an entry from midnight to
  // midnight (7c66ade4). It opens the way the New form makes one.
  it("sends both times empty when both menus show empty", async () => {
    stored("2026-04-15T00:00:00.000-07:00", "2026-04-15T00:00:00.000-07:00");
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    renderForm();
    await screen.findByDisplayValue("Community Meeting");

    const start = screen.getByLabelText("Start Time");
    const end = screen.getByLabelText("End Time");
    fireEvent.change(start, { target: { value: "18:00" } });
    fireEvent.change(start, { target: { value: "" } });
    expect(start).toHaveDisplayValue("");
    expect(end).toHaveDisplayValue("");

    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    expect(sent()).toEqual(BOTH_EMPTY);
  });

  // The server saves both empty as the same notice (#141).
  it("keeps a notice a notice when only the title changes", async () => {
    stored("2026-04-15T00:00:00.000-07:00", "2026-04-15T00:00:00.000-07:00");
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { setDirty } = renderForm();
    const title = await screen.findByDisplayValue("Community Meeting");
    expect(setDirty).toHaveBeenLastCalledWith(false);

    fireEvent.change(title, { target: { value: "Movie night cancelled" } });
    fireEvent.click(screen.getByRole("button", { name: "Update" }));

    expect(sent()).toEqual(BOTH_EMPTY);
  });

  // The admin form takes any time.
  it("shows a time made in admin as one more choice, and sends it back", async () => {
    stored("2026-04-15T07:00:00.000-07:00", "2026-04-15T22:30:00.000-07:00");
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    const { setDirty } = renderForm();
    await screen.findByDisplayValue("Community Meeting");

    const start = screen.getByLabelText("Start Time");
    const end = screen.getByLabelText("End Time");
    expect(start).toHaveDisplayValue("7:00 AM");
    expect(end).toHaveDisplayValue("10:30 PM");
    expect(setDirty).toHaveBeenLastCalledWith(false);
    // In its place by time: first on the start menu, after the empty
    // choice, and last on the end menu.
    expect(within(start).getAllByRole("option")[1]).toHaveTextContent(
      "7:00 AM",
    );
    expect(within(end).getAllByRole("option").at(-1)).toHaveTextContent(
      "10:30 PM",
    );

    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    expect(sent()).toEqual({
      start_hours: "07",
      start_minutes: "00",
      end_hours: "22",
      end_minutes: "30",
    });
  });

  // The choice is the stored time, so it stays on the menu after the
  // person picks another time, and they can pick it again.
  it("keeps the stored time's choice after another time is picked", async () => {
    stored("2026-04-15T07:00:00.000-07:00", "2026-04-15T09:00:00.000-07:00");
    renderForm();
    await screen.findByDisplayValue("Community Meeting");
    const start = screen.getByLabelText("Start Time");

    fireEvent.change(start, { target: { value: "18:00" } });
    expect(start).toHaveDisplayValue("6:00 PM");
    fireEvent.change(start, { target: { value: "07:00" } });

    expect(start).toHaveDisplayValue("7:00 AM");
  });

  // Midnight on only one side is not a notice.
  it("shows a midnight start as 12:00 AM when the end is another time", async () => {
    stored("2026-04-15T00:00:00.000-07:00", "2026-04-15T09:00:00.000-07:00");
    renderForm();
    await screen.findByDisplayValue("Community Meeting");

    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("12:00 AM");
    expect(screen.getByLabelText("End Time")).toHaveDisplayValue("9:00 AM");
  });

  // An all-day event is saved from midnight with no end. It opens with
  // both menus empty, the way the All Day box leaves them, so turning
  // All Day off shows what the form will send.
  it("opens an all-day event with both menus empty", async () => {
    stored("2026-04-15T00:00:00.000-07:00", null, true);
    axios.patch.mockResolvedValue({ status: 200, data: {} });
    renderForm();
    await screen.findByDisplayValue("Community Meeting");

    fireEvent.click(screen.getByLabelText("All Day"));
    expect(screen.getByLabelText("Start Time")).toHaveDisplayValue("");
    expect(screen.getByLabelText("End Time")).toHaveDisplayValue("");

    fireEvent.click(screen.getByRole("button", { name: "Update" }));
    expect(sent()).toEqual(BOTH_EMPTY);
  });
});
