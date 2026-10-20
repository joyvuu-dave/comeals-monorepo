import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { lazyRetry } from "../../../app/frontend/src/helpers/lazy_retry";
import { fakeLocation } from "../helpers/fake_location.js";

// A page's code is a separate file (a chunk). After a deploy, a page
// loaded before it can ask for a chunk the server no longer has. The
// page then reloads once, to get the new build.
describe("lazyRetry", () => {
  let fake;

  beforeEach(() => {
    sessionStorage.clear();
    fake = fakeLocation();
    vi.stubGlobal("__BUILD_ID__", "build-2");
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
    await Promise.resolve();
    await Promise.resolve();

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
    await Promise.resolve();
    await Promise.resolve();
    expect(fake.location.reload).toHaveBeenCalledTimes(1);

    // The reload brings build 2, and its chunk loads.
    vi.stubGlobal("__BUILD_ID__", "build-2");
    await expect(
      lazyRetry(() => Promise.resolve(chunk), vi.fn())(),
    ).resolves.toBe(chunk);

    // The next deploy removes build 2's chunk.
    const beforeReload = vi.fn();
    lazyRetry(missing, beforeReload)();
    await Promise.resolve();
    await Promise.resolve();

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
});
