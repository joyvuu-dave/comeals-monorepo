import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import ToastContainer from "../../../app/frontend/src/components/app/toast_container.jsx";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// ToastContainer reads the module-level toastStore singleton, so each
// test starts by emptying it.
function clearToasts() {
  toastStore.toasts
    .slice()
    .forEach((toast) => toastStore.removeToast(toast.id));
}

describe("ToastContainer", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    clearToasts();
  });

  afterEach(() => {
    clearToasts();
    vi.useRealTimers();
  });

  it("renders nothing when there are no toasts", () => {
    const { container } = render(<ToastContainer />);
    expect(container).toBeEmptyDOMElement();
  });

  it("shows a toast as an alert with its message and type", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.addToast("Saved.", "success");
    });

    const toast = screen.getByRole("alert");
    expect(toast).toHaveTextContent("Saved.");
    expect(toast).toHaveClass("toast--success");
  });

  it("the dismiss button removes the toast", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.addToast("Saved.", "success");
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
      toastStore.addToast("Hello.", type);
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

  it("an error toast stays longer than a success toast", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.addToast("It worked.", "success");
      toastStore.addToast("It failed.", "error");
    });

    act(() => {
      vi.advanceTimersByTime(5000);
    });
    expect(screen.getByRole("alert")).toHaveTextContent("It failed.");

    act(() => {
      vi.advanceTimersByTime(10000);
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
      toastStore.addToast("Hm.", "notice");
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
