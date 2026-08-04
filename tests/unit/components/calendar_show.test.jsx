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

vi.mock("axios", () => ({
  default: {
    get: vi.fn(() => Promise.resolve({ status: 200, data: {} })),
    post: vi.fn(),
  },
}));

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => {
      const cookies = {
        username: "Jane Smith",
        community_id: "7",
        timezone: "America/Los_Angeles",
      };
      return cookies[name];
    }),
    set: vi.fn(),
  },
}));

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

// Both providers so the test holds across the inject() → useStore()
// conversion; the real router replaces the withRouter props.
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
    expect(screen.getByText("New")).toBeInTheDocument();
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
});
