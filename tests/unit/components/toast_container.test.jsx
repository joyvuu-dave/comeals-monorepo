import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import ToastContainer from "../../../app/frontend/src/components/app/toast_container.jsx";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// ToastContainer reads the module-level toastStore singleton, so each
// test starts by emptying it. Toasts are shown the way the app shows
// them: replaceAll, one at a time.
describe("ToastContainer", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    toastStore.clearAll();
  });

  afterEach(() => {
    toastStore.clearAll();
    vi.useRealTimers();
  });

  it("renders nothing when there are no toasts", () => {
    const { container } = render(<ToastContainer />);
    expect(container).toBeEmptyDOMElement();
  });

  it("shows a toast as an alert with its message and type", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("Saved.", "success");
    });

    const toast = screen.getByRole("alert");
    expect(toast).toHaveTextContent("Saved.");
    expect(toast).toHaveClass("toast--success");
  });

  it("the dismiss button removes the toast", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("Saved.", "success");
    });

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(toastStore.toasts).toHaveLength(0);
  });

  // Each type stays up for its own time, and is still up 1 ms before.
  it.each([
    { type: "success", ms: 5000 },
    { type: "info", ms: 5000 },
    { type: "warning", ms: 8000 },
    { type: "error", ms: 15000 },
  ])("a $type toast dismisses itself after $ms ms", ({ type, ms }) => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("Hello.", type);
    });

    act(() => {
      vi.advanceTimersByTime(ms - 1);
    });
    expect(screen.getByRole("alert")).toHaveTextContent("Hello.");

    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  // A replaced toast's timer still runs. When it fires it removes only
  // its own toast (by id), so the toast on screen keeps its full time.
  it("a replaced toast's timer does not remove the toast that took its place", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("It worked.", "success");
    });
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    act(() => {
      toastStore.replaceAll("It failed.", "error");
    });

    // The success toast's timer fires at 5000 ms.
    act(() => {
      vi.advanceTimersByTime(2000);
    });
    expect(screen.getByRole("alert")).toHaveTextContent("It failed.");

    // The error toast has its own 15 seconds, counted from when it came.
    act(() => {
      vi.advanceTimersByTime(15000 - 2000 - 1);
    });
    expect(screen.getByRole("alert")).toHaveTextContent("It failed.");
    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("a toast that replaced a longer one goes on its own time", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("It failed.", "error");
    });
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    act(() => {
      toastStore.replaceAll("It worked.", "success");
    });

    act(() => {
      vi.advanceTimersByTime(5000 - 1);
    });
    expect(screen.getByRole("alert")).toHaveTextContent("It worked.");
    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  // The same message again is a new toast, with a new timer.
  it("the same message shown again stays up for its full time", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("Saved.", "success");
    });
    act(() => {
      vi.advanceTimersByTime(4000);
    });
    act(() => {
      toastStore.replaceAll("Saved.", "success");
    });

    act(() => {
      vi.advanceTimersByTime(5000 - 1);
    });
    expect(screen.getByRole("alert")).toHaveTextContent("Saved.");
    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  // No caller passes any other type today: handleAxiosError turns the
  // server's type into "warning" or "error", and every other caller
  // passes a fixed word. The component still falls back to 5 seconds
  // for a type it does not know, and this test covers that fallback.
  it("a toast of an unknown type dismisses itself after 5 seconds", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.replaceAll("Hm.", "notice");
    });

    act(() => {
      vi.advanceTimersByTime(4999);
    });
    expect(screen.getByRole("alert")).toBeInTheDocument();

    act(() => {
      vi.advanceTimersByTime(1);
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});
