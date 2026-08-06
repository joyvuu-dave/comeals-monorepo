import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

// Mock external modules before importing stores (same set as the
// data_store tests — the real DataStore pulls all of these in).
vi.mock("axios", () => {
  const mockAxios = vi.fn(() => Promise.resolve({ status: 200 }));
  mockAxios.get = vi.fn(() => Promise.resolve({ status: 200, data: {} }));
  mockAxios.interceptors = {
    response: { use: vi.fn(), eject: vi.fn() },
    request: { use: vi.fn() },
  };
  return { default: mockAxios };
});

vi.mock("js-cookie", () => ({
  default: {
    get: vi.fn((name) => {
      const cookies = {
        token: "test-token",
        community_id: "test-community-id",
        timezone: "America/Los_Angeles",
      };
      return cookies[name];
    }),
    remove: vi.fn(),
    set: vi.fn(),
  },
}));

vi.mock("pusher-js", () => {
  class MockPusher {
    constructor() {
      this.connection = {
        bind: vi.fn(),
        socket_id: "test-socket",
      };
      this.subscribe = vi.fn(() => ({ bind: vi.fn(), name: "test-channel" }));
      this.unsubscribe = vi.fn();
    }
  }
  return { default: MockPusher };
});

vi.mock("idb-keyval", () => ({
  get: vi.fn(() => Promise.resolve(undefined)),
  set: vi.fn(() => Promise.resolve()),
  del: vi.fn(() => Promise.resolve()),
  clear: vi.fn(() => Promise.resolve()),
}));

vi.mock("uuid", () => {
  let counter = 0;
  return {
    v4: vi.fn(() => "test-uuid-" + ++counter),
  };
});

import { unprotect } from "mobx-state-tree";
import { runInAction } from "mobx";
import { DataStore } from "../../../app/frontend/src/stores/data_store.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import AttendeesBox from "../../../app/frontend/src/components/meal/attendees_box.jsx";

// AttendeeComponent calls isAlive() on each resident, so the rows must
// be real mobx-state-tree nodes — a plain observable stub throws. Same
// build-up as the data_store tests.
function createDataStore(opts = {}) {
  const { mealProps = {}, residents = [], guests = [] } = opts;
  const mealDefaults = { id: 1, ...mealProps };

  const store = DataStore.create({
    meals: [mealDefaults],
    meal: mealDefaults.id,
  });

  unprotect(store);
  runInAction(() => {
    residents.forEach((r) => store.residents.put(r));
    guests.forEach((g) => store.guests.put(g));
  });

  return store;
}

function renderBox(store) {
  return render(
    <StoreContext.Provider value={store}>
      <AttendeesBox />
    </StoreContext.Provider>,
  );
}

function defaultStore() {
  return createDataStore({
    residents: [
      {
        id: 1,
        meal_id: 1,
        name: "Jane Smith",
        attending: true,
        attending_at: new Date("2026-01-14T18:30:00Z"),
      },
      { id: 2, meal_id: 1, name: "Bob Johnson", vegetarian: true },
      {
        id: 3,
        meal_id: 1,
        name: "Alice Williams",
        attending: true,
        attending_at: new Date("2026-01-14T19:00:00Z"),
        late: true,
      },
    ],
    guests: [
      {
        id: 100,
        meal_id: 1,
        resident_id: 1,
        vegetarian: false,
        created_at: Date.now(),
      },
    ],
  });
}

describe("AttendeesBox", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    Object.defineProperty(globalThis, "navigator", {
      value: { onLine: true },
      writable: true,
      configurable: true,
    });
  });

  it("lists every resident with attendance shown in green", () => {
    renderBox(defaultStore());

    const jane = screen.getByRole("cell", { name: "Jane Smith" });
    const bob = screen.getByRole("cell", { name: "Bob Johnson" });
    expect(jane).toHaveClass("background-green");
    expect(bob).not.toHaveClass("background-green");
  });

  it("shows switch states and guest badges from the store", () => {
    renderBox(defaultStore());

    expect(
      screen.getByLabelText("Toggle Late for Alice Williams"),
    ).toBeChecked();
    expect(
      screen.getByLabelText("Toggle Late for Jane Smith"),
    ).not.toBeChecked();
    expect(screen.getByLabelText("Toggle Veg for Bob Johnson")).toBeChecked();

    // Jane's one meat guest: a cow badge in her row.
    const janeRow = screen
      .getByRole("cell", { name: "Jane Smith" })
      .closest("tr");
    expect(janeRow.querySelector('img[alt="cow-icon"]')).toBeInTheDocument();
    const bobRow = screen
      .getByRole("cell", { name: "Bob Johnson" })
      .closest("tr");
    expect(bobRow.querySelector(".badge img")).not.toBeInTheDocument();
  });

  it("clicking a name toggles attendance optimistically", () => {
    renderBox(defaultStore());

    const bob = screen.getByRole("cell", { name: "Bob Johnson" });
    fireEvent.click(bob);
    expect(bob).toHaveClass("background-green");
  });

  it("disables the remove-guest button for residents without guests", () => {
    renderBox(defaultStore());

    expect(
      screen.getByLabelText("Remove Guest of Jane Smith"),
    ).not.toBeDisabled();
    expect(screen.getByLabelText("Remove Guest of Bob Johnson")).toBeDisabled();
  });

  it("freezes every control once the meal is reconciled", () => {
    renderBox(
      createDataStore({
        mealProps: { closed: true, reconciled: true },
        residents: [
          {
            id: 1,
            meal_id: 1,
            name: "Jane Smith",
            attending: true,
            attending_at: new Date("2026-01-14T18:30:00Z"),
          },
        ],
      }),
    );

    expect(screen.getByLabelText("Toggle Late for Jane Smith")).toBeDisabled();
    expect(screen.getByLabelText("Toggle Veg for Jane Smith")).toBeDisabled();
    expect(screen.getByLabelText("Remove Guest of Jane Smith")).toBeDisabled();
  });
});
