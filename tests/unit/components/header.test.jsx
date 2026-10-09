import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { observable, runInAction } from "mobx";
import { MemoryRouter, useLocation } from "react-router";

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";
cookies.current = { username: "Jane Smith" };

import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import Header from "../../../app/frontend/src/components/meal/header.jsx";
import { fakeLocation } from "../helpers/fake_location.js";
import FakeResizeObserver, {
  makeTall,
} from "../helpers/fake_resize_observer.js";

function makeStore(overrides = {}) {
  return observable(
    {
      mealLoading: false,
      isOnline: true,
      meal: { date: new Date(2026, 0, 15) },
      logout: vi.fn(),
      ...overrides,
    },
    { logout: false },
  );
}

function LocationEcho() {
  const location = useLocation();
  return <span data-testid="location">{location.pathname}</span>;
}

// Header takes no props: it reads the store and the router. The meal
// page renders it the same way, as a bare <Header />.
function renderHeader(store) {
  return render(
    <MemoryRouter initialEntries={["/meals/42/edit/"]}>
      <StoreContext.Provider value={store}>
        <Header />
      </StoreContext.Provider>
      <LocationEcho />
    </MemoryRouter>,
  );
}

describe("Header", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    FakeResizeObserver.made = [];
    vi.stubGlobal("ResizeObserver", FakeResizeObserver);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // On a phone the header can take two or three lines (#151), and the
  // stack of messages must stop under the meal's date, which is under
  // the header (toast.css). So the header puts its height on the page's
  // root element while it shows.
  it("gives the page its height while it shows, and follows it", () => {
    const { unmount } = renderHeader(makeStore());
    const header = document.querySelector("header");
    const [observer] = FakeResizeObserver.made;
    expect(observer.watching).toEqual([header]);

    function published() {
      return document.documentElement.style.getPropertyValue(
        "--meal-header-height",
      );
    }

    makeTall(header, 36);
    observer.resized();
    expect(published()).toBe("36px");

    makeTall(header, 72);
    observer.resized();
    expect(published()).toBe("72px");

    unmount();
    expect(observer.watching).toEqual([]);
    expect(published()).toBe("");
  });

  it("shows the online state and flips with the store", () => {
    const store = makeStore();
    renderHeader(store);
    expect(screen.getByText("ONLINE")).toBeInTheDocument();

    act(() => {
      runInAction(() => {
        store.isOnline = false;
      });
    });
    expect(screen.getByText("OFFLINE")).toBeInTheDocument();
  });

  it("names the signed-in user on the logout button", () => {
    renderHeader(makeStore());
    expect(
      screen.getByRole("button", { name: "logout Jane Smith" }),
    ).toBeInTheDocument();
  });

  it("Calendar goes back to the meal's calendar day", () => {
    renderHeader(makeStore());
    fireEvent.click(screen.getByRole("button", { name: /Calendar/ }));
    expect(screen.getByTestId("location")).toHaveTextContent(
      "/calendar/all/2026-01-15",
    );
  });

  it("renders the history button bar", () => {
    renderHeader(makeStore());
    expect(screen.getByRole("button", { name: "history" })).toBeInTheDocument();
  });

  // The Calendar button opens today while no meal is on screen. Today
  // is the community's, not the device's (#114). At 10:30 UTC on June 3
  // only Kiritimati (UTC+14) is already on June 4, so the device's date
  // is June 3 wherever this runs.
  describe("today, when no meal is on screen", () => {
    beforeEach(() => {
      vi.useFakeTimers({ now: new Date("2026-06-03T10:30:00Z") });
      cookies.current = {
        username: "Jane Smith",
        timezone: "Pacific/Kiritimati",
      };
    });

    afterEach(() => {
      cookies.current = { username: "Jane Smith" };
      vi.useRealTimers();
    });

    it.each([
      ["while the meal is loading", { mealLoading: true, meal: null }],
      [
        "while a meal is loading over the last one",
        { mealLoading: true, meal: { date: new Date(2026, 0, 15) } },
      ],
      ["when there is no meal", { mealLoading: false, meal: null }],
    ])("Calendar goes to the community's today %s", (_label, state) => {
      renderHeader(makeStore(state));
      fireEvent.click(screen.getByRole("button", { name: /Calendar/ }));
      expect(screen.getByTestId("location")).toHaveTextContent(
        "/calendar/all/2026-06-04",
      );
    });
  });

  it("logout signs out and reloads to the login page", () => {
    const store = makeStore();
    renderHeader(store);
    const { location, restore } = fakeLocation();
    try {
      fireEvent.click(
        screen.getByRole("button", { name: "logout Jane Smith" }),
      );
      expect(store.logout).toHaveBeenCalledTimes(1);
      expect(location.href).toBe("/");
    } finally {
      restore();
    }
  });
});
