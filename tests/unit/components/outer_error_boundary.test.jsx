import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { useEffect } from "react";

vi.mock("../../../app/frontend/src/helpers/bugsnag", () => ({
  notifyError: vi.fn(),
}));

import OuterErrorBoundary from "../../../app/frontend/src/components/app/outer_error_boundary";
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag";
import { fakeLocation } from "../helpers/fake_location.js";

// OuterErrorBoundary is around the whole app (index.jsx). ErrorBoundary
// is around the pages only, so a render error in a part of the page
// outside it (the message stack, the banners, the idle timer) took the
// whole page away, timer included, and a shared screen stayed blank
// for good. This one shows the crash page, reports the error, and loads
// "/" by itself after a wait. It uses no store and no context: either
// may be what broke.
const MINUTE = 60 * 1000;

function Bomb() {
  throw new Error("boom");
}

// An error in an effect, not in drawing. React hands it to the nearest
// boundary all the same.
function EffectBomb({ message }) {
  useEffect(() => {
    throw new Error(message);
  }, [message]);
  return null;
}

describe("OuterErrorBoundary", () => {
  let location;
  let restoreLocation;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
    sessionStorage.clear();
    vi.spyOn(console, "error").mockImplementation(() => {});
    ({ location, restore: restoreLocation } = fakeLocation({
      assign: vi.fn(),
    }));
  });

  afterEach(() => {
    restoreLocation();
    vi.restoreAllMocks();
    vi.useRealTimers();
    sessionStorage.clear();
  });

  function savesAnswered(answer = true) {
    return vi.fn(() => Promise.resolve(answer));
  }

  function renderCrash(sendWaitingSaves = savesAnswered()) {
    return render(
      <OuterErrorBoundary sendWaitingSaves={sendWaitingSaves}>
        <Bomb />
      </OuterErrorBoundary>,
    );
  }

  // The fake clock runs the wait, and the promises of the saves settle.
  async function wait(ms) {
    await act(async () => {
      await vi.advanceTimersByTimeAsync(ms);
    });
  }

  it("draws its children when nothing throws, and sets no timer", () => {
    const timers = vi.getTimerCount();
    render(
      <OuterErrorBoundary sendWaitingSaves={savesAnswered()}>
        <p>all fine</p>
      </OuterErrorBoundary>,
    );
    expect(screen.getByText("all fine")).toBeInTheDocument();
    expect(notifyError).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(timers);
  });

  it("shows the crash page with a Refresh button, with no store anywhere", () => {
    renderCrash();
    expect(
      screen.getByText("Something went wrong with Comeals."),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument();
  });

  it("reports the error to Bugsnag with the component stack", () => {
    renderCrash();
    expect(notifyError).toHaveBeenCalledTimes(1);
    const [error, meta] = vi.mocked(notifyError).mock.lastCall;
    expect(error.message).toBe("boom");
    expect(meta.componentStack).toContain("Bomb");
  });

  // Two parts of the page can fail in one go. The page crashed once,
  // so it is reported once, and loads once.
  it("reports once and sets one timer when two errors arrive together", async () => {
    const timers = vi.getTimerCount();
    render(
      <OuterErrorBoundary sendWaitingSaves={savesAnswered()}>
        <EffectBomb message="first" />
        <EffectBomb message="second" />
      </OuterErrorBoundary>,
    );
    expect(
      screen.getByText("Something went wrong with Comeals."),
    ).toBeInTheDocument();
    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(timers + 1);

    await wait(5 * MINUTE);
    expect(location.assign).toHaveBeenCalledTimes(1);
  });

  it("sends the waiting saves, then loads '/' by itself five minutes after the first crash", async () => {
    let answer;
    const sendWaitingSaves = vi.fn(
      () =>
        new Promise((resolve) => {
          answer = resolve;
        }),
    );
    renderCrash(sendWaitingSaves);

    await wait(5 * MINUTE - 1);
    expect(sendWaitingSaves).not.toHaveBeenCalled();

    await wait(1);
    expect(sendWaitingSaves).toHaveBeenCalledTimes(1);
    expect(location.assign).not.toHaveBeenCalled();

    await act(async () => answer(true));
    expect(location.assign).toHaveBeenCalledWith("/");

    // The ten seconds the load would wait at most run out later. They
    // do not load the page a second time.
    await wait(10 * 1000);
    expect(location.assign).toHaveBeenCalledTimes(1);
  });

  // A page that crashes every time it loads must not load every five
  // minutes all day (helpers/crash_reload_wait.ts).
  it("waits longer when the page keeps crashing", async () => {
    sessionStorage.setItem("crashReloads", "2");
    renderCrash();

    await wait(20 * MINUTE - 1);
    expect(location.assign).not.toHaveBeenCalled();

    await wait(1);
    expect(location.assign).toHaveBeenCalledWith("/");
  });

  it("waits 60 minutes when the browser refuses sessionStorage", async () => {
    vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
      throw new DOMException("The operation is insecure.", "SecurityError");
    });
    renderCrash();

    await wait(60 * MINUTE - 1);
    expect(location.assign).not.toHaveBeenCalled();

    await wait(1);
    expect(location.assign).toHaveBeenCalledWith("/");
  });

  // The store may be what broke. Nothing it does may keep the screen on
  // the crash page. The message stack went with the crash, so a save
  // that failed has no message on screen to keep the page for either.
  describe("when the waiting saves go wrong", () => {
    it.each([
      [
        "throw",
        () => {
          throw new Error("[mobx-state-tree] the store is dead");
        },
      ],
      ["fail", () => Promise.reject(new Error("the store is dead"))],
      ["answer that a save was not saved", () => Promise.resolve(false)],
    ])("loads '/' anyway when they %s", async (_name, sendWaitingSaves) => {
      renderCrash(vi.fn(sendWaitingSaves));
      vi.mocked(notifyError).mockClear();

      await wait(5 * MINUTE);
      expect(location.assign).toHaveBeenCalledWith("/");
      // The crash was reported once. The failure here is part of it.
      expect(notifyError).not.toHaveBeenCalled();
    });

    it("loads '/' after ten seconds when they never answer", async () => {
      renderCrash(vi.fn(() => new Promise(() => {})));

      await wait(5 * MINUTE + 10 * 1000 - 1);
      expect(location.assign).not.toHaveBeenCalled();

      await wait(1);
      expect(location.assign).toHaveBeenCalledWith("/");
    });
  });

  it("Refresh sends the waiting saves, then reloads the page", async () => {
    let answer;
    const sendWaitingSaves = vi.fn(
      () =>
        new Promise((resolve) => {
          answer = resolve;
        }),
    );
    renderCrash(sendWaitingSaves);

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    expect(sendWaitingSaves).toHaveBeenCalledTimes(1);
    expect(location.reload).not.toHaveBeenCalled();

    await act(async () => answer(true));
    expect(location.reload).toHaveBeenCalledTimes(1);
    expect(location.assign).not.toHaveBeenCalled();
  });

  // A tap while a load is on its way, or the timer running out during
  // the wait after a tap, does not start a second one.
  it("starts one load, however many times it is asked", async () => {
    const sendWaitingSaves = vi.fn(() => new Promise(() => {}));
    renderCrash(sendWaitingSaves);
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));

    await wait(5 * MINUTE + 10 * 1000);
    expect(sendWaitingSaves).toHaveBeenCalledTimes(1);
    expect(location.reload).toHaveBeenCalledTimes(1);
    expect(location.assign).not.toHaveBeenCalled();
  });

  it("stops its timer when the app goes away", () => {
    const timers = vi.getTimerCount();
    const { unmount } = renderCrash();
    expect(vi.getTimerCount()).toBe(timers + 1);

    unmount();
    expect(vi.getTimerCount()).toBe(timers);
  });
});
