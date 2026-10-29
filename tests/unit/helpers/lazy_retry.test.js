import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { lazyRetry } from "../../../app/frontend/src/helpers/lazy_retry";
import { fakeLocation } from "../helpers/fake_location.js";
import { expectConsole } from "./console_output.js";

// A page's code is a separate file (a chunk). After a deploy, a page
// loaded before it can ask for a chunk the server no longer has. The
// page then reloads once, to get the new build.
// Lets the import's failure and the server's answer go through.
function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

describe("lazyRetry", () => {
  let fake;

  beforeEach(() => {
    sessionStorage.clear();
    fake = fakeLocation();
    vi.stubGlobal("__BUILD_ID__", "build-2");
    // The server answers, so a reload goes ahead at once (see "while the
    // server is down" below for the wait).
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve({ ok: true, status: 200 })),
    );
  });

  afterEach(() => {
    fake.restore();
    sessionStorage.clear();
    vi.unstubAllGlobals();
  });

  it("hands back the chunk when it loads", async () => {
    const chunk = { default: () => null };
    const beforeReload = vi.fn();

    await expect(
      lazyRetry(() => Promise.resolve(chunk), beforeReload)(),
    ).resolves.toBe(chunk);

    expect(beforeReload).not.toHaveBeenCalled();
    expect(fake.location.reload).not.toHaveBeenCalled();
  });

  // The reload ends every request on its way, so beforeReload runs
  // first: it hands the bills saves on their way to the browser (#150).
  it("reloads once when the chunk fails, after beforeReload", async () => {
    const beforeReload = vi.fn();
    const load = lazyRetry(
      () => Promise.reject(new Error("no chunk")),
      beforeReload,
    );

    load();
    await flush();

    expect(beforeReload).toHaveBeenCalledTimes(1);
    expect(fake.location.reload).toHaveBeenCalledTimes(1);
    expect(beforeReload.mock.invocationCallOrder[0]).toBeLessThan(
      fake.location.reload.mock.invocationCallOrder[0],
    );
    expect(sessionStorage.getItem("chunk_retry")).toBe("build-2");
  });

  // The reload already happened once in this build. A second failure is
  // a real error, and it goes to the error page.
  it("fails, with no reload, when the chunk fails again after the reload", async () => {
    sessionStorage.setItem("chunk_retry", "build-2");
    const beforeReload = vi.fn();
    const failure = new Error("no chunk");

    await expect(
      lazyRetry(() => Promise.reject(failure), beforeReload)(),
    ).rejects.toBe(failure);

    expect(beforeReload).not.toHaveBeenCalled();
    expect(fake.location.reload).not.toHaveBeenCalled();
    expect(sessionStorage.getItem("chunk_retry")).toBeNull();
  });

  // A tab reloaded once for a missing chunk at one deploy, and the
  // reload worked. At the next deploy a chunk is missing again. That is
  // a new first failure, so the page reloads again; it does not go
  // straight to the error page.
  it("reloads again at a later deploy, after a reload that worked", async () => {
    const chunk = { default: () => null };
    const missing = () => Promise.reject(new Error("no chunk"));

    // The tab runs build 1, and a deploy removes its chunk.
    vi.stubGlobal("__BUILD_ID__", "build-1");
    lazyRetry(missing, vi.fn())();
    await flush();
    expect(fake.location.reload).toHaveBeenCalledTimes(1);

    // The reload brings build 2, and its chunk loads.
    vi.stubGlobal("__BUILD_ID__", "build-2");
    await expect(
      lazyRetry(() => Promise.resolve(chunk), vi.fn())(),
    ).resolves.toBe(chunk);

    // The next deploy removes build 2's chunk.
    const beforeReload = vi.fn();
    lazyRetry(missing, beforeReload)();
    await flush();

    expect(beforeReload).toHaveBeenCalledTimes(1);
    expect(fake.location.reload).toHaveBeenCalledTimes(2);
  });

  // After the reload one chunk loads and another is still missing (a
  // build with a chunk missing). That is the second failure in this
  // build, so it goes to the error page. If the chunk that loaded had
  // removed the flag, the page would reload again and again.
  it("fails, with no reload, when a chunk loads and another fails after the reload", async () => {
    const chunk = { default: () => null };
    const failure = new Error("no chunk");
    sessionStorage.setItem("chunk_retry", "build-2");

    await expect(
      lazyRetry(() => Promise.resolve(chunk), vi.fn())(),
    ).resolves.toBe(chunk);
    expect(sessionStorage.getItem("chunk_retry")).toBe("build-2");

    const beforeReload = vi.fn();
    await expect(
      lazyRetry(() => Promise.reject(failure), beforeReload)(),
    ).rejects.toBe(failure);

    expect(beforeReload).not.toHaveBeenCalled();
    expect(fake.location.reload).not.toHaveBeenCalled();
  });

  // During a deploy Heroku answers every file with its maintenance page
  // (an HTML 503), so the chunk fails to load. A reload then would land
  // on that page, which never reloads itself. So the page asks the server
  // for its version every 30 seconds, and reloads only once the server
  // answers. Meanwhile the page keeps showing its "Loading..." words.
  describe("while the server is down", () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    it("waits for the server to answer ok, asking every 30 seconds, then reloads", async () => {
      const fetch = vi
        .fn()
        .mockResolvedValueOnce({ ok: false, status: 503 })
        .mockRejectedValueOnce(new TypeError("Failed to fetch"))
        .mockResolvedValueOnce({ ok: true, status: 200 });
      vi.stubGlobal("fetch", fetch);
      const beforeReload = vi.fn();

      lazyRetry(() => Promise.reject(new Error("no chunk")), beforeReload)();
      await vi.advanceTimersByTimeAsync(0);

      expect(fetch).toHaveBeenCalledTimes(1);
      expect(fetch).toHaveBeenCalledWith("/api/v1/version", {
        cache: "no-store",
      });
      expect(beforeReload).not.toHaveBeenCalled();
      expect(fake.location.reload).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(29999);
      expect(fetch).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(fetch).toHaveBeenCalledTimes(2);
      expect(fake.location.reload).not.toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(30000);
      expect(fetch).toHaveBeenCalledTimes(3);
      expect(beforeReload).toHaveBeenCalledTimes(1);
      expect(fake.location.reload).toHaveBeenCalledTimes(1);
      expect(beforeReload.mock.invocationCallOrder[0]).toBeLessThan(
        fake.location.reload.mock.invocationCallOrder[0],
      );
    });
  });
  // A browser set to block site data throws on any use of sessionStorage
  // (#162), and one that is out of space throws on a write. Then the
  // page cannot remember that it reloaded, so a reload could not tell the
  // first failure from the second: a file that stays missing would
  // reload the page over and over. So with storage it cannot use, the
  // page never reloads. It takes the second-failure path at once: the
  // chunk's own error goes on (to the error page, or for Pusher to
  // Bugsnag), and the storage error is never thrown.
  describe("when the browser refuses sessionStorage", () => {
    // lazy_retry.ts warns once each time it cannot use sessionStorage,
    // and every test here makes it fail.
    beforeEach(() => {
      expectConsole("warn", /^This browser refuses sessionStorage:/);
    });

    afterEach(() => {
      vi.restoreAllMocks();
    });

    function refuseStorage() {
      vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
        throw new DOMException("The operation is insecure.", "SecurityError");
      });
    }

    it("fails with the chunk's error, with no reload", async () => {
      refuseStorage();
      const beforeReload = vi.fn();
      const failure = new Error("no chunk");

      await expect(
        lazyRetry(() => Promise.reject(failure), beforeReload)(),
      ).rejects.toBe(failure);

      expect(beforeReload).not.toHaveBeenCalled();
      expect(fake.location.reload).not.toHaveBeenCalled();
    });

    // The loop the rule is there to stop: every load of the page fails
    // the same way, and none of them reloads.
    it("never reloads when the chunk keeps failing", async () => {
      refuseStorage();
      const beforeReload = vi.fn();
      const failure = new Error("no chunk");

      for (let load = 0; load < 3; load += 1) {
        await expect(
          lazyRetry(() => Promise.reject(failure), beforeReload)(),
        ).rejects.toBe(failure);
        await flush();
      }

      expect(beforeReload).not.toHaveBeenCalled();
      expect(fake.location.reload).not.toHaveBeenCalled();
    });

    it("fails with the chunk's error, with no reload, when the flag cannot be written", async () => {
      vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
        throw new DOMException(
          "The quota has been exceeded.",
          "QuotaExceededError",
        );
      });
      const beforeReload = vi.fn();
      const failure = new Error("no chunk");

      await expect(
        lazyRetry(() => Promise.reject(failure), beforeReload)(),
      ).rejects.toBe(failure);

      expect(beforeReload).not.toHaveBeenCalled();
      expect(fake.location.reload).not.toHaveBeenCalled();
    });

    // The second failure removes the flag. If the removal throws, the
    // chunk's error still goes on.
    it("fails with the chunk's error when the flag cannot be removed", async () => {
      sessionStorage.setItem("chunk_retry", "build-2");
      vi.spyOn(Storage.prototype, "removeItem").mockImplementation(() => {
        throw new DOMException("The operation is insecure.", "SecurityError");
      });
      const failure = new Error("no chunk");

      await expect(
        lazyRetry(() => Promise.reject(failure), vi.fn())(),
      ).rejects.toBe(failure);

      expect(fake.location.reload).not.toHaveBeenCalled();
    });
  });
});
