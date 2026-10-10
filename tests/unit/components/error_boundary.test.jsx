import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { useEffect } from "react";

vi.mock("../../../app/frontend/src/helpers/bugsnag", () => ({
  notifyError: vi.fn(),
}));

import ErrorBoundary from "../../../app/frontend/src/components/app/error_boundary.jsx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag";
import { fakeLocation } from "../helpers/fake_location.js";

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

describe("ErrorBoundary", () => {
  // React and the boundary itself both log the caught error. Silence
  // that inside these tests so the output stays readable. The
  // notifyError mock is a vi.fn(), which restoreAllMocks leaves alone,
  // so clear its calls here: each test then sees only its own render.
  beforeEach(() => {
    vi.clearAllMocks();
    sessionStorage.clear();
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
    sessionStorage.clear();
  });

  it("renders its children when nothing throws", () => {
    render(
      <ErrorBoundary>
        <p>all fine</p>
      </ErrorBoundary>,
    );
    expect(screen.getByText("all fine")).toBeInTheDocument();
    expect(notifyError).not.toHaveBeenCalled();
  });

  it("replaces a crashed child with the fallback screen", () => {
    render(
      <ErrorBoundary>
        <Bomb />
      </ErrorBoundary>,
    );
    expect(
      screen.getByText("Something went wrong with Comeals."),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument();
  });

  it("reports the error to Bugsnag with the component stack", () => {
    render(
      <ErrorBoundary>
        <Bomb />
      </ErrorBoundary>,
    );
    expect(notifyError).toHaveBeenCalledTimes(1);
    const [error, meta] = notifyError.mock.lastCall;
    expect(error.message).toBe("boom");
    expect(meta.componentStack).toContain("Bomb");
  });

  // The idle timer reads the note and loads today's calendar: the
  // error page stays when the address changes, so a move inside the
  // app would leave it on screen (components/app/back_to_today.tsx).
  // The note carries how long the timer waits: five minutes after the
  // first crash.
  it("notes the crash in the store, with the wait before the reload", () => {
    const store = { markPageCrashed: vi.fn() };
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <Bomb />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    expect(store.markPageCrashed).toHaveBeenCalledTimes(1);
    expect(store.markPageCrashed).toHaveBeenCalledWith(5 * 60 * 1000);
  });

  // Two parts of the page can fail in one go. That is one crash, so it
  // is counted once, and the wait is the one for a first crash. Counted
  // twice, it would wait ten minutes. Each error is still reported.
  it("counts two errors that arrive together as one crash", () => {
    const store = { markPageCrashed: vi.fn() };
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <EffectBomb message="first" />
          <EffectBomb message="second" />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    expect(
      screen.getByText("Something went wrong with Comeals."),
    ).toBeInTheDocument();
    expect(store.markPageCrashed).toHaveBeenCalledTimes(1);
    expect(store.markPageCrashed).toHaveBeenCalledWith(5 * MINUTE);
    expect(sessionStorage.getItem("crashReloads")).toBe("1");
    expect(notifyError).toHaveBeenCalledTimes(2);
  });

  // A page that crashes every time it loads must not load every five
  // minutes all day (helpers/crash_reload_wait.ts).
  it("notes a longer wait when the page keeps crashing", () => {
    sessionStorage.setItem("crashReloads", "3");
    const store = { markPageCrashed: vi.fn() };
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <Bomb />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    expect(store.markPageCrashed).toHaveBeenCalledWith(40 * 60 * 1000);
  });

  // The store may be what broke. The error page shows anyway, and the
  // one error reported is the one that crashed the page.
  it("shows the error page when the store cannot take the note", () => {
    const store = {
      markPageCrashed: vi.fn(() => {
        throw new Error("[mobx-state-tree] the store is dead");
      }),
    };
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <Bomb />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    expect(
      screen.getByText("Something went wrong with Comeals."),
    ).toBeInTheDocument();
    expect(notifyError).toHaveBeenCalledTimes(1);
    expect(notifyError.mock.lastCall[0].message).toBe("boom");
  });

  // The idle timer loads a crashed page because it reads the note
  // (back_to_today.tsx). When the store cannot take the note, the timer
  // never learns of the crash, and the crash page would stay for good.
  // So the page starts its own plain timer with the same wait, the way
  // OuterErrorBoundary does, and loads "/" when it runs out.
  describe("when the store cannot take the note", () => {
    let location;
    let restoreLocation;

    beforeEach(() => {
      vi.useFakeTimers();
      ({ location, restore: restoreLocation } = fakeLocation({
        assign: vi.fn(),
      }));
    });

    afterEach(() => {
      restoreLocation();
      vi.useRealTimers();
    });

    function brokenStore() {
      return {
        markPageCrashed: vi.fn(() => {
          throw new Error("[mobx-state-tree] the store is dead");
        }),
        finishBillsSaves: vi.fn(() => Promise.resolve(true)),
      };
    }

    function renderCrash(store) {
      return render(
        <StoreContext.Provider value={store}>
          <ErrorBoundary>
            <Bomb />
          </ErrorBoundary>
        </StoreContext.Provider>,
      );
    }

    // The fake clock runs the wait, and the promises of the saves
    // settle.
    async function wait(ms) {
      await act(async () => {
        await vi.advanceTimersByTimeAsync(ms);
      });
    }

    it("sends the waiting saves, then loads '/' by itself five minutes after the first crash", async () => {
      const store = brokenStore();
      renderCrash(store);

      await wait(5 * MINUTE - 1);
      expect(store.finishBillsSaves).not.toHaveBeenCalled();
      expect(location.assign).not.toHaveBeenCalled();

      await wait(1);
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(location.assign).toHaveBeenCalledTimes(1);
      expect(location.assign).toHaveBeenCalledWith("/");
    });

    // A page that crashes every time it loads must not load every five
    // minutes all day (helpers/crash_reload_wait.ts).
    it("waits longer when the page keeps crashing", async () => {
      sessionStorage.setItem("crashReloads", "3");
      renderCrash(brokenStore());

      await wait(40 * MINUTE - 1);
      expect(location.assign).not.toHaveBeenCalled();

      await wait(1);
      expect(location.assign).toHaveBeenCalledWith("/");
    });

    // Every part of the store may be dead, the wait for the saves too.
    // Nothing else takes the screen off this page, so it loads anyway.
    it("loads '/' when the store has nothing left that works", async () => {
      renderCrash({});

      await wait(5 * MINUTE);
      expect(location.assign).toHaveBeenCalledWith("/");
    });

    it("loads nothing once the page is gone", async () => {
      const { unmount } = renderCrash(brokenStore());
      unmount();

      await wait(60 * MINUTE);
      expect(location.assign).not.toHaveBeenCalled();
    });

    // With a store that takes the note, the idle timer does the load. A
    // second timer here would load the page twice.
    it("starts no timer of its own when the store takes the note", () => {
      const timers = vi.getTimerCount();
      renderCrash({ markPageCrashed: vi.fn() });
      expect(vi.getTimerCount()).toBe(timers);
    });
  });

  // A reload ends every request on its way, so Refresh first waits for
  // the bills saves on their way (finishBillsSaves, #150). index.jsx
  // puts the boundary inside the store's provider.
  it("Refresh waits for the bills saves, then reloads the page", async () => {
    let saved;
    const store = {
      finishBillsSaves: vi.fn(
        () =>
          new Promise((resolve) => {
            saved = resolve;
          }),
      ),
    };
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <Bomb />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    const { location, restore } = fakeLocation();
    try {
      fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(location.reload).not.toHaveBeenCalled();

      await act(async () => saved(true));

      expect(location.reload).toHaveBeenCalledTimes(1);
    } finally {
      restore();
    }
  });

  // Renders the error page with this store, and taps Refresh. Hands
  // back the fake location.
  async function tapRefresh(store) {
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <Bomb />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    vi.mocked(notifyError).mockClear();
    const fake = fakeLocation();
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    });
    return fake;
  }

  // A save it waited for was not saved. The message shows above this
  // page (index.jsx puts the messages outside the boundary), and a
  // reload would take it away before the person could read it. The
  // next tap goes on.
  it("Refresh does not reload when a save it waited for was not saved", async () => {
    const store = { finishBillsSaves: vi.fn(() => Promise.resolve(false)) };
    const { location, restore } = await tapRefresh(store);
    try {
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(location.reload).not.toHaveBeenCalled();
    } finally {
      restore();
    }
  });

  // This page shows because something threw, and the store may be what
  // broke. Refresh is the only way off the page, so it reloads even when
  // the wait fails, and the failure is reported.
  it("Refresh reloads, and reports it, when the wait for the bills saves throws", async () => {
    const broken = new Error("[mobx-state-tree] Failed to resolve reference");
    const store = {
      finishBillsSaves: vi.fn(() => {
        throw broken;
      }),
    };
    const { location, restore } = await tapRefresh(store);
    try {
      expect(location.reload).toHaveBeenCalledTimes(1);
      expect(notifyError).toHaveBeenCalledWith(broken);
    } finally {
      restore();
    }
  });

  it("Refresh reloads, and reports it, when the wait for the bills saves fails", async () => {
    const broken = new Error("[mobx-state-tree] Failed to resolve reference");
    const store = { finishBillsSaves: vi.fn(() => Promise.reject(broken)) };
    const { location, restore } = await tapRefresh(store);
    try {
      expect(location.reload).toHaveBeenCalledTimes(1);
      expect(notifyError).toHaveBeenCalledWith(broken);
    } finally {
      restore();
    }
  });
});
