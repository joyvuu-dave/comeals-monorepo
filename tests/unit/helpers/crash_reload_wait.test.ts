import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

import {
  forgetCrashesAfterAnHourWithout,
  waitAfterCrash,
} from "../../../app/frontend/src/helpers/crash_reload_wait";

// After a crash the page loads itself again, after a wait. A page that
// crashes every time it loads would otherwise load every five minutes
// all day. So the wait grows with each crash, when the crashes come one
// after another: 5 minutes, then 10, 20, 40, and at most 60. The count
// is kept in sessionStorage, which outlives a page load in the same
// tab, and it starts again once a page has run an hour without a crash.
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

describe("waitAfterCrash", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    sessionStorage.clear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    sessionStorage.clear();
  });

  it("waits 5 minutes after the first crash, then 10, 20, 40, and at most 60", () => {
    const waits = Array.from({ length: 7 }, () => waitAfterCrash() / MINUTE);
    expect(waits).toEqual([5, 10, 20, 40, 60, 60, 60]);
  });

  // Each crash is followed by a page load. The count must outlive it.
  it("keeps the count in sessionStorage, where the next page reads it", () => {
    waitAfterCrash();
    waitAfterCrash();
    expect(sessionStorage.getItem("crashReloads")).toBe("2");

    // A page that keeps crashing stays at the longest wait, and the
    // count stays small.
    for (let i = 0; i < 20; i += 1) waitAfterCrash();
    expect(sessionStorage.getItem("crashReloads")).toBe("4");
    expect(waitAfterCrash()).toBe(60 * MINUTE);
  });

  // With no count to go on, the page might be crashing on every load.
  // The longest wait is the safe one.
  it("waits 60 minutes when the browser refuses sessionStorage", () => {
    vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });
    expect(waitAfterCrash()).toBe(60 * MINUTE);
  });

  it("waits 60 minutes when sessionStorage cannot be written", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException(
        "The quota has been exceeded.",
        "QuotaExceededError",
      );
    });
    expect(waitAfterCrash()).toBe(60 * MINUTE);
  });

  it("waits 60 minutes when sessionStorage holds something that is not a count", () => {
    ["two", "-1", "1.5"].forEach((junk) => {
      sessionStorage.setItem("crashReloads", junk);
      expect(waitAfterCrash()).toBe(60 * MINUTE);
    });
  });
});

describe("forgetCrashesAfterAnHourWithout", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    sessionStorage.clear();
  });

  afterEach(() => {
    // A crash stops the hour's timer, so no test leaves one behind.
    waitAfterCrash();
    vi.restoreAllMocks();
    vi.useRealTimers();
    sessionStorage.clear();
  });

  it("starts the count again once the page has run an hour without a crash", () => {
    waitAfterCrash();
    waitAfterCrash();
    forgetCrashesAfterAnHourWithout();

    vi.advanceTimersByTime(HOUR - 1);
    expect(sessionStorage.getItem("crashReloads")).toBe("2");

    vi.advanceTimersByTime(1);
    expect(sessionStorage.getItem("crashReloads")).toBeNull();
    expect(waitAfterCrash()).toBe(5 * MINUTE);
  });

  // A page that crashed has not run an hour without a crash, however
  // long its error page stays on screen.
  it("keeps the count when the page crashes before the hour is up", () => {
    waitAfterCrash();
    forgetCrashesAfterAnHourWithout();

    vi.advanceTimersByTime(30 * MINUTE);
    expect(waitAfterCrash()).toBe(10 * MINUTE);

    vi.advanceTimersByTime(2 * HOUR);
    expect(sessionStorage.getItem("crashReloads")).toBe("2");
    expect(waitAfterCrash()).toBe(20 * MINUTE);
  });

  it("keeps one hour's timer when it is started twice", () => {
    const before = vi.getTimerCount();
    forgetCrashesAfterAnHourWithout();
    forgetCrashesAfterAnHourWithout();
    expect(vi.getTimerCount()).toBe(before + 1);
  });

  it("does nothing when the browser refuses sessionStorage", () => {
    forgetCrashesAfterAnHourWithout();
    vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });
    expect(() => vi.advanceTimersByTime(HOUR)).not.toThrow();
  });
});
