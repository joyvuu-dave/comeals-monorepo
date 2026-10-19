import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// nav_trace times a click on the calendar until the result is on the
// screen, in development only. In a production build import.meta.env.DEV
// is false, so every function returns at once. Both versions are loaded
// here: each test loads a fresh copy of the file with DEV set.
async function loadNavTrace(dev) {
  vi.stubEnv("DEV", dev);
  vi.resetModules();
  return await import("../../../app/frontend/src/helpers/nav_trace.js");
}

let fetchMock;
let frames;
let now;

beforeEach(() => {
  fetchMock = vi.fn(() => Promise.resolve());
  vi.stubGlobal("fetch", fetchMock);
  // The breakdown waits two animation frames. A test runs them itself.
  frames = [];
  vi.stubGlobal("requestAnimationFrame", (callback) => frames.push(callback));
  now = 0;
  vi.spyOn(performance, "now").mockImplementation(() => now);
  vi.spyOn(Date, "now").mockReturnValue(1234);
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "groupCollapsed").mockImplementation(() => {});
  vi.spyOn(console, "table").mockImplementation(() => {});
  vi.spyOn(console, "groupEnd").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function runFrames() {
  while (frames.length > 0) frames.shift()();
}

function postedBody(call = 0) {
  return JSON.parse(fetchMock.mock.calls[call][1].body);
}

describe("in development", () => {
  it("prints each step's time after the second frame, and posts it", async () => {
    const { mark, reportAfterPaint } = await loadNavTrace(true);
    now = 10;
    mark("click");
    now = 12.34;
    mark("month-loaded", { month: "2026-10" });

    reportAfterPaint("next month");
    // One frame is not enough: the first one only starts the paint.
    expect(frames).toHaveLength(1);
    frames.shift()();
    expect(console.table).not.toHaveBeenCalled();
    now = 20;
    runFrames();

    const rows = [
      { leg: "click → month-loaded", ms: 2.3, meta: { month: "2026-10" } },
      { leg: "month-loaded → painted", ms: 7.7 },
    ];
    expect(console.groupCollapsed).toHaveBeenCalledExactlyOnceWith(
      "[nav next month] total 10ms",
    );
    expect(console.table).toHaveBeenCalledExactlyOnceWith(rows);
    expect(console.groupEnd).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledExactlyOnceWith("/__perf/log", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: expect.any(String),
      keepalive: true,
    });
    expect(postedBody()).toEqual({
      ts: 1234,
      kind: "nav",
      label: "next month",
      total: 10,
      rows,
    });
  });

  // Each report takes the marks made since the one before.
  it("starts a new list of marks after each report", async () => {
    const { mark, reportAfterPaint } = await loadNavTrace(true);
    mark("first click");
    reportAfterPaint("one");
    mark("second click");
    reportAfterPaint("two");
    runFrames();

    expect(console.table.mock.calls).toEqual([
      [[{ leg: "first click → painted", ms: 0 }]],
      [[{ leg: "second click → painted", ms: 0 }]],
    ]);
  });

  // With no mark before the report, the only entry is "painted", and
  // one entry has no step to time.
  it("prints nothing for a report with no marks", async () => {
    const { reportAfterPaint } = await loadNavTrace(true);
    reportAfterPaint("empty");
    runFrames();
    expect(console.groupCollapsed).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("prints and posts a render of 2ms or more", async () => {
    const { profileRender } = await loadNavTrace(true);
    profileRender("Calendar", "update", 2.04);
    expect(console.log).toHaveBeenCalledExactlyOnceWith(
      "[profile Calendar] update 2.0ms",
    );
    expect(postedBody()).toEqual({
      ts: 1234,
      kind: "profile",
      id: "Calendar",
      phase: "update",
      actualDuration: 2,
    });
  });

  it("leaves out a render under 2ms", async () => {
    const { profileRender } = await loadNavTrace(true);
    profileRender("Calendar", "update", 1.99);
    expect(console.log).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  // The log is for the developer. A failed post must not reach the app.
  it("ignores a post that fails", async () => {
    const { profileRender } = await loadNavTrace(true);
    const failed = Promise.reject(new Error("the dev server is down"));
    fetchMock.mockReturnValue(failed);
    expect(() => profileRender("Calendar", "mount", 5)).not.toThrow();
    // The catch is on the promise fetch returned, so nothing is left
    // unhandled.
    await expect(failed).rejects.toThrow("the dev server is down");
  });

  it("ignores a fetch that throws", async () => {
    const { profileRender } = await loadNavTrace(true);
    fetchMock.mockImplementation(() => {
      throw new TypeError("fetch is not allowed here");
    });
    expect(() => profileRender("Calendar", "mount", 5)).not.toThrow();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});

describe("in a production build", () => {
  it("does nothing at all", async () => {
    const { mark, reportAfterPaint, profileRender } = await loadNavTrace(false);
    mark("click", { month: "2026-10" });
    reportAfterPaint("next month");
    profileRender("Calendar", "update", 50);

    expect(frames).toEqual([]);
    expect(performance.now).not.toHaveBeenCalled();
    expect(console.log).not.toHaveBeenCalled();
    expect(console.table).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
