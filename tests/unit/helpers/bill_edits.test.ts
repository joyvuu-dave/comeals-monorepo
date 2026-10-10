import { describe, it, expect } from "vitest";

import {
  billEditsOf,
  BillRow,
} from "../../../app/frontend/src/helpers/bill_edits";

// The cook a row shows, as a row holds it.
function cook(cookId: number | null): BillRow["resident"] {
  return cookId === null ? null : { id: cookId };
}

// A row that shows what it had when the meal loaded: its base.
function loaded(cookId: number | null, amount = "", noCost = false): BillRow {
  return {
    resident: cook(cookId),
    amount,
    no_cost: noCost,
    baseCookId: cookId,
    baseAmount: amount,
    baseNoCost: noCost,
  };
}

// The same row after the person changed what it shows.
function shows(
  row: BillRow,
  cookId: number | null,
  amount: string,
  noCost = false,
): BillRow {
  return { ...row, resident: cook(cookId), amount, no_cost: noCost };
}

const BOB = 9;
const CAROL = 12;
const XAVIER = 7;

// One row's edits: what the row shows against its base (#150). The
// other rows are only read to check that the row's cook is not picked in
// one of them too.
describe("billEditsOf", () => {
  it("sends nothing when the row shows its base", () => {
    expect(
      billEditsOf(loaded(BOB, "5.00"), [loaded(CAROL, ""), loaded(null)]),
    ).toEqual({ kind: "edits", edits: [] });
    expect(billEditsOf(loaded(null), [loaded(BOB, "5.00")])).toEqual({
      kind: "edits",
      edits: [],
    });
  });

  it("changes a cook's amount, with the amount the page saw", () => {
    expect(billEditsOf(shows(loaded(BOB, "5.00"), BOB, "7"), [])).toEqual({
      kind: "edits",
      edits: [
        {
          op: "change",
          resident_id: BOB,
          from: { amount: "5.00", no_cost: false },
          to: { amount: "7", no_cost: false },
        },
      ],
    });
  });

  it("changes a cook's no_cost", () => {
    expect(billEditsOf(shows(loaded(BOB, ""), BOB, "", true), [])).toEqual({
      kind: "edits",
      edits: [
        {
          op: "change",
          resident_id: BOB,
          from: { amount: "", no_cost: false },
          to: { amount: "", no_cost: true },
        },
      ],
    });
  });

  it("adds a cook picked in a blank row, with no cost typed yet", () => {
    expect(billEditsOf(shows(loaded(null), XAVIER, ""), [])).toEqual({
      kind: "edits",
      edits: [
        { op: "add", resident_id: XAVIER, to: { amount: "", no_cost: false } },
      ],
    });
  });

  it("removes a cook taken off their row, with the bill the page saw", () => {
    expect(
      billEditsOf(shows(loaded(BOB, "0.00", false), null, "0.00"), []),
    ).toEqual({
      kind: "edits",
      edits: [
        {
          op: "remove",
          resident_id: BOB,
          from: { amount: "0.00", no_cost: false },
        },
      ],
    });
  });

  // The row keeps its amount when another name is picked in it, so the
  // new cook gets it. The edits are in resident id order.
  it("removes one cook and adds the other when another name is picked in a row", () => {
    expect(
      billEditsOf(shows(loaded(CAROL, "5.00"), XAVIER, "5.00"), []),
    ).toEqual({
      kind: "edits",
      edits: [
        {
          op: "add",
          resident_id: XAVIER,
          to: { amount: "5.00", no_cost: false },
        },
        {
          op: "remove",
          resident_id: CAROL,
          from: { amount: "5.00", no_cost: false },
        },
      ],
    });
  });

  it("sends nothing when a typed amount goes back to its base", () => {
    expect(billEditsOf(shows(loaded(BOB, "5.00"), BOB, "5"), [])).toEqual({
      kind: "edits",
      edits: [],
    });
  });

  it("compares amounts as numbers: 5, 5.0 and 5.00 are the same, and so are blank and 0.0", () => {
    expect(billEditsOf(shows(loaded(BOB, "5.0"), BOB, "5.00"), [])).toEqual({
      kind: "edits",
      edits: [],
    });
    expect(billEditsOf(shows(loaded(CAROL, "0.0"), CAROL, ""), [])).toEqual({
      kind: "edits",
      edits: [],
    });
  });

  // Each row saves on its own, so another row's change is never in this
  // row's save. A bill whose cook no row shows (#91) is in no row's base
  // and no row's cook, so no edit can name it, and the server keeps it.
  it("names only the row's own cooks", () => {
    const result = billEditsOf(shows(loaded(BOB, ""), BOB, "8"), [
      shows(loaded(CAROL, ""), CAROL, "4"),
      shows(loaded(null), XAVIER, "3"),
    ]);

    expect(
      result.kind === "edits" && result.edits.map((edit) => edit.resident_id),
    ).toEqual([BOB]);
  });

  it("sends nothing for a number typed in a row with no cook", () => {
    expect(billEditsOf(shows(loaded(null), null, "5"), [])).toEqual({
      kind: "edits",
      edits: [],
    });
  });

  it("refuses a cook picked in another row too, and names the cook", () => {
    expect(
      billEditsOf(shows(loaded(null), BOB, ""), [
        shows(loaded(BOB, "5.00"), BOB, "6"),
        loaded(null),
      ]),
    ).toEqual({ kind: "cookInTwoRows", cook: { id: BOB } });
    expect(
      billEditsOf(shows(loaded(BOB, "5.00"), BOB, "6"), [
        shows(loaded(null), BOB, ""),
      ]),
    ).toEqual({ kind: "cookInTwoRows", cook: { id: BOB } });
  });

  // setAmount refuses text that is not whole cents, so only a bug can
  // put it on a row.
  it.each([
    ["an added cook", shows(loaded(null), BOB, "1e3")],
    ["a changed cook", shows(loaded(BOB, "5.00"), BOB, "5.001")],
  ])("refuses an amount that is not whole cents for %s", (_label, row) => {
    expect(billEditsOf(row, [])).toEqual({ kind: "invalidAmount" });
  });

  // An amount the server sent is in the base. If it does not change, it
  // is not sent, so it never blocks a save.
  it("does not refuse an amount the row loaded with and still shows", () => {
    expect(billEditsOf(loaded(BOB, "12.345"), [])).toEqual({
      kind: "edits",
      edits: [],
    });
  });
});
