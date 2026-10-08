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

describe("billEditsOf", () => {
  it("sends nothing when every row shows its base", () => {
    expect(
      billEditsOf([loaded(BOB, "5.00"), loaded(CAROL, ""), loaded(null)]),
    ).toEqual({ kind: "edits", edits: [] });
  });

  it("changes a cook's amount, with the amount the page saw", () => {
    expect(billEditsOf([shows(loaded(BOB, "5.00"), BOB, "7")])).toEqual({
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
    expect(billEditsOf([shows(loaded(BOB, ""), BOB, "", true)])).toEqual({
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
    expect(billEditsOf([shows(loaded(null), XAVIER, "")])).toEqual({
      kind: "edits",
      edits: [
        { op: "add", resident_id: XAVIER, to: { amount: "", no_cost: false } },
      ],
    });
  });

  it("removes a cook taken off their row, with the bill the page saw", () => {
    expect(
      billEditsOf([shows(loaded(BOB, "0.00", false), null, "0.00")]),
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
  // new cook gets it.
  it("removes one cook and adds the other when another name is picked in a row", () => {
    expect(billEditsOf([shows(loaded(BOB, "5.00"), CAROL, "5.00")])).toEqual({
      kind: "edits",
      edits: [
        {
          op: "remove",
          resident_id: BOB,
          from: { amount: "5.00", no_cost: false },
        },
        {
          op: "add",
          resident_id: CAROL,
          to: { amount: "5.00", no_cost: false },
        },
      ],
    });
  });

  // The edits work per cook, not per row: Bob moved from the first row
  // to the second, and only his bill changed.
  it("changes a cook's bill when the cook moves to another row", () => {
    expect(
      billEditsOf([
        shows(loaded(BOB, "5.00"), null, "5.00"),
        shows(loaded(null), BOB, ""),
      ]),
    ).toEqual({
      kind: "edits",
      edits: [
        {
          op: "change",
          resident_id: BOB,
          from: { amount: "5.00", no_cost: false },
          to: { amount: "", no_cost: false },
        },
      ],
    });
  });

  it("sends nothing for a cook who moves to another row with the same bill", () => {
    expect(
      billEditsOf([
        shows(loaded(BOB, "5.00"), null, ""),
        shows(loaded(null), BOB, "5"),
      ]),
    ).toEqual({ kind: "edits", edits: [] });
  });

  it("sends nothing when a typed amount goes back to its base", () => {
    expect(billEditsOf([shows(loaded(BOB, "5.00"), BOB, "5")])).toEqual({
      kind: "edits",
      edits: [],
    });
  });

  it("compares amounts as numbers: 5, 5.0 and 5.00 are the same, and so are blank and 0.0", () => {
    expect(
      billEditsOf([
        shows(loaded(BOB, "5.0"), BOB, "5.00"),
        shows(loaded(CAROL, "0.0"), CAROL, ""),
      ]),
    ).toEqual({ kind: "edits", edits: [] });
  });

  it("lists the edits in resident id order", () => {
    const result = billEditsOf([
      shows(loaded(CAROL, ""), CAROL, "3"),
      shows(loaded(null), XAVIER, "4"),
      shows(loaded(BOB, ""), BOB, "2"),
    ]);

    expect(
      result.kind === "edits" && result.edits.map((edit) => edit.resident_id),
    ).toEqual([XAVIER, BOB, CAROL]);
  });

  // A bill whose cook no row shows (#91) is in no row's base and no
  // row's cook, so no edit can name it, and the server keeps it.
  it("never names a cook no row shows", () => {
    const result = billEditsOf([shows(loaded(BOB, ""), BOB, "8")]);

    expect(result.kind === "edits" && result.edits).toHaveLength(1);
  });

  it("sends nothing for a number typed in a row with no cook", () => {
    expect(billEditsOf([shows(loaded(null), null, "5")])).toEqual({
      kind: "edits",
      edits: [],
    });
  });

  it("refuses a cook picked in two rows, and names the cook", () => {
    expect(
      billEditsOf([
        shows(loaded(BOB, "5.00"), BOB, "6"),
        shows(loaded(null), BOB, ""),
        loaded(null),
      ]),
    ).toEqual({ kind: "cookInTwoRows", cook: { id: BOB } });
  });

  // setAmount refuses text that is not whole cents, so only a bug can
  // put it on a row.
  it.each([
    ["an added cook", shows(loaded(null), BOB, "1e3")],
    ["a changed cook", shows(loaded(BOB, "5.00"), BOB, "5.001")],
  ])("refuses an amount that is not whole cents for %s", (_label, row) => {
    expect(billEditsOf([row])).toEqual({ kind: "invalidAmount" });
  });

  // An amount the server sent is in the base. If it does not change, it
  // is not sent, so it cannot block a save of another cook.
  it("does not refuse an amount the row loaded with and still shows", () => {
    expect(
      billEditsOf([
        loaded(BOB, "12.345"),
        shows(loaded(CAROL, ""), CAROL, "4"),
      ]),
    ).toEqual({
      kind: "edits",
      edits: [
        {
          op: "change",
          resident_id: CAROL,
          from: { amount: "", no_cost: false },
          to: { amount: "4", no_cost: false },
        },
      ],
    });
  });
});
