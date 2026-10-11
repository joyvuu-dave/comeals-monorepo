import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  act,
} from "@testing-library/react";
import { useState } from "react";
import { observable, runInAction } from "mobx";
import {
  MemoryRouter,
  Routes,
  Route,
  useLocation,
  useNavigate,
} from "react-router";

// calendar/show.jsx calls Modal.setAppElement("#root") at import time.
vi.hoisted(() => {
  const root = document.createElement("div");
  root.id = "root";
  document.body.appendChild(root);
});

vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";
cookies.current = {
  username: "Jane Smith",
  community_id: "7",
  timezone: "America/Los_Angeles",
};

import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { CALENDAR_PATH } from "../../../app/frontend/src/routes.js";
import MainCalendar from "../../../app/frontend/src/components/calendar/show.jsx";
import BackToToday from "../../../app/frontend/src/components/app/back_to_today";
import ErrorBoundary from "../../../app/frontend/src/components/app/error_boundary.jsx";
import { IDLE_MS } from "../../../app/frontend/src/helpers/screen_home";
import { fakeLocation } from "../helpers/fake_location.js";
import handleAxiosError from "../../../app/frontend/src/helpers/handle_axios_error.js";
import toastStore from "../../../app/frontend/src/stores/toast_store";
import { messagesShown } from "../helpers/form_messages.js";

// index.jsx registers this plugin at app startup; the "Do" ordinal in
// the header date needs it.
dayjs.extend(advancedFormat);

// The calendar's events are wall-clock Dates: their UTC fields are the
// community's wall clock (calendar/wall_clock_localizer.ts), so they are
// made with Date.UTC.
//
// The spy annotations stop MobX from wrapping them in actions, which
// would hide them from toHaveBeenCalled.
function makeStore(overrides = {}) {
  return observable(
    {
      communityToday: "2026-01-15",
      isOnline: true,
      calendarEvents: [
        {
          id: "meal-42",
          title: "Meal: Jane Smith",
          start: new Date(Date.UTC(2026, 0, 15, 18, 0)),
          end: new Date(Date.UTC(2026, 0, 15, 19, 0)),
          color: "#4caf50",
          url: "/meals/42/edit",
        },
      ],
      calendarEventsVersion: 1,
      hosts: [],
      hostsLoaded: true,
      teardownMealPage: vi.fn(),
      goToMonth: vi.fn(),
      ensureHosts: vi.fn(),
      clearCalendarEvents: vi.fn(),
      invalidateMonthForDate: vi.fn(),
      logout: vi.fn(),
      finishBillsSaves: vi.fn(() => Promise.resolve(true)),
      // Read by the idle timer (back_to_today.tsx).
      pageCrashed: false,
      newVersionAvailable: false,
      // The discard gate's flag (ADR 0006), set the way the real
      // store's action sets it.
      calendarFormDirty: false,
      setCalendarFormDirty(value) {
        this.calendarFormDirty = value;
      },
      // The open form shows an error of its own (use_form_messages.ts).
      // The idle timer reads it too.
      calendarFormErrorShown: false,
      setCalendarFormErrorShown(value) {
        this.calendarFormErrorShown = value;
      },
      ...overrides,
    },
    {
      teardownMealPage: false,
      goToMonth: false,
      ensureHosts: false,
      clearCalendarEvents: false,
      invalidateMonthForDate: false,
      logout: false,
      finishBillsSaves: false,
    },
  );
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// The browser's back button.
function BackButton() {
  const navigate = useNavigate();
  return <button onClick={() => navigate(-1)}>Browser back</button>;
}

// `before` is the page the person was on before `path`, for a test that
// goes back to it.
function renderCalendar({
  store = makeStore(),
  path = "/calendar/all/2026-01-15/",
  before = null,
} = {}) {
  const entries = before === null ? [path] : [before, path];
  render(
    <StoreContext.Provider value={store}>
      <MemoryRouter initialEntries={entries} initialIndex={entries.length - 1}>
        <Routes>
          <Route path={CALENDAR_PATH} element={<MainCalendar />} />
          <Route path="/meals/*" element={null} />
        </Routes>
        <LocationEcho />
        <BackButton />
      </MemoryRouter>
    </StoreContext.Provider>,
  );
  return { store };
}

describe("MainCalendar", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("mounting tears down the meal page, loads the month, and warms hosts", () => {
    const { store } = renderCalendar();
    expect(store.teardownMealPage).toHaveBeenCalledTimes(1);
    expect(store.goToMonth).toHaveBeenCalledWith("2026-01-15");
    expect(store.ensureHosts).toHaveBeenCalledTimes(1);
  });

  it("shows the header date, online state, user, and month label", () => {
    renderCalendar();
    expect(screen.getByText("Thu Jan 15th")).toBeInTheDocument();
    expect(screen.getByText("ONLINE")).toBeInTheDocument();
    expect(screen.getByText("logout Jane Smith")).toBeInTheDocument();
    expect(screen.getByText("January 2026")).toBeInTheDocument();
  });

  it("renders the store's events on the grid", () => {
    renderCalendar();
    expect(screen.getByText("Meal: Jane Smith")).toBeInTheDocument();
  });

  it("clicking an event with a url goes there", () => {
    renderCalendar();
    fireEvent.click(screen.getByText("Meal: Jane Smith"));
    expect(screen.getByTestId("location")).toHaveTextContent("/meals/42/edit");
  });

  it("prev and next go one month either way", () => {
    renderCalendar();
    fireEvent.click(screen.getByRole("button", { name: "Goto Next Month" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2026-02-15",
    );
  });

  it("prev goes back one month", () => {
    renderCalendar();
    fireEvent.click(screen.getByRole("button", { name: "Goto Last Month" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2025-12-15",
    );
  });

  it("the events/new path opens the event modal", () => {
    renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
    expect(screen.getByText("New Event")).toBeInTheDocument();
    expect(screen.getByLabelText("Title")).toBeInTheDocument();
  });

  it("closing the modal returns to the calendar path", () => {
    renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
    fireEvent.click(screen.getByLabelText("Close"));
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/calendar\/all\/2026-01-15$/,
    );
  });

  it("the rotations path opens the rotation modal", async () => {
    const axios = (await import("axios")).default;
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        id: 10,
        place_value: 3,
        description: "Kitchen cleaning",
        residents: [{ id: 1, display_name: "Jane", signed_up: false }],
      },
    });
    renderCalendar({ path: "/calendar/all/2026-01-15/rotations/show/10" });
    expect(screen.getByText("Rotation")).toBeInTheDocument();
    expect(await screen.findByText("Kitchen cleaning")).toBeInTheDocument();
    // The title shows the place value, not the id from the URL.
    expect(screen.getByText("Rotation 3")).toBeInTheDocument();
  });

  it("renders the sidebar buttons", () => {
    renderCalendar();
    expect(screen.getByRole("button", { name: "Guest Room" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Next Meal" })).toBeVisible();
  });

  it("shows OFFLINE when the connection drops", () => {
    renderCalendar({ store: makeStore({ isOnline: false }) });
    expect(screen.getByText("OFFLINE")).toBeInTheDocument();
  });

  // The discard gate (ADR 0006): a dirty form never closes silently.
  // Every close path — the X, Escape, a click outside — runs through
  // the same handleCloseModal, so the X stands in for all of them.
  describe("the discard gate", () => {
    function dirtyEventForm() {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      fireEvent.change(screen.getByLabelText("Title"), {
        target: { value: "Movie Night" },
      });
    }

    it("a dirty form asks instead of closing", () => {
      dirtyEventForm();
      fireEvent.click(screen.getByLabelText("Close"));

      expect(screen.getByText("Discard your changes?")).toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent("/events/new");
    });

    it("Keep editing returns to the form with the changes intact", () => {
      dirtyEventForm();
      fireEvent.click(screen.getByLabelText("Close"));
      fireEvent.click(screen.getByRole("button", { name: "Keep editing" }));

      expect(
        screen.queryByText("Discard your changes?"),
      ).not.toBeInTheDocument();
      expect(screen.getByLabelText("Title")).toHaveValue("Movie Night");
      expect(screen.getByTestId("location")).toHaveTextContent("/events/new");
    });

    it("Discard closes and drops the changes", () => {
      dirtyEventForm();
      fireEvent.click(screen.getByLabelText("Close"));

      // The Discard button is armed only after armMs; jump the clock
      // past the delay so the click goes through.
      const nowSpy = vi
        .spyOn(performance, "now")
        .mockReturnValue(performance.now() + 1000);
      fireEvent.click(screen.getByRole("button", { name: "Discard" }));
      nowSpy.mockRestore();

      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15$/,
      );
    });

    // The overlay closes on its own mousedown, not react-modal's
    // click detection — a day-picker click never bubbles to the
    // overlay (react-day-picker stops it), which stranded react-modal's
    // internal flag and made the first outside click do nothing.
    it("a mousedown on the overlay asks when the form is dirty", () => {
      dirtyEventForm();
      const overlay = document.querySelector(".ReactModal__Overlay");
      fireEvent.mouseDown(overlay);

      expect(screen.getByText("Discard your changes?")).toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent("/events/new");
    });

    it("a mousedown on the overlay closes a clean form at once", () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      const overlay = document.querySelector(".ReactModal__Overlay");
      fireEvent.mouseDown(overlay);

      expect(
        screen.queryByText("Discard your changes?"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15$/,
      );
    });

    // A mousedown that starts inside the form and ends on the overlay
    // (a text-selection drag) must not count as a close request.
    it("a mousedown inside the form does not close it", () => {
      dirtyEventForm();
      fireEvent.mouseDown(screen.getByLabelText("Title"));

      expect(
        screen.queryByText("Discard your changes?"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent("/events/new");
    });

    it("Escape on a dirty form also asks", () => {
      dirtyEventForm();
      fireEvent.keyDown(screen.getByRole("dialog"), {
        key: "Escape",
        keyCode: 27,
      });

      expect(screen.getByText("Discard your changes?")).toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent("/events/new");
    });

    // The flag lives in the store, so the idle timer reads the same one
    // (back_to_today.tsx). The form compares values, not keystrokes.
    it("keeps the flag in the store, where the idle timer reads it too", () => {
      const { store } = renderCalendar({
        path: "/calendar/all/2026-01-15/events/new",
      });
      expect(store.calendarFormDirty).toBe(false);

      fireEvent.change(screen.getByLabelText("Title"), {
        target: { value: "Movie Night" },
      });
      expect(store.calendarFormDirty).toBe(true);

      fireEvent.change(screen.getByLabelText("Title"), {
        target: { value: "" },
      });
      expect(store.calendarFormDirty).toBe(false);
    });

    // ADR 0006: "a change that is typed and then undone also does not
    // count". The idle timer follows the same rule.
    it("a title typed and then deleted counts as nothing typed: the X closes at once", () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      fireEvent.change(screen.getByLabelText("Title"), {
        target: { value: "Movie Night" },
      });
      fireEvent.change(screen.getByLabelText("Title"), {
        target: { value: "" },
      });
      fireEvent.click(screen.getByLabelText("Close"));

      expect(
        screen.queryByText("Discard your changes?"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15$/,
      );
    });

    it("Discard leaves the flag clear for the next form", () => {
      const { store } = renderCalendar({
        path: "/calendar/all/2026-01-15/events/new",
      });
      fireEvent.change(screen.getByLabelText("Title"), {
        target: { value: "Movie Night" },
      });
      fireEvent.click(screen.getByLabelText("Close"));
      expect(screen.getByText("Discard your changes?")).toBeInTheDocument();
      expect(store.calendarFormDirty).toBe(true);
      const nowSpy = vi
        .spyOn(performance, "now")
        .mockReturnValue(performance.now() + 1000);
      fireEvent.click(screen.getByRole("button", { name: "Discard" }));
      nowSpy.mockRestore();

      expect(store.calendarFormDirty).toBe(false);
    });

    // The untouched case is the existing "closing the modal returns to
    // the calendar path" test above; this pins the after-save case.
    it("a successful Create closes without asking", async () => {
      const axios = (await import("axios")).default;
      axios.post.mockResolvedValue({ status: 200, data: {} });
      dirtyEventForm();
      fireEvent.click(screen.getByRole("button", { name: "Create" }));

      await vi.waitFor(() => {
        expect(screen.getByTestId("location")).toHaveTextContent(
          /^\/calendar\/all\/2026-01-15$/,
        );
      });
      expect(
        screen.queryByText("Discard your changes?"),
      ).not.toBeInTheDocument();
    });
  });

  // The idle timer (back_to_today.tsx) reads the flag the discard gate
  // reads. After five idle minutes, a form with nothing typed in it
  // closes, and the screen goes to today's calendar the way it does
  // with no form open. A form with typed changes stays: nobody is there
  // to answer "Discard your changes?" (ADR 0006). The store's day and
  // the clock are Jan 15, 2026, at noon in Los Angeles.
  describe("the idle timer", () => {
    const TODAY = "/calendar/all/2026-01-15/";

    beforeEach(() => {
      // The timer moves only a signed-in screen.
      cookies.current.token = "test-token";
      vi.useFakeTimers({ now: new Date("2026-01-15T12:00:00-08:00") });
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    function renderWithTimer(path) {
      const store = makeStore();
      render(
        <StoreContext.Provider value={store}>
          <MemoryRouter initialEntries={[path]}>
            <BackToToday store={store} />
            <Routes>
              <Route path={CALENDAR_PATH} element={<MainCalendar />} />
            </Routes>
            <LocationEcho />
          </MemoryRouter>
        </StoreContext.Provider>,
      );
      return store;
    }

    // The calendar draws a new month two animation frames after the
    // address changes, and the fake clock runs those frames too.
    function idle(ms) {
      act(() => {
        vi.advanceTimersByTime(ms);
      });
    }

    function title() {
      return screen.getByLabelText("Title");
    }

    it("closes a new form with nothing typed in it after five idle minutes", () => {
      renderWithTimer("/calendar/all/2026-03-01/events/new/");

      idle(IDLE_MS - 1);
      expect(screen.getByRole("dialog")).toBeInTheDocument();

      idle(1);
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(TODAY);
      expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent(
        "January 2026",
      );
    });

    // With no form open, the calendar of today's month stays as it is.
    // With a form open, the form closes and the month stays.
    it("closes a form with nothing typed in it on today's month, and stays on today's month", () => {
      renderWithTimer("/calendar/all/2026-01-03/guest-room-reservations/new/");
      expect(
        screen.getByRole("heading", { name: "January 2026" }),
      ).toBeInTheDocument();

      idle(IDLE_MS);
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(TODAY);
      expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent(
        "January 2026",
      );
    });

    // The gate compares values, not keystrokes (ADR 0006), so a title
    // typed and then deleted is nothing typed, for the timer too.
    it("closes a form where a title was typed and then deleted", () => {
      renderWithTimer("/calendar/all/2026-03-01/events/new/");
      fireEvent.change(title(), { target: { value: "Movie Night" } });
      fireEvent.change(title(), { target: { value: "" } });

      idle(IDLE_MS);
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(TODAY);
    });

    it("leaves a form with typed changes open, with what was typed", () => {
      renderWithTimer("/calendar/all/2026-03-01/events/new/");
      fireEvent.change(title(), { target: { value: "Movie Night" } });

      idle(IDLE_MS * 3);
      expect(title()).toHaveValue("Movie Night");
      expect(screen.getByTestId("location")).toHaveTextContent(
        "/calendar/all/2026-03-01/events/new/",
      );
      expect(
        screen.queryByText("Discard your changes?"),
      ).not.toBeInTheDocument();
    });

    // Someone tapped outside a typed form and walked away from the
    // question. The question and the form both stay.
    it("leaves a typed form open under its discard question", () => {
      renderWithTimer("/calendar/all/2026-03-01/events/new/");
      fireEvent.change(title(), { target: { value: "Movie Night" } });
      fireEvent.click(screen.getByLabelText("Close"));

      idle(IDLE_MS * 3);
      expect(screen.getByText("Discard your changes?")).toBeInTheDocument();
      expect(title()).toHaveValue("Movie Night");
    });

    // The idle timer's load after a crash does not read the flag
    // (helpers/screen_home.ts). The error page took the place of the
    // form, and the form reported nothing typed as it went, so the flag
    // is clear by then.
    it("finds the flag clear after a crash took a typed form away", () => {
      const quiet = vi.spyOn(console, "error").mockImplementation(() => {});
      let crash;
      function CrashOnDemand() {
        const [broken, setBroken] = useState(false);
        crash = () => setBroken(true);
        if (broken) throw new Error("a render error beside the calendar");
        return null;
      }
      const store = makeStore({ markPageCrashed: vi.fn() });
      render(
        <StoreContext.Provider value={store}>
          <MemoryRouter
            initialEntries={["/calendar/all/2026-03-01/events/new/"]}
          >
            <ErrorBoundary>
              <Routes>
                <Route path={CALENDAR_PATH} element={<MainCalendar />} />
              </Routes>
              <CrashOnDemand />
            </ErrorBoundary>
          </MemoryRouter>
        </StoreContext.Provider>,
      );
      fireEvent.change(title(), { target: { value: "Movie Night" } });
      expect(store.calendarFormDirty).toBe(true);

      act(() => crash());
      expect(
        screen.getByText("Something went wrong with Comeals."),
      ).toBeInTheDocument();
      expect(store.calendarFormDirty).toBe(false);
      quiet.mockRestore();
      // ErrorBoundary counted the crash (helpers/crash_reload_wait.ts).
      sessionStorage.clear();
    });

    // #137: an error stays until a person closes it. A form's own
    // messages go when the form closes, so a form that shows an error of
    // its own stays open, typed in or not. The person closes the error,
    // and the next five idle minutes close the form.
    describe("a form that shows an error of its own", () => {
      const EVENT = {
        id: 70,
        title: "Community Meeting",
        description: "",
        start_date: "2026-03-28T19:00:00",
        end_date: null,
        allday: false,
      };

      function refusal(message) {
        return { response: { status: 400, data: { message } } };
      }

      // The page asks for more than the event as it mounts (the
      // signed-in resident's id), so each address gets its own answer.
      // Any other address gets the mock's usual empty answer.
      async function answerGets(answers) {
        const axios = (await import("axios")).default;
        axios.get.mockImplementation(function (url) {
          const answer = answers[url];
          return answer ? answer() : Promise.resolve({ status: 200, data: {} });
        });
        return axios;
      }

      afterEach(async () => {
        const axios = (await import("axios")).default;
        axios.get.mockImplementation(() =>
          Promise.resolve({ status: 200, data: {} }),
        );
      });

      // The case people will hit: the Edit form is clean, and the
      // server refused the Delete.
      it("keeps a refused Delete's reason on screen until a person closes it", async () => {
        const axios = await answerGets({
          "/api/v1/events/70": () =>
            Promise.resolve({ status: 200, data: EVENT }),
        });
        axios.delete.mockRejectedValueOnce(
          refusal("This event already happened."),
        );
        renderWithTimer("/calendar/all/2026-03-01/events/edit/70/");
        await act(async () => {});
        fireEvent.click(screen.getByRole("button", { name: "Delete" }));
        const buttons = screen.getAllByRole("button", { name: "Delete" });
        const nowSpy = vi
          .spyOn(performance, "now")
          .mockReturnValue(performance.now() + 1000);
        fireEvent.click(buttons[buttons.length - 1]);
        nowSpy.mockRestore();
        await act(async () => {});
        expect(
          screen.getByText("This event already happened."),
        ).toBeInTheDocument();

        idle(IDLE_MS * 3);
        expect(
          screen.getByText("This event already happened."),
        ).toBeInTheDocument();
        expect(screen.getByTestId("location")).toHaveTextContent(
          "/calendar/all/2026-03-01/events/edit/70/",
        );
      });

      // #115: the form stays empty and locked, and says why.
      it("keeps an Edit form whose record could not be loaded, with the reason", async () => {
        await answerGets({
          "/api/v1/events/70": () =>
            Promise.reject(refusal("Event not found.")),
        });
        renderWithTimer("/calendar/all/2026-03-01/events/edit/70/");
        await act(async () => {});
        expect(screen.getByText("Event not found.")).toBeInTheDocument();

        idle(IDLE_MS * 3);
        expect(screen.getByText("Event not found.")).toBeInTheDocument();
      });

      it("keeps a refused Create with nothing typed, and closes the form once the person closes the error", async () => {
        const axios = (await import("axios")).default;
        axios.post.mockRejectedValueOnce(refusal("Title can't be blank"));
        renderWithTimer("/calendar/all/2026-03-01/events/new/");
        fireEvent.click(screen.getByRole("button", { name: "Create" }));
        await act(async () => {});
        expect(screen.getByText("Title can't be blank")).toBeInTheDocument();

        idle(IDLE_MS * 3);
        expect(screen.getByText("Title can't be blank")).toBeInTheDocument();

        fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
        idle(IDLE_MS);
        expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
        expect(screen.getByTestId("location")).toHaveTextContent(TODAY);
      });

      // The midnight move closes a form with nothing typed in it, the
      // same as the idle timer does.
      it("keeps the form and its error when the day moves to a new month", async () => {
        const axios = (await import("axios")).default;
        axios.post.mockRejectedValueOnce(refusal("Title can't be blank"));
        const store = renderWithTimer("/calendar/all/2026-01-15/events/new/");
        fireEvent.click(screen.getByRole("button", { name: "Create" }));
        await act(async () => {});

        act(() => {
          runInAction(() => {
            store.communityToday = "2026-02-01";
          });
        });
        expect(screen.getByTestId("location")).toHaveTextContent(
          "/calendar/all/2026-01-15/events/new/",
        );
        expect(screen.getByText("Title can't be blank")).toBeInTheDocument();
      });
    });

    // An edit form compares its fields with what the server sent.
    it("closes an edit form with nothing changed, and leaves one with a change", async () => {
      const axios = (await import("axios")).default;
      axios.get.mockResolvedValue({
        status: 200,
        data: {
          id: 70,
          title: "Community Meeting",
          description: "",
          start_date: "2026-03-28T19:00:00",
          end_date: null,
          allday: false,
        },
      });
      renderWithTimer("/calendar/all/2026-03-01/events/edit/70/");
      await act(async () => {});
      expect(title()).toHaveValue("Community Meeting");

      idle(IDLE_MS);
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(TODAY);

      cleanup();
      renderWithTimer("/calendar/all/2026-03-01/events/edit/70/");
      await act(async () => {});
      fireEvent.change(title(), { target: { value: "Board Meeting" } });

      idle(IDLE_MS * 3);
      expect(title()).toHaveValue("Board Meeting");
    });
  });

  // #137: a form's own messages show inside the form, and the stack
  // keeps every other message, such as the one that names a meal whose
  // costs were not saved. Closing the form, however it closes, takes
  // its own messages with it and leaves the stack as it was.
  describe("messages when a form closes", () => {
    const NOT_SAVED =
      "The cooks and costs you entered for Thu, Jan 15th were not saved. Please open that meal and enter them again.";
    const REFUSED = "Title can't be blank";

    beforeEach(() => {
      toastStore.clearAll();
    });

    afterEach(() => {
      toastStore.clearAll();
    });

    // A message from elsewhere is in the stack, then the form's Create
    // is refused. The refusal shows inside the form, not in the stack.
    async function formRefused() {
      const axios = (await import("axios")).default;
      axios.post.mockRejectedValueOnce({
        response: { status: 422, data: { message: REFUSED } },
      });
      act(() => {
        handleAxiosError({ response: { data: { message: NOT_SAVED } } });
      });
      fireEvent.click(screen.getByRole("button", { name: "Create" }));
      await vi.waitFor(() => {
        expect(messagesShown()).toEqual({
          form: [REFUSED],
          stack: [NOT_SAVED],
        });
      });
    }

    it("closing the form takes away its own message and nothing else", async () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      await formRefused();

      fireEvent.click(screen.getByLabelText("Close"));

      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15$/,
      );
      expect(messagesShown()).toEqual({ form: [], stack: [NOT_SAVED] });
    });

    it("a Create that works after a refusal takes away the refusal", async () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      await formRefused();
      const axios = (await import("axios")).default;
      axios.post.mockResolvedValueOnce({ status: 200, data: {} });

      fireEvent.click(screen.getByRole("button", { name: "Create" }));

      await vi.waitFor(() => {
        expect(screen.getByTestId("location")).toHaveTextContent(
          /^\/calendar\/all\/2026-01-15$/,
        );
      });
      expect(messagesShown()).toEqual({ form: [], stack: [NOT_SAVED] });
    });

    // The back button closes the form without the X, and the form's
    // message is just as much about a form that is gone.
    it("going back from the form takes away its own message and nothing else", async () => {
      renderCalendar({
        before: "/calendar/all/2026-01-15/",
        path: "/calendar/all/2026-01-15/events/new",
      });
      await formRefused();

      fireEvent.click(screen.getByRole("button", { name: "Browser back" }));

      expect(screen.queryByText("New Event")).not.toBeInTheDocument();
      expect(messagesShown()).toEqual({ form: [], stack: [NOT_SAVED] });
    });
  });

  // #148. react-modal listens for Escape only on the dialog itself, so
  // Escape closes a form only while focus is inside the dialog. When
  // focus moves to the page's <body>, it goes back to the dialog.
  describe("focus that leaves the dialog", () => {
    afterEach(() => {
      vi.useRealTimers();
    });

    function pressEscape() {
      fireEvent.keyDown(document.activeElement, {
        key: "Escape",
        keyCode: 27,
      });
    }

    // Chrome takes focus off a button that turns disabled, and the
    // event it sends is the same as for a blur.
    it("goes back to the dialog when a control loses it to the page", async () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      const dialog = screen.getByRole("dialog");
      const title = screen.getByLabelText("Title");
      title.focus();

      title.blur();
      expect(document.body).toHaveFocus();

      await vi.waitFor(() => expect(dialog).toHaveFocus());
      pressEscape();
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15$/,
      );
    });

    // WebKit, like jsdom, sends no event when the focused element is
    // removed: here the ✕ of a message the person closes.
    it("goes back to the dialog when the control that had it is removed", async () => {
      const axios = (await import("axios")).default;
      axios.post.mockRejectedValueOnce({
        response: { status: 422, data: { message: "Title can't be blank" } },
      });
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      const dialog = screen.getByRole("dialog");
      fireEvent.click(screen.getByRole("button", { name: "Create" }));
      const dismiss = await screen.findByRole("button", { name: "Dismiss" });
      dismiss.focus();
      // A move of focus is checked a moment later. That check runs
      // now, so it cannot be what puts focus back after the removal.
      await act(() => new Promise((resolve) => setTimeout(resolve, 0)));

      fireEvent.click(dismiss);
      expect(dismiss).not.toBeInTheDocument();
      expect(document.body).toHaveFocus();

      await vi.waitFor(() => expect(dialog).toHaveFocus());
      pressEscape();
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15$/,
      );
    });

    it("stays on the control it moved to", () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/events/new" });
      vi.useFakeTimers();
      const description = screen.getByLabelText("Description");
      screen.getByLabelText("Title").focus();

      description.focus();
      vi.runAllTimers();

      expect(description).toHaveFocus();
    });
  });

  it("clicking a day number goes to that day; the current day stays put", () => {
    renderCalendar();
    fireEvent.click(screen.getByRole("button", { name: "15" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/calendar\/all\/2026-01-15\/$/,
    );

    fireEvent.click(screen.getByRole("button", { name: "20" }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2026-01-20",
    );
  });

  // Each clock below is on a different date in the community's zone
  // than in UTC, so a Today button that read the computer's own zone
  // would go to the wrong day. One zone alone is not enough: a
  // computer set to the community's zone gets the same date either
  // way. The Los Angeles case catches that on a computer east of Los
  // Angeles, and the Tokyo case on a computer west of Tokyo.
  describe("the today button", () => {
    const fixtureTimezone = cookies.current.timezone;

    afterEach(() => {
      vi.useRealTimers();
      cookies.current.timezone = fixtureTimezone;
    });

    it("goes to today's date in the community's zone", () => {
      // 07:30 UTC on March 4 is 23:30 on March 3 in Los Angeles.
      vi.useFakeTimers({
        toFake: ["Date"],
        now: new Date("2026-03-04T07:30:00Z"),
      });
      renderCalendar();
      fireEvent.click(screen.getByRole("button", { name: "today" }));
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-03-03$/,
      );
    });

    it("goes to today's date in a community east of UTC", () => {
      // 20:00 UTC on March 3 is 05:00 on March 4 in Tokyo.
      cookies.current.timezone = "Asia/Tokyo";
      vi.useFakeTimers({
        toFake: ["Date"],
        now: new Date("2026-03-03T20:00:00Z"),
      });
      renderCalendar();
      fireEvent.click(screen.getByRole("button", { name: "today" }));
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-03-04$/,
      );
    });

    it("does nothing when the calendar already shows today", () => {
      // 07:30 UTC on January 16 is 23:30 on January 15 in Los Angeles.
      vi.useFakeTimers({
        toFake: ["Date"],
        now: new Date("2026-01-16T07:30:00Z"),
      });
      renderCalendar();
      fireEvent.click(screen.getByRole("button", { name: "today" }));
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/calendar\/all\/2026-01-15\/$/,
      );
    });
  });

  it("clicking an event without a url stays on the calendar", () => {
    renderCalendar({
      store: makeStore({
        calendarEvents: [
          {
            id: "note-1",
            title: "Holiday",
            start: new Date(Date.UTC(2026, 0, 16, 0, 0)),
            end: new Date(Date.UTC(2026, 0, 16, 23, 59)),
          },
        ],
      }),
    });
    fireEvent.click(screen.getByText("Holiday"));
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/calendar\/all\/2026-01-15\/$/,
    );
  });

  // Chip text is black on a light background and white on a dark one,
  // whichever passes WCAG AA. An event with no color gets the
  // calendar's own dark blue background, where white is right.
  describe("chip colors", () => {
    function chipFor(title) {
      return screen.getByText(title).closest(".rbc-event");
    }

    it("picks black on light colors and white on dark ones", () => {
      renderCalendar({
        store: makeStore({
          calendarEvents: [
            {
              id: "e1",
              title: "Light",
              start: new Date(Date.UTC(2026, 0, 16, 18, 0)),
              end: new Date(Date.UTC(2026, 0, 16, 19, 0)),
              color: "#4caf50",
              url: "/x",
            },
            {
              id: "e2",
              title: "Dark",
              start: new Date(Date.UTC(2026, 0, 17, 18, 0)),
              end: new Date(Date.UTC(2026, 0, 17, 19, 0)),
              color: "#1a237e",
              url: "/x",
            },
            {
              id: "e3",
              title: "Short",
              start: new Date(Date.UTC(2026, 0, 18, 18, 0)),
              end: new Date(Date.UTC(2026, 0, 18, 19, 0)),
              color: "#000",
              url: "/x",
            },
            {
              id: "e4",
              title: "Plain",
              start: new Date(Date.UTC(2026, 0, 19, 18, 0)),
              end: new Date(Date.UTC(2026, 0, 19, 19, 0)),
            },
          ],
        }),
      });
      expect(chipFor("Light").style.color).toBe("rgb(0, 0, 0)");
      expect(chipFor("Dark").style.color).toBe("rgb(255, 255, 255)");
      // A three-digit hex reads the same as its six-digit form.
      expect(chipFor("Short").style.color).toBe("rgb(255, 255, 255)");
      expect(chipFor("Plain").style.color).toBe("rgb(255, 255, 255)");
    });

    // Only a chip that links somewhere and starts before the community's
    // today (2026-01-15 here) is washed out. A chip with no link (a
    // holiday or a birthday) keeps its full color on any day.
    it("washes out an event that already happened, and nothing else", () => {
      renderCalendar({
        store: makeStore({
          calendarEvents: [
            {
              id: "past",
              title: "Past",
              start: new Date(Date.UTC(2026, 0, 10, 18, 0)),
              end: new Date(Date.UTC(2026, 0, 10, 19, 0)),
              color: "#4caf50",
              url: "/meals/40/edit",
            },
            {
              id: "last-night",
              title: "Last night",
              start: new Date(Date.UTC(2026, 0, 14, 23, 0)),
              end: new Date(Date.UTC(2026, 0, 14, 23, 30)),
              color: "#4caf50",
              url: "/meals/41/edit",
            },
            {
              id: "midnight",
              title: "Midnight",
              start: new Date(Date.UTC(2026, 0, 15, 0, 0)),
              end: new Date(Date.UTC(2026, 0, 15, 1, 0)),
              color: "#4caf50",
              url: "/events/9/edit",
            },
            {
              id: "tomorrow",
              title: "Tomorrow",
              start: new Date(Date.UTC(2026, 0, 16, 18, 0)),
              end: new Date(Date.UTC(2026, 0, 16, 19, 0)),
              color: "#4caf50",
              url: "/meals/43/edit",
            },
            {
              id: "no-url",
              title: "No link",
              start: new Date(Date.UTC(2026, 0, 10, 0, 0)),
              end: new Date(Date.UTC(2026, 0, 10, 23, 59)),
              color: "#4caf50",
            },
          ],
        }),
      });
      expect(chipFor("Past").style.filter).toBe("saturate(35%)");
      expect(chipFor("Past").style.color).toBe("rgb(0, 0, 0)");
      expect(chipFor("Last night").style.filter).toBe("saturate(35%)");
      expect(chipFor("Midnight").style.filter).toBe("");
      expect(chipFor("Tomorrow").style.filter).toBe("");
      expect(chipFor("No link").style.filter).toBe("");
      expect(chipFor("No link").style.color).toBe("rgb(0, 0, 0)");
    });
  });

  // A bills save for a meal the person left can still be on its way. A
  // reload would end it, and logout takes the token away, so logout
  // first waits for it (finishBillsSaves, #150).
  it("logout waits for the bills saves, then signs out and reloads to the login page", async () => {
    const { location, restore } = fakeLocation();
    try {
      let saved;
      const { store } = renderCalendar({
        store: makeStore({
          finishBillsSaves: vi.fn(
            () =>
              new Promise((resolve) => {
                saved = resolve;
              }),
          ),
        }),
      });
      fireEvent.click(screen.getByText("logout Jane Smith"));
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(store.logout).not.toHaveBeenCalled();
      expect(location.href).toBe("http://localhost:3000/");

      await act(async () => saved(true));

      expect(store.logout).toHaveBeenCalledTimes(1);
      expect(location.href).toBe("/");
    } finally {
      restore();
    }
  });

  // A save it waited for was not saved, and the message is on screen.
  // Signing out and reloading would take it away before the person
  // could read it. The next tap goes on.
  it("logout stays signed in when a save it waited for was not saved", async () => {
    const { location, restore } = fakeLocation();
    try {
      const { store } = renderCalendar({
        store: makeStore({
          finishBillsSaves: vi.fn(() => Promise.resolve(false)),
        }),
      });
      await act(async () => {
        fireEvent.click(screen.getByText("logout Jane Smith"));
      });

      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(store.logout).not.toHaveBeenCalled();
      expect(location.href).toBe("http://localhost:3000/");
    } finally {
      restore();
    }
  });

  // Every modal the URL can name, by its title. The edit forms fetch
  // their record; the guest room and common house forms also read the
  // hosts list from the store.
  describe("the modal for each URL", () => {
    it("opens the new guest room form", () => {
      renderCalendar({
        path: "/calendar/all/2026-01-15/guest-room-reservations/new",
      });
      expect(screen.getByText("New Guest Room Reservation")).toBeVisible();
    });

    it("opens the new common house form", () => {
      renderCalendar({
        path: "/calendar/all/2026-01-15/common-house-reservations/new",
      });
      expect(screen.getByText("New Common House Reservation")).toBeVisible();
    });

    it("opens the edit guest room form", async () => {
      const axios = (await import("axios")).default;
      axios.get.mockResolvedValue({
        status: 200,
        data: { event: { id: 60, resident_id: 1, date: "2026-01-25" } },
      });
      renderCalendar({
        path: "/calendar/all/2026-01-15/guest-room-reservations/edit/60",
      });
      expect(screen.getByText("Edit Guest Room Reservation")).toBeVisible();
      expect(await screen.findByDisplayValue("01/25/2026")).toBeVisible();
    });

    it("opens the edit common house form", async () => {
      const axios = (await import("axios")).default;
      axios.get.mockResolvedValue({
        status: 200,
        data: {
          event: {
            id: 50,
            resident_id: 1,
            title: "Book Club",
            start_date: "2026-01-22T19:00:00",
            end_date: "2026-01-22T21:00:00",
          },
        },
      });
      renderCalendar({
        path: "/calendar/all/2026-01-15/common-house-reservations/edit/50",
      });
      expect(screen.getByText("Edit Common House Reservation")).toBeVisible();
      expect(await screen.findByDisplayValue("Book Club")).toBeVisible();
    });

    it("opens the edit event form", async () => {
      const axios = (await import("axios")).default;
      axios.get.mockResolvedValue({
        status: 200,
        data: {
          id: 70,
          title: "Community Meeting",
          description: "",
          start_date: "2026-01-28T19:00:00",
          end_date: null,
          allday: false,
        },
      });
      renderCalendar({ path: "/calendar/all/2026-01-15/events/edit/70" });
      expect(screen.getByText("Edit Event")).toBeVisible();
      expect(
        await screen.findByDisplayValue("Community Meeting"),
      ).toBeVisible();
    });

    it("opens an empty dialog for a modal or view it does not know", () => {
      renderCalendar({ path: "/calendar/all/2026-01-15/rotations/new" });
      const dialog = screen.getByRole("dialog");
      expect(dialog).toBeInTheDocument();
      expect(dialog).toHaveTextContent("");

      cleanup();
      renderCalendar({ path: "/calendar/all/2026-01-15/potluck/show/1" });
      expect(screen.getByRole("dialog")).toHaveTextContent("");
    });
  });
});
