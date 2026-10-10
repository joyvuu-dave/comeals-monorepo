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
  });

  afterEach(() => {
    fake.restore();
    sessionStorage.clear();
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
    expect(sessionStorage.getItem("chunk_retry")).toBe("1");
  });

  // The reload already happened once. A second failure is a real error,
  // and it goes to the error page.
  it("fails, with no reload, when the chunk fails again after the reload", async () => {
    sessionStorage.setItem("chunk_retry", "1");
    const beforeReload = vi.fn();
    const failure = new Error("no chunk");

    await expect(
      lazyRetry(() => Promise.reject(failure), beforeReload)(),
    ).rejects.toBe(failure);

    expect(beforeReload).not.toHaveBeenCalled();
    expect(fake.location.reload).not.toHaveBeenCalled();
    expect(sessionStorage.getItem("chunk_retry")).toBeNull();
  });
});
