// The chunk retry: reload once when a page's code file is gone after a
// deploy, and send a second failure in a row to the error page.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import lazyRetry from "../../../app/frontend/src/helpers/lazy_retry.js";

let reload;

beforeEach(function () {
  sessionStorage.clear();
  reload = vi.fn();
  vi.stubGlobal("location", { reload: reload });
});

afterEach(function () {
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

  it("reloads once when the import fails, and marks that it did", () => {
    lazyRetry(() => Promise.reject(new Error("gone")))();

    return vi.waitFor(function () {
      expect(reload).toHaveBeenCalledTimes(1);
      expect(sessionStorage.getItem("chunk_retry")).toBe("1");
    });
  });

  it("sends a second failure in a row to the error page, and clears the mark", async () => {
    sessionStorage.setItem("chunk_retry", "1");
    const error = new Error("gone again");

    await expect(lazyRetry(() => Promise.reject(error))()).rejects.toBe(error);
    expect(reload).not.toHaveBeenCalled();
    expect(sessionStorage.getItem("chunk_retry")).toBeNull();
  });

  // The reload worked and the new build's chunk loaded. The mark must go,
  // or this tab goes straight to the error page at the next deploy.
  it("clears the mark when an import works after a reload", async () => {
    sessionStorage.setItem("chunk_retry", "1");

    await lazyRetry(() => Promise.resolve({ default: "Page" }))();

    expect(sessionStorage.getItem("chunk_retry")).toBeNull();
  });
});
