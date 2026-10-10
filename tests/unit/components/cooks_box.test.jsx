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
import { BILL_ROW_SAVE_WAIT_MS } from "../../../app/frontend/src/stores/data_store_bills";

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
      saving: false,
      slowToSave: false,
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
      waitingToReload: false,
      bills: new Map(bills.map((bill) => [bill.id, bill])),
      residents: new Map([
        [42, { id: 42, name: "Alice R.", can_cook: true, active: true }],
        [43, { id: 43, name: "Bob", can_cook: false, active: true }],
        [46, { id: 46, name: "Eve S.", can_cook: true, active: true }],
      ]),
      saveBillRowNow: vi.fn(),
      restartBillRowWait: vi.fn(),
      cookTakenByAnotherRow: () => false,
      ...overrides,
    },
    {
      saveBillRowNow: false,
      restartBillRowWait: false,
      cookTakenByAnotherRow: false,
    },
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

  // Logout, Refresh and the error page's Refresh wait for the bills
  // saves before they reload (#150). An edit then would wait 2 seconds
  // before its save, and the reload, or logout taking the token away,
  // would lose it.
  it("starts the row's wait again when the person comes to its cost box", () => {
    const bill = makeBill();
    const store = makeEditStore([bill]);
    renderBox(store);

    fireEvent.focus(screen.getByRole("spinbutton", { name: "Set meal cost" }));

    expect(store.restartBillRowWait).toHaveBeenCalledTimes(1);
    expect(store.restartBillRowWait).toHaveBeenCalledWith(bill);
  });

  it("freezes every control while the page waits to reload", () => {
    renderBox(makeEditStore([makeBill()], { waitingToReload: true }));
    expect(
      screen.getByRole("combobox", { name: "Select meal cook" }),
    ).toBeDisabled();
    expect(
      screen.getByRole("spinbutton", { name: "Set meal cost" }),
    ).toBeDisabled();
    expect(screen.getByRole("checkbox")).toBeDisabled();
  });

  // #145. A save names cooks, so a cost typed in a row with no cook was
  // never sent, and the next load of the meal made the row again
  // without it. Nothing said so. The cost field is off until the row
  // has a cook, like the No cost switch.
  it("turns off the cost field of a row with no cook", () => {
    renderBox(
      makeEditStore([
        makeBill({ id: "1" }),
        makeBill({ id: "2", resident: null, resident_id: "" }),
      ]),
    );
    const [cooksCost, blankCost] = screen.getAllByRole("spinbutton", {
      name: "Set meal cost",
    });
    expect(cooksCost).toBeEnabled();
    expect(blankCost).toBeDisabled();
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

  it("choosing a cook sends it to the bill", () => {
    const bill = makeBill();
    const store = makeEditStore([bill]);
    renderBox(store);
    const select = screen.getByRole("combobox", { name: "Select meal cook" });

    fireEvent.change(select, { target: { value: "42" } });
    expect(bill.setResident).toHaveBeenCalledWith("42");
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
    expect(store.saveBillRowNow).toHaveBeenCalledWith(bill);
  });

  it("marks a pending cost", () => {
    renderBox(makeEditStore([makeBill({ costPending: true })]));
    const pending = screen.getByRole("spinbutton", { name: "Set meal cost" });
    expect(pending).toHaveClass("cost-pending");
    expect(pending).toHaveAttribute("placeholder", "pending");
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
  // goes through the real Bill and the real save. The clock is fake in
  // every test here: an edit starts a row's 2-second wait, and on a real
  // clock that wait would end during a later test and send a save there.
  describe("on the real store", () => {
    beforeEach(() => {
      vi.clearAllMocks();
      vi.useFakeTimers();
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
      await vi.advanceTimersByTimeAsync(BILL_ROW_SAVE_WAIT_MS);
      expect(billsPatches()).toHaveLength(0);
      expect(carolsRow).toHaveDisplayValue("Carol R.");

      answerYes();
      await vi.advanceTimersByTimeAsync(BILL_ROW_SAVE_WAIT_MS);

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
      await vi.advanceTimersByTimeAsync(BILL_ROW_SAVE_WAIT_MS);

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
      await vi.advanceTimersByTimeAsync(BILL_ROW_SAVE_WAIT_MS);

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
      await vi.advanceTimersByTimeAsync(BILL_ROW_SAVE_WAIT_MS - 1);
      expect(billsPatches()).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(1);

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

    // #145, on the real rows: the cost field turns on when the row gets
    // a cook, and off again when the blank is picked.
    it("turns a row's cost field on with a cook and off with the blank", () => {
      renderBox(loadedStore([]));
      const [firstRow] = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      });
      const [firstCost] = screen.getAllByRole("spinbutton", {
        name: "Set meal cost",
      });
      expect(firstCost).toBeDisabled();

      fireEvent.change(firstRow, { target: { value: "42" } });
      expect(firstCost).toBeEnabled();

      fireEvent.change(firstRow, { target: { value: "" } });
      expect(firstCost).toBeDisabled();
    });

    // A cook picked in one row leaves the other rows' menus. When that
    // row picks someone else, the cook comes back to them once the row's
    // save is answered: until then the server may still have the cook's
    // bill, and another row's save that adds them could reach the
    // server first (#150).
    it("offers a cook in the other rows again once their row picks someone else and that is saved", async () => {
      vi.useFakeTimers();
      let answer;
      axios.mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            answer = resolve;
          }),
      );
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
      expect(offered(secondRow)).toEqual(["¯\\_(ツ)_/¯"]);

      await act(() => vi.advanceTimersByTimeAsync(BILL_ROW_SAVE_WAIT_MS));
      expect(billsPatches()).toHaveLength(1);
      expect(offered(secondRow)).toEqual(["¯\\_(ツ)_/¯"]);

      answer({ status: 200, data: { message: "Form submitted.", bills: [] } });
      await act(() => vi.advanceTimersByTimeAsync(0));
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

  // #150. Each row saves on its own. While a row's save is on its way,
  // its menu, cost box and No cost switch are read-only, and the other
  // rows are not. The lock shows nothing for one second. After that, a
  // small spinner shows in the row's cost box.
  describe("a row whose save is on its way", () => {
    beforeEach(() => {
      vi.clearAllMocks();
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    // Bob (11) and Carol (12) cook, with no cost yet. Every save waits
    // until the test answers it. With bobRetired, Bob was retired after
    // cooking (#91), so only his own row offers him.
    function twoCooks({ bobRetired = false } = {}) {
      const answers = [];
      axios.mockImplementation(
        () =>
          new Promise((resolve) => {
            answers.push(resolve);
          }),
      );
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
          residents: [11, 12, 13].map((id) => ({
            id,
            meal_id: 1,
            name: { 11: "Bob", 12: "Carol", 13: "Dan" }[id],
            short_name: "x",
            attending: false,
            attending_at: null,
            late: false,
            vegetarian: false,
            can_cook: true,
            active: !(bobRetired && id === 11),
          })),
          guests: [],
          bills: [
            { resident_id: 11, amount: "0.0", no_cost: false },
            { resident_id: 12, amount: "0.0", no_cost: false },
          ],
        },
        "server",
      );
      renderBox(store);
      const answerNext = async () => {
        answers.shift()({ status: 200, data: { message: "Form submitted." } });
        await act(() => vi.advanceTimersByTimeAsync(0));
      };
      return { store, answerNext };
    }

    function controls(index) {
      return {
        menu: screen.getAllByRole("combobox", { name: "Select meal cook" })[
          index
        ],
        cost: screen.getAllByRole("spinbutton", { name: "Set meal cost" })[
          index
        ],
        noCost: screen.getAllByRole("checkbox")[index],
      };
    }

    function spinners() {
      return document.querySelectorAll(".cost-spinner");
    }

    it("makes that row read-only, and leaves the other rows alone", () => {
      twoCooks();
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.blur(bob.cost);

      expect(axios).toHaveBeenCalledTimes(1);
      expect(bob.cost).toHaveAttribute("readonly");
      expect(bob.menu).toHaveAttribute("aria-disabled", "true");
      expect(bob.noCost).toHaveAttribute("aria-disabled", "true");
      // Read-only, not off: the controls keep their look and their
      // focus, so the lock shows nothing.
      expect(bob.cost).toBeEnabled();
      expect(bob.menu).toBeEnabled();
      expect(bob.noCost).toBeEnabled();

      const carol = controls(1);
      expect(carol.cost).not.toHaveAttribute("readonly");
      expect(carol.menu).not.toHaveAttribute("aria-disabled");
      expect(carol.noCost).not.toHaveAttribute("aria-disabled");
    });

    it("takes no pick and no switch while it is locked, and asks nothing", async () => {
      const { answerNext } = twoCooks();
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.blur(bob.cost);

      fireEvent.change(bob.menu, { target: { value: "13" } });
      fireEvent.click(bob.noCost);

      expect(bob.menu).toHaveValue("11");
      expect(bob.noCost).not.toBeChecked();
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      // A tap on the switch over a typed cost asks "Erase...?" when the
      // row is free. A tap during the lock asks nothing later either.
      await answerNext();
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    // A pick in the row of a retired cook asks "Remove...?" when the row
    // is free. A pick during the lock asks nothing, then or after.
    it("does not ask about a pick made in a retired cook's row while it was locked", async () => {
      const { answerNext } = twoCooks({ bobRetired: true });
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.blur(bob.cost);

      fireEvent.change(bob.menu, { target: { value: "13" } });
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();

      await answerNext();
      expect(bob.menu).toHaveValue("11");
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      // The same pick on the free row asks.
      fireEvent.change(bob.menu, { target: { value: "13" } });
      expect(screen.getByRole("alertdialog")).toBeInTheDocument();
    });

    it("frees the row once its save is answered", async () => {
      const { answerNext } = twoCooks();
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.blur(bob.cost);

      await answerNext();

      expect(bob.cost).not.toHaveAttribute("readonly");
      expect(bob.menu).not.toHaveAttribute("aria-disabled");
      expect(bob.noCost).not.toHaveAttribute("aria-disabled");
    });

    it("shows a spinner in the cost box, with aria-busy, once the save has waited one second", async () => {
      const { answerNext } = twoCooks();
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.blur(bob.cost);

      await act(() => vi.advanceTimersByTimeAsync(999));
      expect(spinners()).toHaveLength(0);
      expect(bob.cost).not.toHaveAttribute("aria-busy");

      await act(() => vi.advanceTimersByTimeAsync(1));
      expect(spinners()).toHaveLength(1);
      expect(spinners()[0]).toHaveAttribute("aria-hidden", "true");
      expect(spinners()[0]).toHaveTextContent("");
      expect(bob.cost.parentElement).toContainElement(spinners()[0]);
      expect(bob.cost).toHaveAttribute("aria-busy", "true");
      expect(controls(1).cost).not.toHaveAttribute("aria-busy");

      await answerNext();
      expect(spinners()).toHaveLength(0);
      expect(bob.cost).not.toHaveAttribute("aria-busy");
    });

    it("closes a question that was open when the row locked, for good", async () => {
      const { answerNext } = twoCooks();
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.click(bob.noCost);
      expect(screen.getByRole("alertdialog")).toBeInTheDocument();

      await act(() => vi.advanceTimersByTimeAsync(2000)); // the row saves
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();

      await answerNext();
      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
    });

    it("closes a question about removing a retired cook for good too", async () => {
      const { answerNext } = twoCooks({ bobRetired: true });
      const bob = controls(0);
      fireEvent.change(bob.cost, { target: { value: "5" } });
      fireEvent.change(bob.menu, { target: { value: "13" } });
      expect(screen.getByRole("alertdialog")).toBeInTheDocument();

      await act(() => vi.advanceTimersByTimeAsync(2000)); // the row saves
      await answerNext();

      expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
      expect(bob.menu).toHaveValue("11");
    });

    it("lets two rows save at the same time", () => {
      twoCooks();
      fireEvent.change(controls(0).cost, { target: { value: "5" } });
      fireEvent.blur(controls(0).cost);
      fireEvent.change(controls(1).cost, { target: { value: "7" } });
      fireEvent.blur(controls(1).cost);

      expect(axios).toHaveBeenCalledTimes(2);
      expect(controls(0).cost).toHaveAttribute("readonly");
      expect(controls(1).cost).toHaveAttribute("readonly");
    });
  });

  describe("when a row saves", () => {
    beforeEach(() => {
      vi.clearAllMocks();
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    function loaded() {
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
            {
              id: 11,
              meal_id: 1,
              name: "Bob",
              short_name: "Bob",
              attending: false,
              attending_at: null,
              late: false,
              vegetarian: false,
              can_cook: true,
              active: true,
            },
          ],
          guests: [],
          bills: [],
        },
        "server",
      );
      renderBox(store);
      return store;
    }

    it("saves at once when Enter is pressed in the cost box", () => {
      loaded();
      fireEvent.change(
        screen.getAllByRole("combobox", { name: "Select meal cook" })[0],
        { target: { value: "11" } },
      );
      const cost = screen.getAllByRole("spinbutton", {
        name: "Set meal cost",
      })[0];
      fireEvent.change(cost, { target: { value: "5" } });

      fireEvent.keyDown(cost, { key: "Enter" });

      expect(axios).toHaveBeenCalledTimes(1);
      expect(axios.mock.calls[0][0].data.edits).toEqual([
        { op: "add", resident_id: 11, to: { amount: "5", no_cost: false } },
      ]);
    });

    // A pick starts the row's 2-second wait. On a phone the person then
    // closes the menu, taps the cost box and waits for the keyboard,
    // which can take about 2 seconds. Coming to the cost box starts the
    // wait again, so the pick's save does not lock the row under the
    // first digits typed: "25" must not become "5".
    it("takes the digits typed in the cost box soon after a pick", async () => {
      axios.mockImplementation(() => new Promise(() => {}));
      loaded();
      const menu = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      })[0];
      fireEvent.change(menu, { target: { value: "11" } });
      await act(() => vi.advanceTimersByTimeAsync(1900));
      const cost = screen.getAllByRole("spinbutton", {
        name: "Set meal cost",
      })[0];
      fireEvent.focus(cost);
      await act(() => vi.advanceTimersByTimeAsync(200));

      fireEvent.change(cost, { target: { value: "2" } });
      fireEvent.change(cost, { target: { value: "25" } });

      expect(cost).toHaveValue(25);
      expect(axios).not.toHaveBeenCalled();
    });

    it("does not save on other keys", () => {
      loaded();
      fireEvent.change(
        screen.getAllByRole("combobox", { name: "Select meal cook" })[0],
        { target: { value: "11" } },
      );
      fireEvent.keyDown(
        screen.getAllByRole("spinbutton", { name: "Set meal cost" })[0],
        { key: "5" },
      );

      expect(axios).not.toHaveBeenCalled();
    });

    // A person who picks a cook and then goes to the cost box to type
    // the cost sends one save. A save on leaving the menu would lock the
    // cost box they are about to type in.
    it("waits 2 seconds after a pick, even when the person leaves the menu", async () => {
      loaded();
      const menu = screen.getAllByRole("combobox", {
        name: "Select meal cook",
      })[0];
      fireEvent.change(menu, { target: { value: "11" } });
      fireEvent.blur(menu);

      await act(() => vi.advanceTimersByTimeAsync(1999));
      expect(axios).not.toHaveBeenCalled();
      await act(() => vi.advanceTimersByTimeAsync(1));
      expect(axios).toHaveBeenCalledTimes(1);
    });

    it("waits 2 seconds after the No cost switch, even when the person leaves it", async () => {
      loaded();
      fireEvent.change(
        screen.getAllByRole("combobox", { name: "Select meal cook" })[0],
        { target: { value: "11" } },
      );
      const noCost = screen.getAllByRole("checkbox")[0];
      fireEvent.click(noCost);
      fireEvent.blur(noCost);

      await act(() => vi.advanceTimersByTimeAsync(1999));
      expect(axios).not.toHaveBeenCalled();
      await act(() => vi.advanceTimersByTimeAsync(1));
      expect(axios.mock.calls[0][0].data.edits).toEqual([
        { op: "add", resident_id: 11, to: { amount: "", no_cost: true } },
      ]);
    });
  });

  // Two saves on their way at once must not name one cook (#150): a
  // row's menu does not offer a cook that another row is still
  // changing.
  it("does not offer a cook another row is taking off until that row's save is answered", () => {
    const store = makeEditStore(
      [
        makeBill({ id: "1", resident: null, resident_id: "", baseCookId: 42 }),
        makeBill({ id: "2", resident: null, resident_id: "" }),
      ],
      {
        cookTakenByAnotherRow: (row, cookId) => row.id === "2" && cookId === 42,
      },
    );
    renderBox(store);

    const [firstRow, secondRow] = screen.getAllByRole("combobox", {
      name: "Select meal cook",
    });
    expect(offered(firstRow)).toEqual(["¯\\_(ツ)_/¯", "Alice R.", "Eve S."]);
    expect(offered(secondRow)).toEqual(["¯\\_(ツ)_/¯", "Eve S."]);
  });
});
