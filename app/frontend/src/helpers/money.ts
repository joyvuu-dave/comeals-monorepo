// String tests for money amounts. Amounts are decimal strings on the wire
// (see docs/adr/0001-typescript-at-the-api-boundary.md) and stay strings in
// the stores. Never coerce them with Number() — these tests read the string
// directly.

// Whole cents, 0 to 9999.99: up to four digits, then an optional dot and up
// to two more digits. The server enforces the same grammar, and the database
// CHECK constraint on bills.amount is the last line of defense.
const WHOLE_CENTS = /^\d{1,4}(\.\d{1,2})?$/;

// Valid user input for a bill amount: empty (not filled in yet) or a
// whole-cents amount.
export function isValidAmountString(value: string): boolean {
  return value === "" || WHOLE_CENTS.test(value);
}

// What a cost means while it is still being typed. A person types one
// key at a time, so "7." and ".7" are on the way to "7.50" and "0.75",
// and the cost field must keep them on screen. Returns the whole-cents
// amount the typed text means ("7." means "7", ".7" means "0.7", "."
// means ""), or null when no more typing could make it a cost.
const BEING_TYPED = /^\d{0,4}(\.\d{0,2})?$/;

export function amountMeantBy(typed: string): string | null {
  if (!BEING_TYPED.test(typed)) return null;
  const meant = typed.endsWith(".") ? typed.slice(0, -1) : typed;
  return meant.startsWith(".") ? "0" + meant : meant;
}

// True when a decimal string means zero: blank, "0", "0.00", "0.0000000".
// Zero means "not filled in yet" — no_cost is the one explicit way to say a
// cook spent nothing. Both the display mapping (zero shows as blank) and the
// close-gate (a meal cannot close while a cook's cost is zero) share this
// test so they agree before and after a reload.
export function isZeroAmountString(value: string | null | undefined): boolean {
  if (value === null || value === undefined) return true;
  const str = String(value).trim();
  if (str === "") return true;
  return /^0+(\.0*)?$/.test(str);
}

// The display form of a wire amount. Zero shows as blank ("not filled in
// yet"). Anything else keeps its exact value, zero-padded to at least two
// decimals by string edits alone — Rails drops trailing zeros, so "50.0"
// arrives for a $50.00 bill. Never a float, never rounding, never
// truncating: a value the ledger does not hold can never appear on screen.
export function toDisplayAmountString(wire: string | null | undefined): string {
  if (isZeroAmountString(wire)) return "";
  const str = String(wire);
  const dot = str.indexOf(".");
  if (dot === -1) return str + ".00";
  const decimals = str.length - dot - 1;
  return decimals < 2 ? str + "0".repeat(2 - decimals) : str;
}

// True when two amount strings are the same number of cents: "5", "5.0"
// and "05.00" are the same, and so are "" and "0.0". String edits only,
// like the rest of this file: leading zeros are dropped, then both sides
// are compared in their display form.
export function sameAmount(a: string, b: string): boolean {
  return (
    toDisplayAmountString(a.replace(/^0+(?=\d)/, "")) ===
    toDisplayAmountString(b.replace(/^0+(?=\d)/, ""))
  );
}
