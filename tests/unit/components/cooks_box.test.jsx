import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, within } from "@testing-library/react";
import { observable } from "mobx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import CooksBox from "../../../app/frontend/src/components/meal/cooks_box.jsx";

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
        [42, { id: 42, name: "Alice R.", can_cook: true }],
        [43, { id: 43, name: "Bob", can_cook: false }],
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
});
