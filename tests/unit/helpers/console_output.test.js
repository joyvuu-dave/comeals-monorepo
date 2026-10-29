import { describe, it, expect, afterEach } from "vitest";
import {
  clearExpected,
  expectConsole,
  expectedNotSeen,
  isExpected,
} from "./console_output.js";

// The rules render_setup.js applies to console output (#249). These call
// the helper directly and clear it after each test, so the setup's own
// check at the end of the test sees nothing left over.
describe("expected console output", () => {
  afterEach(() => clearExpected());

  it("allows a message that matches, and counts the expectation as met", () => {
    expectConsole("error", /^Bad response/);

    expect(isExpected("error", "Bad response from server 500")).toBe(true);
    expect(expectedNotSeen()).toEqual([]);
  });

  it("does not allow a message for another method or another text", () => {
    expectConsole("error", /^Bad response/);

    expect(isExpected("warn", "Bad response from server 500")).toBe(false);
    expect(isExpected("error", "Something else")).toBe(false);
    expect(expectedNotSeen()).toEqual(["console.error: /^Bad response/"]);
  });

  it("needs the message twice when the same pattern is declared twice", () => {
    expectConsole("error", /^No\.$/);
    expectConsole("error", /^No\.$/);

    isExpected("error", "No.");
    expect(expectedNotSeen()).toEqual(["console.error: /^No\\.$/"]);

    isExpected("error", "No.");
    expect(expectedNotSeen()).toEqual([]);
  });

  it("still allows the message after every expectation is met", () => {
    expectConsole("warn", /refuses sessionStorage/);

    isExpected("warn", "This browser refuses sessionStorage: x");

    expect(isExpected("warn", "This browser refuses sessionStorage: y")).toBe(
      true,
    );
  });

  it("forgets every expectation when cleared", () => {
    expectConsole("error", /x/);

    clearExpected();

    expect(expectedNotSeen()).toEqual([]);
    expect(isExpected("error", "x")).toBe(false);
  });
});
