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
      amountIsValid: true,
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
      editBillsMode: false,
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

describe("CooksBox display mode", () => {
  it("shows each cook's name and amount", () => {
    renderBox(makeStore([makeBill({ amount: "12.34" })]));
    const row = screen.getByRole("row");
    expect(row).toHaveTextContent("Alice R.");
    expect(row).toHaveTextContent("$12.34");
  });

  it("shows the word 'pending' while a cost is awaited", () => {
    renderBox(makeStore([makeBill({ costPending: true })]));
    const pending = screen.getByText("pending");
    expect(pending.tagName).toBe("EM");
  });

  it("shows a bare $ for a blank amount — by design, we like how it looks", () => {
    renderBox(makeStore([makeBill({ amount: "", no_cost: true })]));
    const cells = screen.getAllByRole("cell");
    expect(cells[1]).toHaveTextContent(/^\$$/);
  });

  it("hides the row of a bill with no cook", () => {
    const bill = makeBill({ resident: null });
    const { container } = renderBox(makeStore([bill]));
    expect(container.querySelector("tr")).toHaveAttribute("hidden");
  });
});

describe("CooksBox edit mode", () => {
  function makeEditStore(bills, overrides = {}) {
    return makeStore(bills, { editBillsMode: true, ...overrides });
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
});
