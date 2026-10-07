import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, fireEvent, act, within } from "@testing-library/react";
import { stage } from "../helpers/create_data_store.js";

// Mock external modules before importing stores (same set as the
// data_store tests — the real DataStore pulls all of these in).
vi.mock("axios", () => import("../mocks/axios.js"));

vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));

vi.mock("pusher-js", () => import("../mocks/pusher.js"));

vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import { stubRandomUUID } from "../mocks/uuid.js";
stubRandomUUID();

import { DataStore } from "../../../app/frontend/src/stores/data_store.js";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
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

// What the server answers for an attendance add, in the shape
// MealResidentSerializer sends; the store reads its created_at.
function mealResidentAnswer(residentId) {
  return {
    status: 200,
    data: {
      id: 900 + residentId,
      meal_id: 1,
      resident_id: residentId,
      late: false,
      vegetarian: false,
      created_at: "2026-01-14T13:00:00Z",
    },
  };
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

  // A retired resident is in the meal form only because they ate or
  // because they cooked (MealFormSerializer, #91). The sign-up list
  // shows them only when they are signed up for this meal: a retired
  // cook who did not eat must not show as someone to sign up.
  it("lists a retired resident only when signed up for this meal", () => {
    renderBox(
      createDataStore({
        residents: [
          { id: 1, meal_id: 1, name: "Jane Smith" },
          {
            id: 4,
            meal_id: 1,
            name: "Rita Retired",
            active: false,
            attending: true,
            attending_at: new Date("2026-01-14T18:30:00Z"),
          },
          { id: 5, meal_id: 1, name: "Carol Cook", active: false },
        ],
      }),
    );

    expect(screen.getByRole("cell", { name: "Jane Smith" })).toBeVisible();
    expect(screen.getByRole("cell", { name: "Rita Retired" })).toBeVisible();
    expect(
      screen.queryByRole("cell", { name: "Carol Cook" }),
    ).not.toBeInTheDocument();
  });

  // The tests below load the meal the way the page does, with loadData,
  // because the list reads what the load saw.
  describe("a retired resident tapped off by mistake", () => {
    // One resident row as the meal form sends it.
    function residentRow(id, name, overrides = {}) {
      return {
        id,
        meal_id: 1,
        name,
        short_name: name,
        attending: false,
        attending_at: null,
        late: false,
        vegetarian: false,
        can_cook: true,
        active: true,
        ...overrides,
      };
    }

    // The meal form as the server sends it (MealFormSerializer). Jane is
    // active. Rita is retired, and signed up for this meal unless the
    // test says otherwise. Carol is retired and did not eat: the form
    // lists her only because she cooked (#91).
    function mealForm({ ritaAttending = true, guests = [] } = {}) {
      return {
        id: 1,
        date: "2026-01-14",
        description: "",
        closed: false,
        closed_at: null,
        reconciled: false,
        max: null,
        next_id: 1,
        prev_id: 1,
        residents: [
          residentRow(1, "Jane Smith"),
          residentRow(4, "Rita Retired", {
            active: false,
            attending: ritaAttending,
            attending_at: ritaAttending ? "2026-01-14T18:30:00Z" : null,
          }),
          residentRow(5, "Carol Cook", { active: false }),
        ],
        guests,
        bills: [{ resident_id: 5, amount: "40", no_cost: false }],
      };
    }

    function loadedStore(form) {
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(form, "server");
      return store;
    }

    // Nobody can sign up a retired resident who is not on the list. So
    // if a wrong tap took the row away, the mistake could not be undone
    // from this page, and their guest's remove button would go with it.
    it("keeps the row after a tap takes them off, so a second tap signs them up again", async () => {
      const store = loadedStore(
        mealForm({
          guests: [
            {
              id: 100,
              meal_id: 1,
              resident_id: 4,
              vegetarian: false,
              created_at: "2026-01-14T18:40:00Z",
            },
          ],
        }),
      );
      renderBox(store);

      fireEvent.click(screen.getByRole("cell", { name: "Rita Retired" }));
      await act(async () => {});

      expect(store.residents.get("4").attending).toBe(false);
      const rita = screen.getByRole("cell", { name: "Rita Retired" });
      expect(rita).not.toHaveClass("background-green");
      expect(
        screen.getByLabelText("Remove Guest of Rita Retired"),
      ).toBeEnabled();

      axios.mockResolvedValueOnce(mealResidentAnswer(4));
      fireEvent.click(rita);
      await act(async () => {});

      expect(rita).toHaveClass("background-green");
      expect(store.residents.get("4").attending).toBe(true);
      expect(axios).toHaveBeenLastCalledWith(
        expect.objectContaining({
          method: "post",
          url: "/api/v1/meals/1/residents/4",
        }),
      );
      // Carol was not signed up when the meal was loaded, so she is not
      // on the list.
      expect(
        screen.queryByRole("cell", { name: "Carol Cook" }),
      ).not.toBeInTheDocument();
    });

    // The row stays only until the next load. A load where they are not
    // signed up shows the list without them.
    it("drops the row at the next load if they are no longer signed up", async () => {
      const store = loadedStore(mealForm());
      renderBox(store);

      fireEvent.click(screen.getByRole("cell", { name: "Rita Retired" }));
      await act(async () => {});
      expect(
        screen.getByRole("cell", { name: "Rita Retired" }),
      ).toBeInTheDocument();

      act(() => {
        store.loadData(mealForm({ ritaAttending: false }), "server");
      });

      expect(
        screen.queryByRole("cell", { name: "Rita Retired" }),
      ).not.toBeInTheDocument();
      expect(screen.getByRole("cell", { name: "Jane Smith" })).toBeVisible();
    });
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

  it("clicking a name toggles attendance optimistically", async () => {
    toastStore.clearAll();
    const store = defaultStore();
    axios.mockResolvedValueOnce(mealResidentAnswer(2));
    renderBox(store);

    const bob = screen.getByRole("cell", { name: "Bob Johnson" });
    fireEvent.click(bob);
    expect(bob).toHaveClass("background-green");

    // The server's yes keeps it, with the server's sign-up time.
    await act(async () => {});
    expect(bob).toHaveClass("background-green");
    expect(store.residents.get("2").attending_at).toEqual(
      new Date("2026-01-14T13:00:00Z"),
    );
    expect(toastStore.toasts).toHaveLength(0);
  });

  // An open meal has no seat count (extras is null), and anyone can
  // join it.
  it("leaves every control usable for someone not attending an open meal", () => {
    const store = defaultStore();
    renderBox(store);
    expect(store.meal.extras).toBeNull();
    const bob = screen.getByRole("cell", { name: "Bob Johnson" });
    expect(bob.getAttribute("style")).toBeNull();
    expect(screen.getByLabelText("Toggle Late for Bob Johnson")).toBeEnabled();
    expect(screen.getByLabelText("Toggle Veg for Bob Johnson")).toBeEnabled();
    expect(
      screen.getByLabelText("Add Guest of Bob Johnson").closest("button"),
    ).toBeEnabled();
  });

  it("disables the remove-guest button for residents without guests", () => {
    renderBox(defaultStore());

    expect(
      screen.getByLabelText("Remove Guest of Jane Smith"),
    ).not.toBeDisabled();
    expect(screen.getByLabelText("Remove Guest of Bob Johnson")).toBeDisabled();
  });

  // Only the reconciled flag can lock anything here: the meal has seats
  // left, Jane joined after the close and added her guest after it, and
  // Bob can still join. With the flag off the same rows are all usable,
  // so the flag is what locks them.
  it.each([true, false])(
    "reconciled %s: the flag alone locks every control in every row",
    (reconciled) => {
      renderBox(
        createDataStore({
          mealProps: {
            closed: true,
            closed_at: new Date("2026-01-14T12:00:00Z"),
            extras: 2,
            reconciled: reconciled,
          },
          residents: [
            {
              id: 1,
              meal_id: 1,
              name: "Jane Smith",
              attending: true,
              attending_at: new Date("2026-01-14T13:00:00Z"),
            },
            { id: 2, meal_id: 1, name: "Bob Johnson" },
          ],
          guests: [
            {
              id: 100,
              meal_id: 1,
              resident_id: 1,
              vegetarian: false,
              created_at: new Date("2026-01-14T14:00:00Z"),
            },
          ],
        }),
      );

      const controls = [
        screen.getByLabelText("Toggle Late for Jane Smith"),
        screen.getByLabelText("Toggle Veg for Jane Smith"),
        screen.getByLabelText("Add Guest of Jane Smith").closest("button"),
        screen.getByLabelText("Remove Guest of Jane Smith"),
        screen.getByLabelText("Toggle Late for Bob Johnson"),
        screen.getByLabelText("Toggle Veg for Bob Johnson"),
        screen.getByLabelText("Add Guest of Bob Johnson").closest("button"),
      ];
      const names = [
        screen.getByRole("cell", { name: "Jane Smith" }),
        screen.getByRole("cell", { name: "Bob Johnson" }),
      ];
      for (const control of controls) {
        expect(control.disabled, control.outerHTML).toBe(reconciled);
      }
      for (const name of names) {
        expect(name.style.pointerEvents, name.textContent).toBe(
          reconciled ? "none" : "",
        );
      }
    },
  );

  // pointer-events: none stops a mouse. It does not stop a click event
  // sent to the cell itself, the way a screen reader's activate action
  // or a script sends one. jsdom does not apply pointer-events at all,
  // so this click reaches the handler, and the store must refuse it.
  it("sends nothing for a click sent straight to a name on a reconciled meal", () => {
    renderBox(
      createDataStore({
        mealProps: {
          closed: true,
          closed_at: new Date("2026-01-14T12:00:00Z"),
          extras: 2,
          reconciled: true,
        },
        residents: [
          {
            id: 1,
            meal_id: 1,
            name: "Jane Smith",
            attending: true,
            attending_at: new Date("2026-01-14T13:00:00Z"),
          },
          { id: 2, meal_id: 1, name: "Bob Johnson" },
        ],
      }),
    );
    const jane = screen.getByRole("cell", { name: "Jane Smith" });
    const bob = screen.getByRole("cell", { name: "Bob Johnson" });

    fireEvent.click(jane);
    fireEvent.click(bob);

    expect(axios).not.toHaveBeenCalled();
    expect(jane).toHaveClass("background-green");
    expect(bob).not.toHaveClass("background-green");
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
    toastStore.clearAll();
    const store = defaultStore();
    // Bob is not attending, so his Late switch signs him up.
    axios.mockResolvedValueOnce(mealResidentAnswer(2));
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

    // The server said yes to all three, so nothing was rolled back.
    expect(bob.attending).toBe(true);
    expect(bob.late).toBe(true);
    expect(bob.vegetarian).toBe(false);
    expect(bob.attending_at).toEqual(new Date("2026-01-14T13:00:00Z"));
    expect(toastStore.toasts).toHaveLength(0);
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

    // The real store and the guest menu together (issue #116): on the
    // shared screen, Jane's guest menu is open when Bob takes the last
    // seat. Her menu closes, and a tap on its cow sends nothing.
    it("an open guest menu closes when someone takes the last seat", async () => {
      const store = closedStore(1);
      axios.mockResolvedValueOnce(mealResidentAnswer(2));
      renderBox(store);
      const janeAdd = screen.getByLabelText("Add Guest of Jane Smith");
      const janeMenu = janeAdd.closest(".dropdown");
      fireEvent.click(janeAdd);
      expect(janeMenu).toHaveClass("active");

      fireEvent.click(screen.getByRole("cell", { name: "Bob Johnson" }));
      expect(store.meal.extras).toBe(0);
      expect(janeMenu).not.toHaveClass("active");
      expect(janeAdd.closest("button")).toBeDisabled();

      fireEvent.click(within(janeMenu).getByAltText("cow-icon"));
      await act(async () => {});
      expect(axios).toHaveBeenCalledTimes(1);
      expect(store.guests.size).toBe(0);
    });

    it("leaves the switches open for someone who can still join", () => {
      renderBox(closedStore(2));
      expect(
        screen.getByLabelText("Toggle Late for Bob Johnson"),
      ).toBeEnabled();
      expect(screen.getByLabelText("Toggle Veg for Bob Johnson")).toBeEnabled();
    });

    // A tap on the name of someone who cannot join does nothing, so the
    // cell looks locked, by the same rule as that row's switches. A
    // closed meal with no seat count (extras null) has no seat left.
    it.each([0, null])(
      "dims the name of someone who cannot join (extras %s), like their switches",
      (extras) => {
        renderBox(closedStore(extras));
        const bob = screen.getByRole("cell", { name: "Bob Johnson" });
        expect(bob.style.color).toBe("var(--gray-11)");
        expect(bob.style.cursor).toBe("not-allowed");
        expect(bob.style.pointerEvents).toBe("none");
        expect(bob.style.filter).toBe("");
        expect(
          screen.getByLabelText("Toggle Late for Bob Johnson"),
        ).toBeDisabled();
      },
    );

    // The rule is only for someone who is not attending. Jane signed up
    // before the close and cannot back out, but can still say she is
    // late; Carol joined after the close and can still change anything.
    it("does not lock anything more for people already attending", () => {
      const store = closedStore(0);
      stage(store, () => {
        store.residents.put({
          id: 3,
          meal_id: 1,
          name: "Carol Diaz",
          attending: true,
          attending_at: new Date("2026-01-14T13:00:00Z"),
        });
      });
      renderBox(store);
      expect(screen.getByLabelText("Toggle Late for Jane Smith")).toBeEnabled();
      const carol = screen.getByRole("cell", { name: "Carol Diaz" });
      expect(carol.getAttribute("style")).toBeNull();
      expect(screen.getByLabelText("Toggle Late for Carol Diaz")).toBeEnabled();
      expect(screen.getByLabelText("Toggle Veg for Carol Diaz")).toBeEnabled();
    });

    it("leaves the name of someone who can still join looking tappable", async () => {
      const store = closedStore(1);
      axios.mockResolvedValueOnce(mealResidentAnswer(2));
      renderBox(store);
      const bob = screen.getByRole("cell", { name: "Bob Johnson" });
      expect(bob.getAttribute("style")).toBeNull();
      fireEvent.click(bob);
      await act(async () => {});
      expect(bob).toHaveClass("background-green");
      expect(store.residents.get("2").attending).toBe(true);
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
