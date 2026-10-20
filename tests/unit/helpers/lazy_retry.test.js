// The chunk retry: reload once when a page's code file is gone after a
// deploy, and send a second failure in a row to the error page.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import lazyRetry from "../../../app/frontend/src/helpers/lazy_retry.js";

let reload;

let fetchMock;

beforeEach(function () {
  sessionStorage.clear();
  vi.stubGlobal("__BUILD_ID__", "build-2");
  reload = vi.fn();
  vi.stubGlobal("location", { reload: reload });
  fetchMock = vi.fn(function () {
    return Promise.resolve({ ok: true });
  });
  vi.stubGlobal("fetch", fetchMock);
});

afterEach(function () {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("lazyRetry", () => {
  it("loads the chunk when the import works", async () => {
    const chunk = { default: "Page" };

    await expect(lazyRetry(() => Promise.resolve(chunk))()).resolves.toBe(
      chunk,
    );
    expect(reload).not.toHaveBeenCalled();
  });

  it("reloads once when the import fails, and marks the build that did", () => {
    lazyRetry(() => Promise.reject(new Error("gone")))();

    return vi.waitFor(function () {
      expect(reload).toHaveBeenCalledTimes(1);
      expect(sessionStorage.getItem("chunk_retry")).toBe("build-2");
    });
  });

  // A tab that reloaded at an earlier deploy still holds that build's
  // mark. A failure in this build is a first one, so it reloads.
  it("reloads again at a later deploy", () => {
    sessionStorage.setItem("chunk_retry", "build-1");

    lazyRetry(() => Promise.reject(new Error("gone")))();

    return vi.waitFor(function () {
      expect(reload).toHaveBeenCalledTimes(1);
      expect(sessionStorage.getItem("chunk_retry")).toBe("build-2");
    });
  });

  // After a reload one chunk can load while another is still missing.
  // That second failure is in the build that already reloaded, so it goes
  // to the error page. Reloading would load the first chunk, fail on the
  // second, and reload again with no end.
  it("does not reload twice in one build, even when another chunk loaded in between", async () => {
    sessionStorage.setItem("chunk_retry", "build-2");
    await lazyRetry(() => Promise.resolve({ default: "Page" }))();
    const error = new Error("still gone");

    await expect(lazyRetry(() => Promise.reject(error))()).rejects.toBe(error);
    expect(reload).not.toHaveBeenCalled();
  });

  // An import fails for every page during a deploy too: Heroku answers
  // every file with its maintenance page. A reload then would land on
  // that page, which never reloads, so the reload waits for the server.
  it("waits until the server answers before it reloads", async () => {
    vi.useFakeTimers();
    fetchMock.mockImplementationOnce(function () {
      return Promise.resolve({ ok: false });
    });
    fetchMock.mockImplementationOnce(function () {
      return Promise.reject(new TypeError("Failed to fetch"));
    });

    lazyRetry(() => Promise.reject(new Error("gone")))();
    await vi.advanceTimersByTimeAsync(0);
    expect(fetchMock).toHaveBeenCalledWith("/api/v1/version", {
      cache: "no-store",
    });
    expect(reload).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(30 * 1000);
    expect(reload).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(30 * 1000);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(reload).toHaveBeenCalledTimes(1);
  });

  it("sends a second failure in the same build to the error page, and clears the mark", async () => {
    sessionStorage.setItem("chunk_retry", "build-2");
    const error = new Error("gone again");

    await expect(lazyRetry(() => Promise.reject(error))()).rejects.toBe(error);
    expect(reload).not.toHaveBeenCalled();
    expect(sessionStorage.getItem("chunk_retry")).toBeNull();
  });
});
