import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { stage } from "../helpers/create_data_store.js";

// Mock external modules before importing stores (same set as the
// data_store tests — the real DataStore pulls all of these in).
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import { DataStore } from "../../../app/frontend/src/stores/data_store.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import AttendeesBox, {
  AttendeeComponent,
} from "../../../app/frontend/src/components/meal/attendees_box.jsx";

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
  stage(store, () => {
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

  it("renders no rows while the store has no meal", () => {
    const store = defaultStore();
    renderBox(store);
    expect(
      screen.getByRole("cell", { name: "Jane Smith" }),
    ).toBeInTheDocument();

    act(() => {
      stage(store, () => {
        store.meal = null;
      });
    });
    expect(
      screen.queryByRole("cell", { name: "Jane Smith" }),
    ).not.toBeInTheDocument();
  });

  // A row handed a node that has already been removed from the tree
  // renders nothing instead of reading a dead node.
  it("a row for a dead node renders nothing", () => {
    const store = defaultStore();
    const jane = store.residents.get("1");
    stage(store, () => {
      store.residents.delete("1");
    });
    const { container } = render(
      <StoreContext.Provider value={store}>
        <table>
          <tbody>
            <AttendeeComponent resident={jane} />
          </tbody>
        </table>
      </StoreContext.Provider>,
    );
    expect(container.querySelector("tr")).not.toBeInTheDocument();
  });

  it("shows a veg guest badge", () => {
    renderBox(
      createDataStore({
        residents: [{ id: 2, meal_id: 1, name: "Bob Johnson" }],
        guests: [
          {
            id: 101,
            meal_id: 1,
            resident_id: 2,
            vegetarian: true,
            created_at: Date.now(),
          },
        ],
      }),
    );
    const bobRow = screen
      .getByRole("cell", { name: "Bob Johnson" })
      .closest("tr");
    expect(bobRow.querySelector('img[alt="carrot-icon"]')).toBeInTheDocument();
  });

  it("the switches and the remove button reach the store", async () => {
    const store = defaultStore();
    renderBox(store);
    const bob = store.residents.get("2");

    fireEvent.click(screen.getByLabelText("Toggle Late for Bob Johnson"));
    expect(bob.late).toBe(true);

    fireEvent.click(screen.getByLabelText("Toggle Veg for Bob Johnson"));
    expect(bob.vegetarian).toBe(false);

    // The guest row goes when the server confirms the delete.
    expect(store.guests.size).toBe(1);
    fireEvent.click(screen.getByLabelText("Remove Guest of Jane Smith"));
    await vi.waitFor(() => {
      expect(store.guests.size).toBe(0);
    });
  });

  // A closed meal: a resident who signed up before the close cannot
  // change their signup, and one who is not signed up can only join
  // while a seat is left.
  describe("a closed meal", () => {
    function closedStore(extras) {
      return createDataStore({
        mealProps: {
          closed: true,
          closed_at: new Date("2026-01-14T12:00:00Z"),
          extras: extras,
        },
        residents: [
          {
            id: 1,
            meal_id: 1,
            name: "Jane Smith",
            attending: true,
            attending_at: new Date("2026-01-14T10:00:00Z"),
          },
          { id: 2, meal_id: 1, name: "Bob Johnson" },
        ],
      });
    }

    it("locks a signup made before the close, and the rest when no seat is left", () => {
      renderBox(closedStore(0));
      expect(screen.getByLabelText("Toggle Veg for Jane Smith")).toBeDisabled();
      expect(
        screen.getByLabelText("Toggle Late for Bob Johnson"),
      ).toBeDisabled();
      expect(
        screen.getByLabelText("Toggle Veg for Bob Johnson"),
      ).toBeDisabled();
    });

    it("leaves the switches open for someone who can still join", () => {
      renderBox(closedStore(2));
      expect(
        screen.getByLabelText("Toggle Late for Bob Johnson"),
      ).toBeEnabled();
      expect(screen.getByLabelText("Toggle Veg for Bob Johnson")).toBeEnabled();
    });
  });

  it("dims a name that is not attending once the meal is reconciled", () => {
    renderBox(
      createDataStore({
        mealProps: { closed: true, reconciled: true },
        residents: [{ id: 2, meal_id: 1, name: "Bob Johnson" }],
      }),
    );
    const bob = screen.getByRole("cell", { name: "Bob Johnson" });
    expect(bob.style.color).toBe("var(--gray-11)");
    expect(bob.style.filter).toBe("");
  });
});
