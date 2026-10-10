import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";

vi.mock("../../../app/frontend/src/helpers/bugsnag", () => ({
  notifyError: vi.fn(),
}));

import ErrorBoundary from "../../../app/frontend/src/components/app/error_boundary.jsx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag";
import { fakeLocation } from "../helpers/fake_location.js";

function Bomb() {
  throw new Error("boom");
}

describe("ErrorBoundary", () => {
  // React and the boundary itself both log the caught error. Silence
  // that inside these tests so the output stays readable. The
  // notifyError mock is a vi.fn(), which restoreAllMocks leaves alone,
  // so clear its calls here: each test then sees only its own render.
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
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
  it("notes the crash in the store", () => {
    const store = { markPageCrashed: vi.fn() };
    render(
      <StoreContext.Provider value={store}>
        <ErrorBoundary>
          <Bomb />
        </ErrorBoundary>
      </StoreContext.Provider>,
    );
    expect(store.markPageCrashed).toHaveBeenCalledTimes(1);
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
