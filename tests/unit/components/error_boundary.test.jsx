import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen } from "@testing-library/react";

vi.mock("../../../app/frontend/src/helpers/bugsnag", () => ({
  notifyError: vi.fn(),
}));

import ErrorBoundary from "../../../app/frontend/src/components/app/error_boundary.jsx";
import { notifyError } from "../../../app/frontend/src/helpers/bugsnag";

function Bomb() {
  throw new Error("boom");
}

describe("ErrorBoundary", () => {
  // React and the boundary itself both log the caught error. Silence
  // that inside these tests so the output stays readable.
  beforeEach(() => {
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
    // React's dev build can replay a caught render error, so the count
    // may be more than one. What matters is what got reported.
    expect(notifyError).toHaveBeenCalled();
    const [error, meta] = notifyError.mock.calls[0];
    expect(error.message).toBe("boom");
    expect(meta.componentStack).toContain("Bomb");
  });
});
