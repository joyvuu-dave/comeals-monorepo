import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act, fireEvent } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import {
  MemoryRouter,
  Route,
  Routes,
  useLocation,
  useNavigate,
} from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));
vi.mock("../../../app/frontend/src/helpers/bugsnag", () => ({
  notifyError: vi.fn(),
}));

import Cookie from "js-cookie";
import BackToToday from "../../../app/frontend/src/components/app/back_to_today";
import ErrorBoundary from "../../../app/frontend/src/components/app/error_boundary.jsx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { IDLE_MS } from "../../../app/frontend/src/helpers/screen_home";
import toastStore from "../../../app/frontend/src/stores/toast_store";
import { createDataStore, stubAction } from "../helpers/create_data_store.js";
import { useDeviceZone } from "../helpers/device_zone.js";
import { fakeLocation } from "../helpers/fake_location.js";

// BackToToday brings the shared screen back to today's calendar: five
// minutes after the last touch, mouse, key or scroll, and after the page
// loads or changes; and at the community's midnight, when the calendar
// shows the month that held the old day. It moves inside the app, with
// no page load, except on a crashed page and on old code after a deploy
// ("a page load in place of a move"). The rules for where it goes are
// pinned in tests/unit/helpers/screen_home.test.ts; these tests pin
// when.

// The community is in Los Angeles (the cookie fixture). Oct 10, 2026 at
// noon there.
const NOON = "2026-10-10T12:00:00-07:00";
const HOME = "/calendar/all/2026-10-10/";
const MEAL = "/meals/42/edit/";

// The page the router shows, and a count of its navigations: each one
// has its own key.
function LocationEcho() {
  const location = useLocation();
  return (
    <span data-testid="location" data-key={location.key}>
      {location.pathname}
    </span>
  );
}

// Lets a test change the page with no DOM event, which would count as
// activity by itself.
let navigateFromTest;
function Navigator() {
  navigateFromTest = useNavigate();
  return null;
}

function where() {
  return screen.getByTestId("location").textContent;
}

function navigationKey() {
  return screen.getByTestId("location").dataset.key;
}

// The page the router starts on. A list of pages is the history, and
// the router starts on the last one.
function renderAt(path, store = observable({ communityToday: "2026-10-10" })) {
  const entries = Array.isArray(path) ? path : [path];
  render(
    <MemoryRouter initialEntries={entries} initialIndex={entries.length - 1}>
      <BackToToday store={store} />
      <LocationEcho />
      <Navigator />
      <div data-testid="scroller" />
    </MemoryRouter>,
  );
  return store;
}

function wait(ms) {
  act(() => {
    vi.advanceTimersByTime(ms);
  });
}

describe("BackToToday", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(NOON));
  });

  afterEach(() => {
    delete window.__COMEALS_NO_IDLE_TIMER__;
    toastStore.clearAll();
    vi.useRealTimers();
  });

  describe("the idle timer", () => {
    // Before, the timer started only at the first touch, so a page
    // loaded with nobody there (Refresh after a deploy, a browser that
    // reopens its last page) never went home.
    it("counts the page load as activity: a page nobody touches goes home five minutes after it loads", () => {
      renderAt(MEAL);

      wait(IDLE_MS - 1);
      expect(where()).toBe(MEAL);

      wait(1);
      expect(where()).toBe(HOME);
    });

    it.each([
      ["a mouse move", (el) => fireEvent.mouseMove(el)],
      ["a mouse press", (el) => fireEvent.mouseDown(el)],
      ["a click", (el) => fireEvent.click(el)],
      ["a touch", (el) => fireEvent.touchStart(el)],
      ["a key", (el) => fireEvent.keyDown(el, { key: "a" })],
      // A scroll inside an element does not bubble, so it is caught on
      // its way down.
      ["a scroll inside the page", (el) => fireEvent.scroll(el)],
    ])("%s starts the five minutes again", (_name, act_) => {
      renderAt(MEAL);
      wait(IDLE_MS - 1000);

      act_(screen.getByTestId("scroller"));
      wait(IDLE_MS - 1);
      expect(where()).toBe(MEAL);

      wait(1);
      expect(where()).toBe(HOME);
    });

    it("does not count a modifier key alone", () => {
      renderAt(MEAL);
      wait(IDLE_MS - 1000);

      ["Shift", "Control", "Alt", "Meta"].forEach((key) =>
        fireEvent.keyDown(screen.getByTestId("scroller"), { key }),
      );
      wait(1000);
      expect(where()).toBe(HOME);
    });

    it("counts a page change as activity", () => {
      renderAt(MEAL);
      wait(IDLE_MS - 1000);

      act(() => navigateFromTest("/meals/43/edit/"));
      wait(IDLE_MS - 1);
      expect(where()).toBe("/meals/43/edit/");

      wait(1);
      expect(where()).toBe(HOME);
    });

    // The store's day is moved by a timer, and a device that slept can
    // wake with that timer late. The trip home reads the clock itself.
    it("goes to the day the clock says, not the store's day", () => {
      renderAt(MEAL, observable({ communityToday: "2026-10-09" }));

      wait(IDLE_MS);
      expect(where()).toBe(HOME);
    });

    it("does nothing on the calendar of today's month, and keeps counting after a later page change", () => {
      renderAt("/calendar/all/2026-10-01/");
      const key = navigationKey();

      wait(IDLE_MS * 3);
      expect(where()).toBe("/calendar/all/2026-10-01/");
      expect(navigationKey()).toBe(key);

      act(() => navigateFromTest("/calendar/all/2026-12-01/"));
      wait(IDLE_MS);
      expect(where()).toBe(HOME);
    });

    // ADR 0006: an open form is a draft. The timer must not close it.
    it("leaves an open calendar form alone", () => {
      renderAt("/calendar/all/2026-12-01/events/edit/5/");

      wait(IDLE_MS * 2);
      expect(where()).toBe("/calendar/all/2026-12-01/events/edit/5/");
    });

    // The trip home is a move inside the app, so the stack of messages
    // is not drawn again from nothing: an error stays until a person
    // closes it (#137).
    it("keeps the messages on screen", () => {
      renderAt(MEAL);
      toastStore.show("Costs not saved for Tue, Oct 6th.", "error");

      wait(IDLE_MS);
      expect(where()).toBe(HOME);
      expect(toastStore.toasts.map((toast) => toast.message)).toEqual([
        "Costs not saved for Tue, Oct 6th.",
      ]);
    });

    // A reset link's page holds the new password someone may be typing.
    it("leaves a signed-out page alone", () => {
      Cookie.remove("token");
      renderAt("/reset-password/abc123/");

      wait(IDLE_MS * 2);
      expect(where()).toBe("/reset-password/abc123/");
    });

    // tests/helpers/browser_setup.js sets this flag, so the browser
    // tests are not sent home in the middle of a test.
    it("is off when the browser tests turn it off", () => {
      window.__COMEALS_NO_IDLE_TIMER__ = true;
      renderAt(MEAL);

      wait(IDLE_MS * 2);
      fireEvent.mouseMove(screen.getByTestId("scroller"));
      wait(IDLE_MS * 2);
      expect(where()).toBe(MEAL);
    });

    it("stops when the app goes away", () => {
      const { unmount } = render(
        <MemoryRouter initialEntries={[MEAL]}>
          <BackToToday store={observable({ communityToday: "2026-10-10" })} />
        </MemoryRouter>,
      );
      const timersBefore = vi.getTimerCount();

      unmount();
      expect(vi.getTimerCount()).toBe(timersBefore - 1);
    });
  });

  // Two things a move inside the app cannot fix: a crashed page, whose
  // error page stays when the address changes, and old code after a
  // deploy. For those the timer loads today's calendar from the server,
  // once the bills saves on their way are answered (#150).
  describe("a page load in place of a move", () => {
    let location;
    let restoreLocation;

    beforeEach(() => {
      ({ location, restore: restoreLocation } = fakeLocation({
        assign: vi.fn(),
      }));
    });

    afterEach(() => {
      restoreLocation();
    });

    // A store as the timer reads it. The test changes the two flags.
    function screenStore(saved = true) {
      const finishBillsSaves = vi.fn(() => Promise.resolve(saved));
      return observable(
        {
          communityToday: "2026-10-10",
          pageCrashed: false,
          newVersionAvailable: false,
          finishBillsSaves,
        },
        { finishBillsSaves: false },
      );
    }

    function note(store, flag) {
      act(() => {
        runInAction(() => {
          store[flag] = true;
        });
      });
    }

    // The microtasks of the wait for the bills saves run too.
    async function waitAndSettle(ms) {
      await act(async () => {
        await vi.advanceTimersByTimeAsync(ms);
      });
    }

    it("loads today's calendar five minutes after a crash, once the bills saves are answered", async () => {
      const store = renderAt(MEAL, screenStore());
      wait(IDLE_MS - 1000);
      note(store, "pageCrashed");

      await waitAndSettle(IDLE_MS - 1);
      expect(location.assign).not.toHaveBeenCalled();

      await waitAndSettle(1);
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(location.assign).toHaveBeenCalledWith(HOME);
      // A load, not a move as well.
      expect(where()).toBe(MEAL);
    });

    // The timer runs out once and then waits for the next touch. A
    // crash after that, with nobody there, starts the five minutes
    // again, so the error page does not stay on screen until someone
    // touches it.
    it("starts the five minutes again at a crash on the calendar of today's month", async () => {
      const store = renderAt("/calendar/all/2026-10-01/", screenStore());
      await waitAndSettle(IDLE_MS * 2);
      expect(location.assign).not.toHaveBeenCalled();

      note(store, "pageCrashed");
      await waitAndSettle(IDLE_MS);
      expect(location.assign).toHaveBeenCalledWith(HOME);
    });

    // The message of the save that failed is on screen. A load would
    // take it away before anyone read it.
    it("stays when a save it waited for was not saved", async () => {
      const store = renderAt(MEAL, screenStore(false));
      note(store, "pageCrashed");

      await waitAndSettle(IDLE_MS);
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(location.assign).not.toHaveBeenCalled();
    });

    // #137: an error stays until a person closes it. Closing it is a
    // tap, which starts the five minutes again.
    it("waits while an error message is on screen, and loads five minutes after it is closed", async () => {
      toastStore.show("Costs not saved for Tue, Oct 6th.", "error");
      const store = renderAt(MEAL, screenStore());
      note(store, "pageCrashed");

      await waitAndSettle(IDLE_MS);
      expect(store.finishBillsSaves).not.toHaveBeenCalled();
      expect(location.assign).not.toHaveBeenCalled();
      // The move inside the app still happens. The error page stays.
      expect(where()).toBe(HOME);

      fireEvent.click(screen.getByTestId("scroller"));
      act(() => toastStore.clearAll());
      await waitAndSettle(IDLE_MS);
      expect(location.assign).toHaveBeenCalledWith(HOME);
    });

    // A message that is not an error closes by itself in a few seconds.
    it("does not wait for a message that is not an error", async () => {
      const store = renderAt(MEAL, screenStore());
      note(store, "pageCrashed");
      wait(IDLE_MS - 1000);
      act(() => toastStore.show("Saved.", "success"));

      await waitAndSettle(1000);
      expect(toastStore.toasts).toHaveLength(1);
      expect(location.assign).toHaveBeenCalledWith(HOME);
    });

    // The screen nobody uses gets the new code five minutes after the
    // banner saw it, even on the calendar of today's month.
    it("loads today's calendar five minutes after a new version is out", async () => {
      const store = renderAt("/calendar/all/2026-10-01/", screenStore());
      await waitAndSettle(IDLE_MS * 2);

      note(store, "newVersionAvailable");
      await waitAndSettle(IDLE_MS - 1);
      expect(location.assign).not.toHaveBeenCalled();

      await waitAndSettle(1);
      expect(location.assign).toHaveBeenCalledWith(HOME);
    });

    // ADR 0006: a form is a draft until Create or Update.
    it("does not load a new version over an open calendar form", async () => {
      const store = renderAt(
        "/calendar/all/2026-10-01/events/new/",
        screenStore(),
      );
      note(store, "newVersionAvailable");

      await waitAndSettle(IDLE_MS * 2);
      expect(store.finishBillsSaves).not.toHaveBeenCalled();
      expect(location.assign).not.toHaveBeenCalled();
      expect(where()).toBe("/calendar/all/2026-10-01/events/new/");
    });

    // Login loads the page again by itself.
    it("does not load a new version on a signed-out page", async () => {
      Cookie.remove("token");
      const store = renderAt("/reset-password/abc123/", screenStore());
      note(store, "newVersionAvailable");

      await waitAndSettle(IDLE_MS * 2);
      expect(location.assign).not.toHaveBeenCalled();
    });

    // The error page and the timer, as index.jsx puts them together.
    // Before, the timer moved the address to today's calendar and the
    // error page stayed.
    describe("with the real store and error page", () => {
      let store;

      beforeEach(() => {
        vi.stubEnv("VITE_PUSHER_KEY", "test-key");
        vi.spyOn(console, "error").mockImplementation(() => {});
      });

      afterEach(() => {
        store.beforeDestroy();
        vi.unstubAllEnvs();
        vi.restoreAllMocks();
      });

      function Boom() {
        throw new Error("a render error on the meal page");
      }

      it("a crashed meal page loads today's calendar after five idle minutes", async () => {
        store = createDataStore();
        render(
          <StoreContext.Provider value={store}>
            <MemoryRouter initialEntries={[MEAL]}>
              <BackToToday store={store} />
              <LocationEcho />
              <ErrorBoundary>
                <Routes>
                  <Route path="/meals/:id/edit/*" element={<Boom />} />
                </Routes>
              </ErrorBoundary>
            </MemoryRouter>
          </StoreContext.Provider>,
        );
        expect(
          screen.getByText("Something went wrong with Comeals."),
        ).toBeInTheDocument();
        expect(store.pageCrashed).toBe(true);

        await waitAndSettle(IDLE_MS);
        expect(location.assign).toHaveBeenCalledWith(HOME);
      });
    });
  });

  describe("a new day", () => {
    function newDay(store, day) {
      act(() => {
        runInAction(() => {
          store.communityToday = day;
        });
      });
    }

    it("moves the calendar of the old day's month to the new day's month, in place of the old address", () => {
      const store = renderAt([MEAL, "/calendar/all/2026-10-15/"]);
      store.communityToday = "2026-10-31";

      newDay(store, "2026-11-01");
      expect(where()).toBe("/calendar/all/2026-11-01/");

      // Back goes to the page before the calendar, not to the old month.
      act(() => navigateFromTest(-1));
      expect(where()).toBe(MEAL);
    });

    it("leaves a calendar of another month, and an open form, where they are", () => {
      const store = renderAt("/calendar/all/2026-12-01/");
      newDay(store, "2026-11-01");
      expect(where()).toBe("/calendar/all/2026-12-01/");

      act(() =>
        navigateFromTest(
          "/calendar/all/2026-11-20/guest-room-reservations/new",
        ),
      );
      newDay(store, "2026-12-01");
      expect(where()).toBe(
        "/calendar/all/2026-11-20/guest-room-reservations/new",
      );
    });
  });
});

// The day is the community's (Los Angeles), whatever the device's own
// zone. Los Angeles changes its clocks at 2am on Mar 8 and Nov 1, 2026,
// and Nov 1 is also the first of a month.
describe.each([
  "Pacific/Honolulu",
  "America/Los_Angeles",
  "America/New_York",
  "UTC",
  "Europe/London",
  "Asia/Tokyo",
])("on a device in %s", (deviceZone) => {
  useDeviceZone(deviceZone);

  let store;

  beforeEach(() => {
    vi.stubEnv("VITE_PUSHER_KEY", "test-key");
    vi.useFakeTimers();
  });

  afterEach(() => {
    if (store) store.beforeDestroy();
    store = undefined;
    vi.useRealTimers();
    vi.unstubAllEnvs();
  });

  function startAt(instant, path) {
    vi.setSystemTime(new Date(instant));
    store = createDataStore();
    stubAction(store, "loadMonthAsync");
    renderAt(path, store);
  }

  function runUntil(instant) {
    act(() => {
      vi.advanceTimersByTime(Date.parse(instant) - Date.now());
    });
  }

  // 23:57 on Oct 31 is Nov 1 already in New York, London and Tokyo.
  it("goes home to Oct 31 five minutes before the fall-back midnight, and to Nov 1 after it", () => {
    startAt("2026-10-31T23:54:00-07:00", MEAL);
    runUntil("2026-10-31T23:59:00-07:00");
    expect(where()).toBe("/calendar/all/2026-10-31/");

    // The midnight moves October to November.
    runUntil("2026-11-01T00:00:01-07:00");
    expect(where()).toBe("/calendar/all/2026-11-01/");
  });

  // The first 1:30 of the 25-hour day is PDT, the second PST.
  it("goes home to Nov 1 from the October calendar in the hour that repeats", () => {
    startAt("2026-11-01T01:30:00-08:00", "/calendar/all/2026-10-15/");
    runUntil("2026-11-01T01:35:00-08:00");
    expect(where()).toBe("/calendar/all/2026-11-01/");
  });

  // 2:00 to 3:00 does not happen on the spring-forward day.
  it("goes home to Mar 8 across the hour the clocks skip", () => {
    startAt("2026-03-08T01:58:00-08:00", "/calendar/all/2026-02-15/");
    runUntil("2026-03-08T03:03:00-07:00");
    expect(where()).toBe("/calendar/all/2026-03-08/");
  });

  it("leaves the March calendar where it is at the spring-forward midnight, and the one after", () => {
    window.__COMEALS_NO_IDLE_TIMER__ = true;
    startAt("2026-03-07T23:59:00-08:00", "/calendar/all/2026-03-07/");

    runUntil("2026-03-08T00:00:01-08:00");
    expect(store.communityToday).toBe("2026-03-08");
    runUntil("2026-03-09T00:00:01-07:00");
    expect(store.communityToday).toBe("2026-03-09");
    expect(where()).toBe("/calendar/all/2026-03-07/");
    delete window.__COMEALS_NO_IDLE_TIMER__;
  });
});
