import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, fireEvent, screen } from "@testing-library/react";
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
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { CALENDAR_PATH } from "../../../app/frontend/src/routes.js";
import MainCalendar from "../../../app/frontend/src/components/calendar/show.jsx";
import { createDataStore } from "../helpers/create_data_store.js";
import { useDeviceZone } from "../helpers/device_zone.js";
import { chipDay, chipLine, todayCell } from "../helpers/month_grid.js";
import { setPageSetting } from "../helpers/page_settings_for_tests.js";

// The calendar shows every time in the community's zone, on every
// device (#129). The community here is Los Angeles (the cookie fixture)
// and the device is somewhere else. The calendar used to hand
// react-big-calendar each community time as a Date in the device's
// zone, new Date(year, month, day, hour, minute). A time that the
// device's own clock skips cannot be such a Date: it moves forward by
// the skip, so it is drawn an hour late, and in Greenland on the next
// day.
//
// Each test goes from the server's answer to the screen: the real
// store turns the month into chips, and the real calendar draws them.

// A month as the server sends it, with only these events.
function month(year, monthNumber, events) {
  return {
    id: "test-community-id",
    year,
    month: monthNumber,
    timezone: "America/Los_Angeles",
    meals: [],
    bills: [],
    rotations: [],
    birthdays: [],
    common_house_reservations: [],
    guest_room_reservations: [],
    events,
  };
}

function event(title, start, end) {
  return { id: `events/${title}`, title, start, end, url: "events/edit/1" };
}

// The calendar on `day`, drawing what the real store makes of `data`.
function Where() {
  return <div data-testid="where">{useLocation().pathname}</div>;
}

function drawCalendar(day, data) {
  const dataStore = createDataStore();
  dataStore.drawEvents(data);
  const store = observable(
    {
      communityToday: day,
      isOnline: true,
      calendarEvents: dataStore.calendarEvents.slice(),
      calendarEventsVersion: 1,
      hosts: [],
      hostsLoaded: true,
      teardownMealPage: vi.fn(),
      goToMonth: vi.fn(),
      ensureHosts: vi.fn(),
      clearCalendarEvents: vi.fn(),
    },
    {
      teardownMealPage: false,
      goToMonth: false,
      ensureHosts: false,
      clearCalendarEvents: false,
    },
  );
  return render(
    <StoreContext.Provider value={store}>
      <MemoryRouter initialEntries={[`/calendar/all/${day}/`]}>
        <Routes>
          <Route
            path={CALENDAR_PATH}
            element={
              <>
                <MainCalendar />
                <Where />
              </>
            }
          />
        </Routes>
      </MemoryRouter>
    </StoreContext.Provider>,
  ).container;
}

beforeEach(() => {
  vi.clearAllMocks();
  setPageSetting("comeals-pusher-key", "test-key");
  setPageSetting("comeals-pusher-cluster", "us2");
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

// Greenland's clocks skip from 23:00 to midnight on Saturday, Mar 28,
// 2026 (01:00 UTC on Sunday).
describe("on a phone in Greenland (America/Nuuk)", () => {
  useDeviceZone("America/Nuuk");

  it("draws an event at 23:30 on Saturday, Mar 28 on that Saturday", () => {
    const container = drawCalendar(
      "2026-03-28",
      month(2026, 3, [
        event(
          "Late talk",
          "2026-03-28T23:30:00.000-07:00",
          "2026-03-28T23:45:00.000-07:00",
        ),
      ]),
    );

    expect(chipDay(container, "Late talk")).toBe("28");
  });

  it("marks Saturday as today at 23:30 on Saturday, Mar 28", () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-03-28T23:30:00-07:00"));

    const container = drawCalendar("2026-03-28", month(2026, 3, []));

    expect(todayCell(container)).toBe("28");
  });
});

// London's clocks skip from 01:00 to 02:00 on Sunday, Mar 29, 2026.
describe("on a phone in London (Europe/London)", () => {
  useDeviceZone("Europe/London");

  it("keeps the events of Sunday, Mar 29 in the order of their times", () => {
    const container = drawCalendar(
      "2026-03-29",
      month(2026, 3, [
        event(
          "At two",
          "2026-03-29T02:00:00.000-07:00",
          "2026-03-29T02:15:00.000-07:00",
        ),
        event(
          "At half past one",
          "2026-03-29T01:30:00.000-07:00",
          "2026-03-29T01:45:00.000-07:00",
        ),
      ]),
    );

    expect(chipDay(container, "At half past one")).toBe("29");
    expect(chipDay(container, "At two")).toBe("29");
    expect(chipLine(container, "At half past one")).toBe(0);
    expect(chipLine(container, "At two")).toBe(1);
  });
});

// Havana's clocks skip from midnight to 01:00 on Sunday, Mar 8, 2026,
// the same day Los Angeles skips from 02:00 to 03:00.
describe("on a phone in Havana (America/Havana)", () => {
  useDeviceZone("America/Havana");

  it("keeps the events of Sunday, Mar 8 in the order of their times", () => {
    const container = drawCalendar(
      "2026-03-08",
      month(2026, 3, [
        event(
          "At one",
          "2026-03-08T01:00:00.000-08:00",
          "2026-03-08T01:15:00.000-08:00",
        ),
        event(
          "At half past midnight",
          "2026-03-08T00:30:00.000-08:00",
          "2026-03-08T00:45:00.000-08:00",
        ),
      ]),
    );

    expect(chipDay(container, "At half past midnight")).toBe("08");
    expect(chipDay(container, "At one")).toBe("08");
    expect(chipLine(container, "At half past midnight")).toBe(0);
    expect(chipLine(container, "At one")).toBe(1);
  });
});

// Three lines of calendar/show.jsx read a day in UTC: the month shown,
// the start of today for washing out past chips, and the day a clicked
// day number goes to. CI runs in UTC, where the device's zone gives the
// same answer, so these tests run on the two devices furthest from UTC.
// Changed back to the device's zone, each line fails here.

function daysInMonthShown(container) {
  return container.querySelectorAll(".rbc-date-cell:not(.rbc-off-range)")
    .length;
}

function dimmed(container, title) {
  const chip = [...container.querySelectorAll(".rbc-event")].find(
    (c) => c.textContent === title,
  );
  return chip.style.filter === "saturate(35%)";
}

describe("on a phone in Kiritimati (UTC+14)", () => {
  useDeviceZone("Pacific/Kiritimati");

  // Local midnight on Mar 1 in Kiritimati is 10:00 on Feb 28 in UTC.
  it("shows March, not February, for /calendar/all/2026-03-01", () => {
    const container = drawCalendar("2026-03-01", month(2026, 3, []));
    expect(daysInMonthShown(container)).toBe(31);
  });

  // Saturday 23:30 in Los Angeles is Sunday 21:30 in Kiritimati.
  it("washes out Friday's chips, and not Saturday's, late on Saturday", () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-03-07T23:30:00-08:00"));
    const container = drawCalendar(
      "2026-03-07",
      month(2026, 3, [
        event(
          "Fri dinner",
          "2026-03-06T19:00:00.000-08:00",
          "2026-03-06T20:00:00.000-08:00",
        ),
        event(
          "Sat dinner",
          "2026-03-07T19:00:00.000-08:00",
          "2026-03-07T20:00:00.000-08:00",
        ),
      ]),
    );
    expect(todayCell(container)).toBe("07");
    expect(dimmed(container, "Fri dinner")).toBe(true);
    expect(dimmed(container, "Sat dinner")).toBe(false);
  });
});

describe("on a phone on Baker Island (UTC-12)", () => {
  useDeviceZone("Etc/GMT+12");

  // Sunday 00:30 in Los Angeles is Saturday 20:30 on Baker Island.
  it("washes out Saturday's chips, and not Sunday's, just after midnight", () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-03-08T00:30:00-08:00"));
    const container = drawCalendar(
      "2026-03-08",
      month(2026, 3, [
        event(
          "Sat dinner",
          "2026-03-07T19:00:00.000-08:00",
          "2026-03-07T20:00:00.000-08:00",
        ),
        event(
          "Sun breakfast",
          "2026-03-08T09:00:00.000-07:00",
          "2026-03-08T10:00:00.000-07:00",
        ),
      ]),
    );
    expect(todayCell(container)).toBe("08");
    expect(chipDay(container, "Sun breakfast")).toBe("08");
    expect(dimmed(container, "Sat dinner")).toBe(true);
    expect(dimmed(container, "Sun breakfast")).toBe(false);
  });

  // The day numbers are links. Midnight on Mar 20 in UTC is noon on
  // Mar 19 on Baker Island.
  it("goes to the day whose number was clicked", async () => {
    drawCalendar("2026-03-15", month(2026, 3, []));
    fireEvent.click(screen.getByRole("button", { name: "20" }));
    expect(screen.getByTestId("where")).toHaveTextContent(
      /^\/calendar\/all\/2026-03-20$/,
    );
    // When the address changes, the calendar writes a timing report to
    // the console two animation frames later (nav_trace.js), and this
    // is the file's last test. Without this wait, the report could come
    // after the file had ended, while Vitest was closing the worker's
    // connection, and Vitest 5 then fails the run with "Closing rpc
    // while onUserConsoleLog was pending".
    await new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    });
  });
});
