import { describe, it, expect } from "vitest";
import {
  isValidAmountString,
  isZeroAmountString,
  toDisplayAmountString,
} from "../../../app/frontend/src/helpers/money";

describe("isValidAmountString", () => {
  it("accepts empty (not filled in yet)", () => {
    expect(isValidAmountString("")).toBe(true);
  });

  it("accepts whole-cent amounts from 0 to 9999.99", () => {
    expect(isValidAmountString("0")).toBe(true);
    expect(isValidAmountString("0.5")).toBe(true);
    expect(isValidAmountString("12")).toBe(true);
    expect(isValidAmountString("12.34")).toBe(true);
    expect(isValidAmountString("9999.99")).toBe(true);
  });

  it("rejects everything else", () => {
    expect(isValidAmountString("12.345")).toBe(false); // sub-cent
    expect(isValidAmountString("10000")).toBe(false); // over the column max
    expect(isValidAmountString("-5")).toBe(false); // negative
    expect(isValidAmountString("1e3")).toBe(false); // scientific notation
    expect(isValidAmountString(".5")).toBe(false); // no leading digit
    expect(isValidAmountString("12.")).toBe(false); // trailing dot
    expect(isValidAmountString("   ")).toBe(false); // whitespace
    expect(isValidAmountString("25abc")).toBe(false); // suffix
  });
});

describe("isZeroAmountString", () => {
  it("treats blank and zero strings as zero", () => {
    expect(isZeroAmountString("")).toBe(true);
    expect(isZeroAmountString("0")).toBe(true);
    expect(isZeroAmountString("0.0")).toBe(true); // Rails wire format for 0
    expect(isZeroAmountString("0.00")).toBe(true);
    expect(isZeroAmountString("0.00000000")).toBe(true);
    expect(isZeroAmountString(null)).toBe(true);
    expect(isZeroAmountString(undefined)).toBe(true);
  });

  it("treats any nonzero amount as nonzero", () => {
    expect(isZeroAmountString("0.01")).toBe(false);
    expect(isZeroAmountString("5")).toBe(false);
    expect(isZeroAmountString("0.00000001")).toBe(false);
  });

  it("does not treat garbage as zero", () => {
    expect(isZeroAmountString("abc")).toBe(false);
  });
});

describe("toDisplayAmountString", () => {
  it("shows zero as blank", () => {
    expect(toDisplayAmountString("0")).toBe("");
    expect(toDisplayAmountString("0.0")).toBe("");
    expect(toDisplayAmountString("")).toBe("");
    expect(toDisplayAmountString(null)).toBe("");
  });

  it("pads to two decimals with string edits (Rails drops trailing zeros)", () => {
    expect(toDisplayAmountString("50.0")).toBe("50.00");
    expect(toDisplayAmountString("35.5")).toBe("35.50");
    expect(toDisplayAmountString("15")).toBe("15.00");
  });

  it("keeps already-padded amounts unchanged", () => {
    expect(toDisplayAmountString("12.34")).toBe("12.34");
  });

  it("never rounds or truncates a value the ledger holds", () => {
    // Legacy sub-cent data (older than the whole-cents CHECK) displays
    // exactly as stored — a rounded display value must not exist at all.
    expect(toDisplayAmountString("12.345")).toBe("12.345");
    expect(toDisplayAmountString("0.00000001")).toBe("0.00000001");
  });
});
