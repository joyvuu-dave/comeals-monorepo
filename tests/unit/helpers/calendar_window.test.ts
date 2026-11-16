import { describe, it, expect } from "vitest";
import {
  earlier,
  firstDay,
  inLastMonthOrAfter,
  lastDay,
} from "../../../app/frontend/src/helpers/calendar_window";

// The same window as the server's CalendarWindow
// (spec/models/calendar_window_spec.rb).
describe("calendar window", () => {
  it("goes from 10 years before today to 10 years after", () => {
    expect([firstDay("2026-11-15"), lastDay("2026-11-15")]).toEqual([
      "2016-11-15",
      "2036-11-15",
    ]);
  });

  it("counts 10 years from February 29 to February 28 at both ends", () => {
    expect([firstDay("2028-02-29"), lastDay("2028-02-29")]).toEqual([
      "2018-02-28",
      "2038-02-28",
    ]);
  });

  it("never goes past December 31, 9999", () => {
    expect(lastDay("9989-12-31")).toBe("9999-12-31");
    expect(lastDay("9990-01-01")).toBe("9999-12-31");
  });

  it("puts the year 10000 after 9999, which a string compare would not", () => {
    expect(earlier("10000-01-01", "9999-12-31")).toBe("9999-12-31");
    expect(earlier("2026-01-02", "2026-01-01")).toBe("2026-01-01");
    expect(earlier("2026-01-01", "2026-01-01")).toBe("2026-01-01");
  });

  it("knows December 9999 is the last month", () => {
    expect(inLastMonthOrAfter("9999-11-30")).toBe(false);
    expect(inLastMonthOrAfter("9999-12-01")).toBe(true);
    expect(inLastMonthOrAfter("10000-01-01")).toBe(true);
  });
});
