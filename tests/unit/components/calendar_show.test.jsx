import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { observable } from "mobx";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

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

// index.jsx registers this plugin at app startup; the "Do" ordinal in
// the header date needs it.
dayjs.extend(advancedFormat);

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
          start: new Date(2026, 0, 15, 18, 0),
          end: new Date(2026, 0, 15, 19, 0),
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
      ...overrides,
    },
    {
      teardownMealPage: false,
      goToMonth: false,
      ensureHosts: false,
      clearCalendarEvents: false,
      invalidateMonthForDate: false,
      logout: false,
    },
  );
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

function renderCalendar({
  store = makeStore(),
  path = "/calendar/all/2026-01-15/",
} = {}) {
  render(
    <StoreContext.Provider value={store}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path={CALENDAR_PATH} element={<MainCalendar />} />
          <Route path="/meals/*" element={null} />
        </Routes>
        <LocationEcho />
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
        description: "Kitchen cleaning",
        residents: [{ id: 1, display_name: "Jane", signed_up: false }],
      },
    });
    renderCalendar({ path: "/calendar/all/2026-01-15/rotations/show/10" });
    expect(screen.getByText("Rotation 10")).toBeInTheDocument();
    expect(await screen.findByText("Kitchen cleaning")).toBeInTheDocument();
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
      const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 1000);
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
});
