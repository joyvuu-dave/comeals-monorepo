// The edits a bills save sends (#135, docs/adr/0009-bills-saves-send-edits.md),
// worked out from the meal's bill rows.
//
// Each row shows a cook and a bill, and keeps a base: the cook and bill
// the server has for that row, as far as this page knows. A save is the
// difference between what the rows show and their bases. It is worked
// out per cook, not per row, so a cook moved from one row to another is
// a change of that cook's bill, not a remove and an add of the same cook.
//
// A bill whose cook no row shows is in no base and on no row, so no edit
// names it, and the server never touches it. That is how a bill the page
// cannot show stays safe (#91).
import type { BillEdit, BillValues } from "./api";
import { isValidAmountString, sameAmount } from "./money";

// What a row reads to build the edits: a Bill node has these fields.
export interface BillRow {
  // The cook the row shows now, or null for none.
  resident: { id: number } | null;
  amount: string;
  no_cost: boolean;
  baseCookId: number | null;
  baseAmount: string;
  baseNoCost: boolean;
}

export type BillEditsResult<R extends BillRow> =
  // What to send. An empty list means the rows show what the server has.
  | { kind: "edits"; edits: BillEdit[] }
  // One cook is picked in two rows. A save names each cook once, so
  // nothing can be sent until one of the rows shows another cook.
  | { kind: "cookInTwoRows"; cook: NonNullable<R["resident"]> }
  // A changed row's amount is not whole cents from 0 to 9999.99.
  // setAmount refuses such text, so only a bug can put it on a row.
  | { kind: "invalidAmount" };

function sameValues(a: BillValues, b: BillValues): boolean {
  return sameAmount(a.amount, b.amount) && a.no_cost === b.no_cost;
}

export function billEditsOf<R extends BillRow>(rows: R[]): BillEditsResult<R> {
  // Each cook's bill at the rows' bases, and as the rows show it now.
  const before = new Map<number, BillValues>();
  const after = new Map<number, BillValues>();
  for (const row of rows) {
    if (row.baseCookId !== null) {
      before.set(row.baseCookId, {
        amount: row.baseAmount,
        no_cost: row.baseNoCost,
      });
    }
    const cook = row.resident;
    if (cook === null) continue;
    if (after.has(cook.id)) return { kind: "cookInTwoRows", cook };
    after.set(cook.id, { amount: row.amount, no_cost: row.no_cost });
  }

  const edits: BillEdit[] = [];
  for (const [cookId, to] of after) {
    const from = before.get(cookId);
    if (from !== undefined && sameValues(from, to)) continue;
    // An amount the row loaded with and still shows is never sent, so
    // only an amount in an edit is checked.
    if (!isValidAmountString(to.amount)) return { kind: "invalidAmount" };
    edits.push(
      from === undefined
        ? { op: "add", resident_id: cookId, to }
        : { op: "change", resident_id: cookId, from, to },
    );
  }
  for (const [cookId, from] of before) {
    if (!after.has(cookId)) {
      edits.push({ op: "remove", resident_id: cookId, from });
    }
  }
  edits.sort((a, b) => a.resident_id - b.resident_id);
  return { kind: "edits", edits };
}
