import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, within, act } from "@testing-library/react";
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
      resident: {
        id: 42,
        name: "Alice R.",
        plainName: "Alice",
        active: true,
        can_cook: true,
      },
      resident_id: 42,
      // A row made here, not by a load, so it had no cook at load time,
      // and the server has no bill for it.
      loadedCookId: null,
      baseCookId: null,
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
      mealLoading: false,
      bills: new Map(bills.map((bill) => [bill.id, bill])),
      residents: new Map([
        [42, { id: 42, name: "Alice R.", can_cook: true, active: true }],
        [43, { id: 43, name: "Bob", can_cook: false, active: true }],
        [46, { id: 46, name: "Eve S.", can_cook: true, active: true }],
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

  // After a bills save for the meal failed, the meal loads again, and
  // until it arrives the rows may show what the server does not have.
  // Nothing may be typed on top of that (decision 7 of #135).
  it("freezes every control while the meal loads again", () => {
    renderBox(makeEditStore([makeBill()], { mealLoading: true }));
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

  // The meal starts to load again (a bills save for it failed) while the
  // question is open. The switch is frozen until the meal arrives, so
  // the question goes away: a Yes would change a row that may show what
  // the server does not have.
  it("the no-cost question goes away while the meal loads again", () => {
    const bill = makeBill({ amount: "12.00" });
    const store = makeEditStore([bill]);
    renderBox(store);
    fireEvent.click(screen.getByRole("checkbox"));
    expect(screen.getByRole("alertdialog")).toBeInTheDocument();

    act(() => {
      store.mealLoading = true;
    });

    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  // Each row names a different cook: a save names each cook once, so a
  // cook in two rows could not be saved (billEditsOf, "cookInTwoRows").
  it("does not offer a cook already picked in another row", () => {
    renderBox(
      makeEditStore([
        makeBill({ id: "1" }),
        makeBill({ id: "2", resident: null, resident_id: "" }),
      ]),
    );

    const [alicesRow, blankRow] = screen.getAllByRole("combobox", {
      name: "Select meal cook",
    });
    expect(offered(alicesRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R.", "Eve S."]);
    expect(offered(blankRow)).toEqual(["¯\\_(ツ)_/¯", "Eve S."]);
  });

  // A row keeps offering the cook it loaded with (#91), unless another
  // row picked that cook since.
  it("does not offer a row's loaded cook once another row picked them", () => {
    const eve = {
      id: 46,
      name: "Eve S.",
      plainName: "Eve",
      active: true,
      can_cook: true,
    };
    renderBox(
      makeEditStore([
        makeBill({ id: "1", loadedCookId: 46 }),
        makeBill({ id: "2", resident: eve, resident_id: 46 }),
      ]),
    );

    const [alicesRow, evesRow] = screen.getAllByRole("combobox", {
      name: "Select meal cook",
    });
    expect(offered(alicesRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R."]);
    expect(offered(evesRow)).toEqual(["¯\\_(ツ)_/¯", "Eve S."]);
  });

  // Carol cooked, and was retired after (#91). Only her own row offers
  // her. Picking another name there, or the blank, removes her bill,
  // and after the page loads the meal again no menu offers her. So the
  // pick asks first. The menu is on the left of the row, so this bar
  // puts No on the left, under the menu.
  describe("removing a cook no other menu offers", () => {
    function carol(overrides = {}) {
      return {
        id: 44,
        name: "Carol R.",
        plainName: "Carol",
        active: false,
        can_cook: true,
        ...overrides,
      };
    }

    // Carol's row as a load makes it: the server has her bill.
    function carolsBill(overrides = {}) {
      return makeBill({
        resident: carol(),
        resident_id: 44,
        loadedCookId: 44,
        baseCookId: 44,
        amount: "40.00",
        ...overrides,
      });
    }

    // The residents the menus read, Carol among them, as the server
    // lists her (#91).
    function storeWith(bills) {
      const residents = new Map(makeStore([]).residents);
      residents.set(44, carol());
      return makeEditStore(bills, { residents });
    }

    function carolsMenu() {
      return screen.getByRole("combobox", { name: "Select meal cook" });
    }

    it("asks before another name is picked in the retired cook's row", () => {
      const bill = carolsBill();
      renderBox(storeWith([bill]));

      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      expect(bill.setResident).not.toHaveBeenCalled();
      expect(carolsMenu()).toHaveValue("44");
      const question = screen.getByRole("alertdialog", {
        name: "Remove Carol as a cook?",
      });
      expect(question).toHaveTextContent(
        "Remove Carol as a cook?After this page updates, only an admin can add Carol back.",
      );
      expect(question).toHaveClass("confirm-bar-left");
      expect(screen.getByRole("button", { name: "No" })).toHaveFocus();
    });

    it("asks before the blank is picked in the retired cook's row", () => {
      const bill = carolsBill();
      renderBox(storeWith([bill]));

      fireEvent.change(carolsMenu(), { target: { value: "" } });

      expect(bill.setResident).not.toHaveBeenCalled();
      expect(
        screen.getByRole("alertdialog", { name: "Remove Carol as a cook?" }),
      ).toBeInTheDocument();
    });

    // "Can cook" turned off after cooking hides a cook from the other
    // menus too, and only an admin can turn it on again.
    it("asks for a cook who can no longer cook", () => {
      const bill = carolsBill({
        resident: carol({ active: true, can_cook: false }),
      });
      renderBox(storeWith([bill]));

      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      expect(bill.setResident).not.toHaveBeenCalled();
      expect(
        screen.getByRole("alertdialog", { name: "Remove Carol as a cook?" }),
      ).toBeInTheDocument();
    });

    it("No keeps the cook", () => {
      const bill = carolsBill();
      renderBox(storeWith([bill]));
      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      fireEvent.click(screen.getByRole("button", { name: "No" }));

      expect(bill.setResident).not.toHaveBeenCalled();
      expect(carolsMenu()).toHaveValue("44");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    it("Yes picks the name", () => {
      const bill = carolsBill();
      renderBox(storeWith([bill]));
      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      // The Yes button is armed only after armMs; jump the clock.
      const nowSpy = vi
        .spyOn(performance, "now")
        .mockReturnValue(performance.now() + 1000);
      fireEvent.click(screen.getByRole("button", { name: "Yes" }));
      nowSpy.mockRestore();

      expect(bill.setResident).toHaveBeenCalledTimes(1);
      expect(bill.setResident).toHaveBeenCalledWith("42");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    // Every menu offers an active cook who can cook, so a wrong pick is
    // undone by picking them again.
    it("does not ask for a cook every menu offers", () => {
      const bill = makeBill({ baseCookId: 42, loadedCookId: 42 });
      renderBox(storeWith([bill]));

      fireEvent.change(carolsMenu(), { target: { value: "46" } });

      expect(bill.setResident).toHaveBeenCalledWith("46");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    // Carol was picked again in her row, and that pick has not been
    // saved: the server has Alice's bill for the row (the base), not
    // Carol's. Picking another name only undoes the unsaved pick.
    it("does not ask when the server has no bill for the retired cook", () => {
      const bill = carolsBill({ baseCookId: 42 });
      renderBox(storeWith([bill]));

      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      expect(bill.setResident).toHaveBeenCalledWith("42");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    it("does not ask when a cook is picked in a blank row", () => {
      const bill = makeBill({ resident: null, resident_id: "" });
      renderBox(storeWith([bill]));

      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      expect(bill.setResident).toHaveBeenCalledWith("42");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    it("goes away while the meal loads again", () => {
      const bill = carolsBill();
      const store = storeWith([bill]);
      renderBox(store);
      fireEvent.change(carolsMenu(), { target: { value: "42" } });
      expect(screen.getByRole("alertdialog")).toBeInTheDocument();

      act(() => {
        store.mealLoading = true;
      });

      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(bill.setResident).not.toHaveBeenCalled();
    });

    // A keyboard can reach the menu while the no-cost question is open,
    // with no click outside the bar to close it. One row asks one
    // question at a time.
    it("closes the no-cost question when it asks", () => {
      renderBox(storeWith([carolsBill()]));
      fireEvent.click(screen.getByRole("checkbox"));
      expect(
        screen.getByRole("alertdialog", { name: "Erase Carol's $40.00?" }),
      ).toBeInTheDocument();

      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      expect(screen.getAllByRole("alertdialog")).toHaveLength(1);
      expect(
        screen.getByRole("alertdialog", { name: "Remove Carol as a cook?" }),
      ).toBeInTheDocument();
    });

    it("is closed by the no-cost question", () => {
      renderBox(storeWith([carolsBill()]));
      fireEvent.change(carolsMenu(), { target: { value: "42" } });

      fireEvent.click(screen.getByRole("checkbox"));

      expect(screen.getAllByRole("alertdialog")).toHaveLength(1);
      expect(
        screen.getByRole("alertdialog", { name: "Erase Carol's $40.00?" }),
      ).toBeInTheDocument();
    });
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
    // `others` adds more residents to the list.
    function loadedStore(bills, others = []) {
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
            ...others,
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

    // Press Yes on the question that is open, once it is armed.
    function answerYes() {
      const nowSpy = vi
        .spyOn(performance, "now")
        .mockReturnValue(performance.now() + 1000);
      fireEvent.click(screen.getByRole("button", { name: "Yes" }));
      nowSpy.mockRestore();
    }

    const forty = { amount: "40.00", no_cost: false };

    // Picking another name in a retired cook's row would remove her bill,
    // so nothing is sent until the person says Yes.
    it("sends a pick in a retired cook's row only after Yes", async () => {
      vi.useFakeTimers();
      renderBox(
        loadedStore([{ resident_id: 44, amount: "40", no_cost: false }]),
      );
      const [carolsRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });

      fireEvent.change(carolsRow, { target: { value: "42" } });
      fireEvent.blur(carolsRow);
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);
      expect(billsPatches()).toHaveLength(0);
      expect(carolsRow).toHaveDisplayValue("Carol R.");

      answerYes();
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

      expect(carolsRow).toHaveDisplayValue("Alice R.");
      expect(billsPatches()).toHaveLength(1);
      expect(billsPatches()[0][0].data.edits).toEqual([
        { op: "add", resident_id: 42, to: forty },
        { op: "remove", resident_id: 44, from: forty },
      ]);
    });

    it("sends nothing after No, and the retired cook keeps her row", async () => {
      vi.useFakeTimers();
      renderBox(
        loadedStore([{ resident_id: 44, amount: "40", no_cost: false }]),
      );
      const [carolsRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });

      fireEvent.change(carolsRow, { target: { value: "" } });
      fireEvent.click(screen.getByRole("button", { name: "No" }));
      fireEvent.blur(carolsRow);
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

      expect(billsPatches()).toHaveLength(0);
      expect(carolsRow).toHaveValue("44");
      expect(carolsRow).toHaveDisplayValue("Carol R.");
    });

    // After a Yes, her row still offers her until the meal loads again,
    // so a wrong Yes can be undone there. Picking her again is an add,
    // which removes nothing the server has, so it does not ask. Once
    // that add is saved, the server has her bill again, so another pick
    // asks again.
    it("lets a retired cook be picked again in their own row after a Yes removed her", async () => {
      vi.useFakeTimers();
      renderBox(
        loadedStore([{ resident_id: 44, amount: "40", no_cost: false }]),
      );
      const [carolsRow, blankRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });

      // The pick and the Yes. The person waits past the save delay, so
      // it is saved, and the server answers with the bills it kept.
      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 42, amount: "40.0", no_cost: false }],
        },
      });
      fireEvent.change(carolsRow, { target: { value: "42" } });
      answerYes();
      await vi.advanceTimersByTimeAsync(SAVE_DEBOUNCE_MS);

      expect(billsPatches()).toHaveLength(1);
      expect(billsPatches()[0][0].data.edits).toEqual([
        { op: "add", resident_id: 42, to: forty },
        { op: "remove", resident_id: 44, from: forty },
      ]);
      expect(offered(carolsRow)).toContain("Carol R.");
      expect(offered(blankRow)).not.toContain("Carol R.");

      axios.mockResolvedValueOnce({
        status: 200,
        data: {
          message: "Form submitted.",
          bills: [{ resident_id: 44, amount: "40.0", no_cost: false }],
        },
      });
      fireEvent.change(carolsRow, { target: { value: "44" } });
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      fireEvent.blur(carolsRow);

      expect(billsPatches()).toHaveLength(2);
      expect(billsPatches()[1][0].data.edits).toEqual([
        { op: "remove", resident_id: 42, from: forty },
        { op: "add", resident_id: 44, to: forty },
      ]);
      await vi.advanceTimersByTimeAsync(0);

      fireEvent.change(carolsRow, { target: { value: "42" } });
      expect(
        screen.getByRole("alertdialog", { name: "Remove Carol R. as a cook?" }),
      ).toBeInTheDocument();
    });

    // A keyboard can reach the cook menu while the no-cost question is
    // open (Shift+Tab from No), and that sends no click to close the
    // question. The question names the row's cook, so a pick closes it.
    // Before, the blank made the question read the name of no cook, and
    // the page broke.
    it("closes the no-cost question when the blank is picked", () => {
      renderBox(
        loadedStore([{ resident_id: 42, amount: "12", no_cost: false }]),
      );
      const [alicesRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });
      const [alicesNoCost] = screen.getAllByRole("checkbox");
      fireEvent.click(alicesNoCost);
      expect(
        screen.getByRole("alertdialog", { name: "Erase Alice R.'s $12.00?" }),
      ).toBeInTheDocument();

      fireEvent.change(alicesRow, { target: { value: "" } });

      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(alicesRow).toHaveValue("");
      expect(alicesNoCost).not.toBeChecked();
    });

    // The same holds for the cost. Before, the open question went on
    // asking about the new cost ("Erase Alice R.'s $8.00?"). And a
    // cleared cost hid it, so the next cost typed brought it back with
    // no click on No cost.
    it("closes the no-cost question when a cost is typed", () => {
      renderBox(
        loadedStore([{ resident_id: 42, amount: "12", no_cost: false }]),
      );
      const [alicesCost] = screen.getAllByRole("spinbutton", {
        name: "Set meal cost",
      });
      const [alicesNoCost] = screen.getAllByRole("checkbox");
      fireEvent.click(alicesNoCost);
      expect(
        screen.getByRole("alertdialog", { name: "Erase Alice R.'s $12.00?" }),
      ).toBeInTheDocument();

      fireEvent.change(alicesCost, { target: { value: "" } });
      fireEvent.change(alicesCost, { target: { value: "8" } });

      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(alicesCost).toHaveValue(8);
      expect(alicesNoCost).not.toBeChecked();
    });

    // Before, the open question went on asking about the new cook, with
    // no new click: "Erase Eve S.'s $12.00?".
    it("closes the no-cost question when another cook is picked", () => {
      renderBox(
        loadedStore(
          [{ resident_id: 42, amount: "12", no_cost: false }],
          [residentRow(46, "Eve S.")],
        ),
      );
      const [alicesRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });
      const [alicesNoCost] = screen.getAllByRole("checkbox");
      fireEvent.click(alicesNoCost);
      expect(
        screen.getByRole("alertdialog", { name: "Erase Alice R.'s $12.00?" }),
      ).toBeInTheDocument();

      fireEvent.change(alicesRow, { target: { value: "46" } });

      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(alicesRow).toHaveDisplayValue("Eve S.");
      expect(alicesNoCost).not.toBeChecked();
    });

    // A cook picked in one row leaves the other rows' menus, and comes
    // back to them when that row picks someone else.
    it("offers a cook in the other rows again once their row picks someone else", () => {
      renderBox(
        loadedStore([{ resident_id: 42, amount: "12", no_cost: false }]),
      );
      const [alicesRow, secondRow, thirdRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });
      expect(offered(secondRow)).toEqual(["¯\\_(ツ)_/¯"]);
      expect(offered(thirdRow)).toEqual(["¯\\_(ツ)_/¯"]);

      fireEvent.change(alicesRow, { target: { value: "" } });

      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(offered(secondRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R."]);
      expect(offered(thirdRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R."]);
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
