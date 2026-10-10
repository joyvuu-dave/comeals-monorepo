import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act, fireEvent } from "@testing-library/react";
import VersionBanner from "../../../app/frontend/src/components/app/version_banner.jsx";
import { StoreContext } from "../../../app/frontend/src/helpers/store_context.jsx";
import { fakeLocation } from "../helpers/fake_location.js";

// The banner uses two things in the store: the wait for the bills
// saves on their way before a reload (#150), and the note that a new
// version is out, which the idle timer reads.
function renderBanner(
  store = {
    finishBillsSaves: vi.fn(() => Promise.resolve(true)),
    markNewVersionAvailable: vi.fn(),
  },
) {
  return render(
    <StoreContext.Provider value={store}>
      <VersionBanner />
    </StoreContext.Provider>,
  );
}

const POLL_INTERVAL = 5 * 60 * 1000;

// The banner reads the running build's entry file from the module
// script tag, then polls the served manifest. A manifest naming a
// different entry file means a deploy happened since the page loaded.
function addEntryScript(src) {
  const script = document.createElement("script");
  script.type = "module";
  script.src = src;
  document.head.appendChild(script);
  return script;
}

// The shape of a real build's public/.vite/manifest.json, cut down:
// one entry (index.html), with chunks before and after it whose files
// never match the page's script. Only the entry counts.
function manifestNaming(entryFile) {
  return {
    "_helpers-C-a_4Q2I.js": {
      file: "vite-assets/helpers-C-a_4Q2I.js",
      name: "helpers",
    },
    "index.html": {
      file: entryFile,
      name: "index",
      src: "index.html",
      isEntry: true,
    },
    "src/components/calendar/show.jsx": {
      file: "vite-assets/show-C2edZfga.js",
      name: "show",
      src: "src/components/calendar/show.jsx",
      isDynamicEntry: true,
    },
  };
}

function mockManifest(entryFile) {
  vi.stubGlobal(
    "fetch",
    vi.fn(() =>
      Promise.resolve({
        ok: true,
        json: () => Promise.resolve(manifestNaming(entryFile)),
      }),
    ),
  );
}

describe("VersionBanner", () => {
  let script;

  beforeEach(() => {
    vi.useFakeTimers();
    script = addEntryScript("/vite-assets/index-OLD.js");
  });

  afterEach(() => {
    script.remove();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("renders nothing before the first poll", () => {
    mockManifest("vite-assets/index-NEW.js");
    const { container } = renderBanner();
    expect(container).toBeEmptyDOMElement();
  });

  it("shows the banner when the manifest names a newer entry file", async () => {
    mockManifest("vite-assets/index-NEW.js");
    renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(screen.getByText("A new version is available.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument();
    expect(fetch).toHaveBeenCalledWith("/.vite/manifest.json");
  });

  // The idle timer loads the new code when nobody has used the screen
  // for five minutes (components/app/back_to_today.tsx). Before, the
  // shared screen ran the old code until someone tapped Refresh.
  it("notes the new version in the store, once", async () => {
    mockManifest("vite-assets/index-NEW.js");
    const store = {
      finishBillsSaves: vi.fn(),
      markNewVersionAvailable: vi.fn(),
    };
    renderBanner(store);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3 * POLL_INTERVAL);
    });
    expect(store.markNewVersionAvailable).toHaveBeenCalledTimes(1);
  });

  it("notes nothing while the build is current", async () => {
    mockManifest("vite-assets/index-OLD.js");
    const store = {
      finishBillsSaves: vi.fn(),
      markNewVersionAvailable: vi.fn(),
    };
    renderBanner(store);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3 * POLL_INTERVAL);
    });
    expect(store.markNewVersionAvailable).not.toHaveBeenCalled();
  });

  it("stops polling once it has found a new version", async () => {
    mockManifest("vite-assets/index-NEW.js");
    renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    });
    expect(fetch).toHaveBeenCalledTimes(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3 * POLL_INTERVAL);
    });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("polls every five minutes while the build is current", async () => {
    mockManifest("vite-assets/index-OLD.js");
    renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL - 1);
    });
    expect(fetch).not.toHaveBeenCalled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(fetch).toHaveBeenCalledTimes(1);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL);
    });
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("stays hidden while the manifest matches the running build", async () => {
    mockManifest("vite-assets/index-OLD.js");
    const { container } = renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(container).toBeEmptyDOMElement();
  });

  it("stays hidden when the manifest fetch fails", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.reject(new Error("offline"))),
    );
    const { container } = renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(container).toBeEmptyDOMElement();
  });

  it("never polls when the page has no module script to compare against", async () => {
    script.remove();
    mockManifest("vite-assets/index-NEW.js");
    const { container } = renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(fetch).not.toHaveBeenCalled();
    expect(container).toBeEmptyDOMElement();
  });

  it("stays hidden when the manifest answers with an error status", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve({ ok: false, status: 503 })),
    );
    const { container } = renderBanner();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(container).toBeEmptyDOMElement();
  });

  it("stops polling when it unmounts", async () => {
    mockManifest("vite-assets/index-OLD.js");
    const { unmount } = renderBanner();
    unmount();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3 * POLL_INTERVAL);
    });
    expect(fetch).not.toHaveBeenCalled();
  });

  // A reload ends every request on its way, so Refresh first waits for
  // the bills saves on their way (finishBillsSaves, #150).
  it("Refresh waits for the bills saves, then reloads the page", async () => {
    mockManifest("vite-assets/index-NEW.js");
    let saved;
    const store = {
      finishBillsSaves: vi.fn(
        () =>
          new Promise((resolve) => {
            saved = resolve;
          }),
      ),
      markNewVersionAvailable: vi.fn(),
    };
    renderBanner(store);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

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

  // A save it waited for was not saved, and the message is on screen.
  // A reload would take it away before the person could read it. The
  // next tap goes on.
  it("Refresh does not reload when a save it waited for was not saved", async () => {
    mockManifest("vite-assets/index-NEW.js");
    const store = {
      finishBillsSaves: vi.fn(() => Promise.resolve(false)),
      markNewVersionAvailable: vi.fn(),
    };
    renderBanner(store);
    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    const { location, restore } = fakeLocation();
    try {
      await act(async () => {
        fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
      });
      expect(store.finishBillsSaves).toHaveBeenCalledTimes(1);
      expect(location.reload).not.toHaveBeenCalled();
    } finally {
      restore();
    }
  });
});
