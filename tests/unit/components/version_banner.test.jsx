import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act } from "@testing-library/react";
import VersionBanner from "../../../app/frontend/src/components/app/version_banner.jsx";

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

function mockManifest(entryFile) {
  vi.stubGlobal(
    "fetch",
    vi.fn(() =>
      Promise.resolve({
        ok: true,
        json: () =>
          Promise.resolve({
            "index.html": { isEntry: true, file: entryFile },
          }),
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
    const { container } = render(<VersionBanner />);
    expect(container).toBeEmptyDOMElement();
  });

  it("shows the banner when the manifest names a newer entry file", async () => {
    mockManifest("vite-assets/index-NEW.js");
    render(<VersionBanner />);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(screen.getByText("A new version is available.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument();
  });

  it("stays hidden while the manifest matches the running build", async () => {
    mockManifest("vite-assets/index-OLD.js");
    const { container } = render(<VersionBanner />);

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
    const { container } = render(<VersionBanner />);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL + 1000);
    });

    expect(container).toBeEmptyDOMElement();
  });
});
