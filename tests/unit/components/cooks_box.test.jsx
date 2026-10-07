import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, within } from "@testing-library/react";
import { observable } from "mobx";

// The tests at the end use the real DataStore, which pulls these in
// (same set as the data_store tests).
vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
vi.mock("pusher-js", () => import("../mocks/pusher.js"));
vi.mock("idb-keyval", () => import("../mocks/idb_keyval.js"));

import axios from "axios";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import CooksBox from "../../../app/frontend/src/components/meal/cooks_box.jsx";
import { createDataStore } from "../helpers/create_data_store.js";
import { SAVE_DEBOUNCE_MS } from "../../../app/frontend/src/helpers/helpers.js";

// A stub of the one bill shape CooksBox reads. The real Bill is a
// mobx-state-tree node; the component only touches these fields. The
// `false` annotations stop MobX from wrapping the spies in actions,
// which would hide them from toHaveBeenCalled.
function makeBill(overrides = {}) {
  return observable(
    {
      id: "1",
      resident: { id: 42, name: "Alice R.", plainName: "Alice" },
      resident_id: 42,
      // A row made here, not by a load, so it had no cook at load time.
      loadedCookId: null,
      amount: "",
      no_cost: false,
      costPending: false,
      setResident: vi.fn(),
      setAmount: vi.fn((value) => value),
      normalizeAmountDisplay: vi.fn(),
      toggleNoCost: vi.fn(),
      ...overrides,
    },
    {
      setResident: false,
      setAmount: false,
      normalizeAmountDisplay: false,
      toggleNoCost: false,
    },
  );
}

function makeStore(bills, overrides = {}) {
  return observable(
    {
      meal: { reconciled: false },
      bills: new Map(bills.map((bill) => [bill.id, bill])),
      residents: new Map([
        [42, { id: 42, name: "Alice R.", can_cook: true, active: true }],
        [43, { id: 43, name: "Bob", can_cook: false, active: true }],
      ]),
      flushPendingBillsSave: vi.fn(),
      ...overrides,
    },
    { flushPendingBillsSave: false },
  );
}

function renderBox(store) {
  return render(
    <StoreContext.Provider value={store}>
      <CooksBox />
    </StoreContext.Provider>,
  );
}

describe("CooksBox", () => {
  function makeEditStore(bills, overrides = {}) {
    return makeStore(bills, overrides);
  }

  it("offers only residents who can cook", () => {
    renderBox(makeEditStore([makeBill()]));
    const select = screen.getByRole("combobox", { name: "Select meal cook" });
    const names = within(select)
      .getAllByRole("option")
      .map((option) => option.textContent);
    expect(names).toContain("Alice R.");
    expect(names).not.toContain("Bob");
  });

  // The names a row's cook menu offers.
  function offered(select) {
    return within(select)
      .getAllByRole("option")
      .map((option) => option.textContent);
  }

  // A cook retired after cooking keeps their bill (#91). Their own row
  // shows them; no other row offers them, so nobody can pick them again.
  it("offers a retired cook only in the row of their own bill", () => {
    const carol = { id: 44, name: "Carol R.", plainName: "Carol" };
    const store = makeEditStore(
      [
        makeBill({ id: "1", resident: carol, resident_id: 44 }),
        makeBill({ id: "2", resident: null, resident_id: "" }),
      ],
      {
        residents: new Map([
          [42, { id: 42, name: "Alice R.", can_cook: true, active: true }],
          [44, { id: 44, name: "Carol R.", can_cook: true, active: false }],
        ]),
      },
    );
    renderBox(store);

    const [carolsRow, blankRow] = screen.getAllByRole("combobox", {
      name: "Select meal cook",
    });
    expect(carolsRow).toHaveValue("44");
    expect(carolsRow).toHaveDisplayValue("Carol R.");
    expect(offered(carolsRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R.", "Carol R."]);
    expect(offered(blankRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R."]);
  });

  // The same rule for a cook whose "can cook" was turned off after the
  // bill was made: the row still shows who cooked.
  it("shows a cook who can no longer cook in the row of their own bill", () => {
    const bob = { id: 43, name: "Bob", plainName: "Bob" };
    renderBox(
      makeEditStore([
        makeBill({ id: "1", resident: bob, resident_id: 43 }),
        makeBill({ id: "2", resident: null, resident_id: "" }),
      ]),
    );

    const [bobsRow, blankRow] = screen.getAllByRole("combobox", {
      name: "Select meal cook",
    });
    expect(bobsRow).toHaveDisplayValue("Bob");
    expect(offered(blankRow)).not.toContain("Bob");
  });

  it("freezes every control when the meal is reconciled", () => {
    renderBox(makeEditStore([makeBill()], { meal: { reconciled: true } }));
    expect(
      screen.getByRole("combobox", { name: "Select meal cook" }),
    ).toBeDisabled();
    expect(
      screen.getByRole("spinbutton", { name: "Set meal cost" }),
    ).toBeDisabled();
    expect(screen.getByRole("checkbox")).toBeDisabled();
  });

  it("freezes every control while no meal is loaded", () => {
    renderBox(makeEditStore([makeBill()], { meal: null }));
    expect(
      screen.getByRole("combobox", { name: "Select meal cook" }),
    ).toBeDisabled();
    expect(
      screen.getByRole("spinbutton", { name: "Set meal cost" }),
    ).toBeDisabled();
    expect(screen.getByRole("checkbox")).toBeDisabled();
  });

  it("turning on no-cost over a typed cost asks first instead of erasing", () => {
    const bill = makeBill({ amount: "12.00" });
    renderBox(makeEditStore([bill]));

    fireEvent.click(screen.getByRole("checkbox"));

    expect(bill.toggleNoCost).not.toHaveBeenCalled();
    const confirm = screen.getByRole("alertdialog", {
      name: "Erase Alice's $12.00?",
    });
    expect(confirm).toHaveTextContent("Erase Alice’s $12.00?");
  });

  it("No keeps the typed cost", () => {
    const bill = makeBill({ amount: "12.00" });
    renderBox(makeEditStore([bill]));

    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: "No" }));

    expect(bill.toggleNoCost).not.toHaveBeenCalled();
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  it("turning on no-cost with nothing typed flips right away", () => {
    const bill = makeBill({ amount: "" });
    renderBox(makeEditStore([bill]));

    fireEvent.click(screen.getByRole("checkbox"));

    expect(bill.toggleNoCost).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  it("turning no-cost off flips right away — it destroys nothing", () => {
    const bill = makeBill({ no_cost: true, amount: "" });
    renderBox(makeEditStore([bill]));

    fireEvent.click(screen.getByRole("checkbox"));

    expect(bill.toggleNoCost).toHaveBeenCalledTimes(1);
  });

  it("choosing a cook and leaving the select saves the row", () => {
    const bill = makeBill();
    const store = makeEditStore([bill]);
    renderBox(store);
    const select = screen.getByRole("combobox", { name: "Select meal cook" });

    fireEvent.change(select, { target: { value: "42" } });
    expect(bill.setResident).toHaveBeenCalledWith("42");

    fireEvent.blur(select);
    expect(store.flushPendingBillsSave).toHaveBeenCalledTimes(1);
  });

  // setAmount keeps the whole-cents grammar: it answers with the value
  // that landed in the store. When that differs from what was typed,
  // the store does not change, React does not re-render, and the input
  // must be put back by hand.
  it("typing a cost sends it to the bill; a refused keystroke is undone", () => {
    const bill = makeBill({
      setAmount: vi.fn((value) => {
        if (value === "12.345") return "12.34";
        bill.amount = value;
        return value;
      }),
    });
    const store = makeEditStore([bill]);
    renderBox(store);
    const input = screen.getByRole("spinbutton", { name: "Set meal cost" });

    fireEvent.change(input, { target: { value: "12.34" } });
    expect(bill.setAmount).toHaveBeenCalledWith("12.34");
    expect(input).toHaveValue(12.34);

    fireEvent.change(input, { target: { value: "12.345" } });
    expect(input).toHaveValue(12.34);

    fireEvent.blur(input);
    expect(bill.normalizeAmountDisplay).toHaveBeenCalledTimes(1);
    expect(store.flushPendingBillsSave).toHaveBeenCalledTimes(1);
  });

  it("marks a pending cost", () => {
    renderBox(makeEditStore([makeBill({ costPending: true })]));
    const pending = screen.getByRole("spinbutton", { name: "Set meal cost" });
    expect(pending).toHaveClass("cost-pending");
    expect(pending).toHaveAttribute("placeholder", "pending");
  });

  it("leaving the no-cost switch saves the row", () => {
    const store = makeEditStore([makeBill()]);
    renderBox(store);
    fireEvent.blur(screen.getByRole("checkbox"));
    expect(store.flushPendingBillsSave).toHaveBeenCalledTimes(1);
  });

  it("Yes erases the typed cost", () => {
    const bill = makeBill({ amount: "12.00" });
    renderBox(makeEditStore([bill]));
    fireEvent.click(screen.getByRole("checkbox"));

    // The Yes button is armed only after armMs; jump the clock.
    const nowSpy = vi
      .spyOn(performance, "now")
      .mockReturnValue(performance.now() + 1000);
    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    nowSpy.mockRestore();

    expect(bill.toggleNoCost).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  // The real store, loaded with the server's answer, so a pick in a menu
  // goes through the real Bill and the real save.
  describe("on the real store", () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    // One resident row as /meals/:id/cooks sends it.
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

    // Alice can cook. Carol (44) and Dan (45) were retired after they
    // cooked. The server lists them because they have a bill (#91).
    function loadedStore(bills) {
      const store = createDataStore({ mealProps: { closed: false } });
      store.loadData(
        {
          id: 1,
          date: "2023-06-15",
          description: "",
          closed: false,
          closed_at: null,
          reconciled: false,
          max: null,
          next_id: 1,
          prev_id: 1,
          residents: [
            residentRow(42, "Alice R."),
            residentRow(44, "Carol R.", { active: false }),
            residentRow(45, "Dan R.", { active: false }),
          ],
          guests: [],
          bills,
        },
        "server",
      );
      return store;
    }

    // The bills saves the page sent.
    function billsPatches() {
      return axios.mock.calls.filter(
        ([config]) =>
          config.method === "patch" && config.url === "/api/v1/meals/1/bills",
      );
    }

    // A save lists every cook, and the server deletes the bill of a cook
    // left out. A person who picks the wrong name and then waits sends
    // that pick, so the server deletes the retired cook's bill. Their row
    // must still offer them, so the person can pick them again, and that
    // save gives them their bill back.
    it("lets a retired cook be picked again in their own row after another name was picked there", async () => {
      vi.useFakeTimers();
      renderBox(
        loadedStore([{ resident_id: 44, amount: "40", no_cost: false }]),
      );
      const [carolsRow, blankRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });

      // The wrong pick. The person waits past the save delay, so it is
      // saved, and the server answers with the bills it kept.
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 42, amount: "40.0", no_cost: false }],
        },
      });
      fireEvent.change(carolsRow, { target: { value: "42" } });
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

      expect(billsPatches()).toHaveLength(1);
      expect(billsPatches()[0][0].data.bills).toEqual([
        { resident_id: 42, amount: "40.00", no_cost: false },
      ]);
      expect(offered(carolsRow)).toContain("Carol R.");
      expect(offered(blankRow)).not.toContain("Carol R.");

      fireEvent.change(carolsRow, { target: { value: "44" } });
      fireEvent.blur(carolsRow);

      expect(billsPatches()).toHaveLength(2);
      expect(billsPatches()[1][0].data.bills).toEqual([
        { resident_id: 44, amount: "40.00", no_cost: false },
      ]);
    });

    it("offers each of two retired cooks only in the row of their own bill", () => {
      renderBox(
        loadedStore([
          { resident_id: 44, amount: "40", no_cost: false },
          { resident_id: 45, amount: "25", no_cost: false },
        ]),
      );

      const [carolsRow, dansRow, blankRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });
      expect(offered(carolsRow)).toEqual([
        "¯\\_(ツ)_/¯",
        "Alice R.",
        "Carol R.",
      ]);
      expect(offered(dansRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R.", "Dan R."]);
      expect(offered(blankRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R."]);
    });
  });
});
