import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

vi.mock("../../../app/frontend/src/helpers/bugsnag", () => ({
  notifyError: vi.fn(),
}));

import ErrorBoundary from "../../../app/frontend/src/components/app/error_boundary.jsx";
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

  it("Refresh reloads the page", () => {
    render(
      <ErrorBoundary>
        <Bomb />
      </ErrorBoundary>,
    );
    const { location, restore } = fakeLocation();
    try {
      fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
      expect(location.reload).toHaveBeenCalledTimes(1);
    } finally {
      restore();
    }
  });
});
