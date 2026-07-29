import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import Bugsnag from "@bugsnag/js";

// The module reads import.meta.env at load time, so each case has to
// re-import it with the environment already stubbed.
async function loadHelper() {
  vi.resetModules();
  return import("../../../app/frontend/src/helpers/bugsnag.js");
}

describe("bugsnag helper", () => {
  beforeEach(() => {
    vi.spyOn(Bugsnag, "start").mockImplementation(() => {});
    vi.spyOn(Bugsnag, "notify").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  // The important case. A test run and `vite dev` must never report, and
  // the local checkout has no key at all, so both guards are load-bearing.
  it("does not start without an API key", async () => {
    vi.stubEnv("VITE_BUGSNAG_API_KEY", "");
    vi.stubEnv("PROD", true);

    const { startBugsnag } = await loadHelper();

    expect(startBugsnag()).toBe(false);
    expect(Bugsnag.start).not.toHaveBeenCalled();
  });

  it("does not start outside a production build, even with a key", async () => {
    vi.stubEnv("VITE_BUGSNAG_API_KEY", "abc123");
    vi.stubEnv("PROD", false);

    const { startBugsnag } = await loadHelper();

    expect(startBugsnag()).toBe(false);
    expect(Bugsnag.start).not.toHaveBeenCalled();
  });

  it("starts once when the key is present in a production build", async () => {
    vi.stubEnv("VITE_BUGSNAG_API_KEY", "abc123");
    vi.stubEnv("PROD", true);

    const { startBugsnag } = await loadHelper();

    expect(startBugsnag()).toBe(true);
    expect(startBugsnag()).toBe(false);
    expect(Bugsnag.start).toHaveBeenCalledTimes(1);
    expect(Bugsnag.start).toHaveBeenCalledWith(
      expect.objectContaining({
        apiKey: "abc123",
        enabledReleaseStages: ["production"],
      }),
    );
  });

  describe("notifyError", () => {
    // The error boundary calls this on every render error. Before Bugsnag
    // has started, notify only logs a console warning and drops the error,
    // so the guard keeps that noise out of a normal dev session.
    it("does nothing before start", async () => {
      vi.stubEnv("VITE_BUGSNAG_API_KEY", "");
      const { notifyError } = await loadHelper();

      expect(notifyError(new Error("boom"))).toBe(false);
      expect(Bugsnag.notify).not.toHaveBeenCalled();
    });

    it("reports after start, with the React component stack", async () => {
      vi.stubEnv("VITE_BUGSNAG_API_KEY", "abc123");
      vi.stubEnv("PROD", true);
      const { startBugsnag, notifyError } = await loadHelper();
      startBugsnag();

      const error = new Error("boom");
      const addMetadata = vi.fn();
      Bugsnag.notify.mockImplementation((_err, onError) =>
        onError({ addMetadata }),
      );

      expect(notifyError(error, { componentStack: "at Calendar" })).toBe(true);
      expect(Bugsnag.notify).toHaveBeenCalledWith(error, expect.any(Function));
      expect(addMetadata).toHaveBeenCalledWith("react", {
        componentStack: "at Calendar",
      });
    });
  });
});
