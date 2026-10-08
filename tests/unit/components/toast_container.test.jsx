import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  act,
  cleanup,
} from "@testing-library/react";
import Modal from "react-modal";
import ToastContainer from "../../../app/frontend/src/components/app/toast_container.jsx";
import toastStore from "../../../app/frontend/src/stores/toast_store";
import FakeResizeObserver, {
  makeTall,
} from "../helpers/fake_resize_observer.js";

// ToastContainer draws the stack the toast store holds (#137). The
// store's rules (how many, which go first, timers) are tested in
// tests/unit/stores/toast_store.test.js; these tests check what the
// screen shows and what a person can do with it.
describe("ToastContainer", () => {
  const NOT_SAVED =
    "The cooks and costs you entered for Thu, Jun 15th were not saved. Please open that meal and enter them again.";

  beforeEach(() => {
    vi.useFakeTimers();
    toastStore.clearAll();
    FakeResizeObserver.made = [];
    vi.stubGlobal("ResizeObserver", FakeResizeObserver);
  });

  afterEach(() => {
    toastStore.clearAll();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  // The stack sits at the bottom of the screen, over the end of the
  // page. While it shows, the page gets room at its bottom as tall as
  // the stack (toast.css), so a person can scroll the last rows of a
  // page, such as the last sign-up, above it and tap them.
  describe("room at the bottom of the page", () => {
    function room() {
      return document.documentElement.style.getPropertyValue(
        "--message-stack-room",
      );
    }

    function stackIsTall(height) {
      makeTall(document.querySelector(".toast-container"), height);
    }

    it("is none while no message shows", () => {
      render(<ToastContainer />);

      expect(room()).toBe("");
      expect(FakeResizeObserver.made).toHaveLength(0);
    });

    it("is as tall as the stack and its margins while messages show, and follows the stack's height", () => {
      render(<ToastContainer />);
      act(() => {
        toastStore.show("It failed.", "error");
      });
      const [observer] = FakeResizeObserver.made;
      expect(observer.watching).toEqual([
        document.querySelector(".toast-container"),
      ]);

      stackIsTall(120);
      observer.resized();
      expect(room()).toBe("calc(120px + 2 * var(--space-4))");

      stackIsTall(200);
      observer.resized();
      expect(room()).toBe("calc(200px + 2 * var(--space-4))");
    });

    it("goes when the last message goes, and stops watching the stack", () => {
      render(<ToastContainer />);
      act(() => {
        toastStore.show("It failed.", "error");
      });
      const [observer] = FakeResizeObserver.made;

      act(() => {
        toastStore.clearAll();
      });

      expect(room()).toBe("");
      expect(observer.watching).toEqual([]);
    });

    it("watches the stack once while messages come and go", () => {
      render(<ToastContainer />);
      act(() => {
        toastStore.show("One", "error");
        toastStore.show("Two", "error");
      });
      act(() => {
        toastStore.remove(toastStore.toasts[0].id);
      });

      expect(FakeResizeObserver.made).toHaveLength(1);
    });
  });

  // The words of every message on screen, top to bottom.
  function wordsOnScreen() {
    return Array.from(document.querySelectorAll(".toast__message")).map(
      (node) => node.textContent,
    );
  }

  // The one place a screen reader hears a message that is not an
  // error (see ToastContainer). Always on the page, even with no
  // messages, so a screen reader is already watching it when words go
  // into it.
  function politeRegion() {
    return screen.getByRole("status");
  }

  it("draws only the empty polite region when there are no messages", () => {
    render(<ToastContainer />);

    expect(politeRegion()).toBeEmptyDOMElement();
    expect(politeRegion()).toHaveAttribute("aria-live", "polite");
    expect(politeRegion()).toHaveClass("visually-hidden");
    expect(document.querySelector(".toast-container")).toBeNull();
  });

  // A screen reader says an error at once.
  it("shows an error as an alert, and not in the polite region", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("It failed.", "error");
    });

    const toast = screen.getByRole("alert");
    expect(toast).toHaveTextContent("It failed.");
    expect(toast).toHaveClass("toast--error");
    expect(toast).toHaveAttribute("aria-live", "assertive");
    expect(politeRegion()).toBeEmptyDOMElement();
  });

  // A screen reader may say nothing about a live region that comes onto
  // the page with its words already in it, so the words go into the
  // region that was there all along. The message on screen has no role
  // of its own, or a screen reader that does say it would say it twice.
  it.each(["success", "info", "warning"])(
    "says a %s message through the polite region",
    (type) => {
      render(<ToastContainer />);
      act(() => {
        toastStore.show("Hello.", type);
      });

      expect(politeRegion()).toHaveTextContent(/^Hello\.$/);
      const toast = document.querySelector(`.toast--${type}`);
      expect(toast).toHaveTextContent("Hello.");
      expect(toast).not.toHaveAttribute("role");
      expect(toast).not.toHaveAttribute("aria-live");
      expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    },
  );

  it("the polite region holds only the newest message that is not an error", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("Older.", "info");
      toastStore.show("Newer.", "warning");
      toastStore.show("It failed.", "error");
    });

    expect(politeRegion()).toHaveTextContent(/^Newer\.$/);
  });

  // An older message still on screen was said when it came.
  it("the polite region empties when its message goes", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("Older.", "warning");
      toastStore.show("Newer.", "info");
    });

    act(() => {
      vi.advanceTimersByTime(5000);
    });

    expect(wordsOnScreen()).toEqual(["Older."]);
    expect(politeRegion()).toBeEmptyDOMElement();
  });

  // The same words again are a new message: the person sees it come in
  // again, and a screen reader says it again. A new element in the
  // region is what a screen reader says.
  it("the same words again put a new element in the polite region", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("Cooks saved.", "info");
    });
    const first = politeRegion().firstChild;

    act(() => {
      toastStore.show("Cooks saved.", "info");
    });

    expect(politeRegion()).toHaveTextContent(/^Cooks saved\.$/);
    expect(politeRegion().firstChild).not.toBe(first);
  });

  // A person taps a sign-up again and gets the same error. A new alert
  // element is what makes the message slide in again and a screen
  // reader say it again, so the person can tell the second try failed.
  it.each([
    ["on top already", []],
    ["under another message", ["Resident not found."]],
  ])(
    "the same error again is drawn as a new alert, when it is %s",
    (_label, others) => {
      const CONFLICT =
        "Someone else was changing this meal at the same time. Nothing was saved. Try again.";
      render(<ToastContainer />);
      act(() => {
        toastStore.show(CONFLICT, "error");
        others.forEach((words) => toastStore.show(words, "error"));
      });
      const first = screen.getByText(CONFLICT).closest(".toast");

      act(() => {
        toastStore.show(CONFLICT, "error");
      });

      expect(screen.getAllByRole("alert")[0]).toHaveTextContent(CONFLICT);
      expect(screen.getAllByText(CONFLICT)).toHaveLength(1);
      expect(screen.getByText(CONFLICT).closest(".toast")).not.toBe(first);
    },
  );

  // A calendar form or a confirm dialog is a react-modal, and while one
  // is open react-modal hides #root from screen readers with
  // aria-hidden. The messages are drawn outside #root, so aria-hidden
  // does not hide an error that comes while a dialog is open. On screen
  // it is under the dialog (toast.css), and shows when the dialog
  // closes. (Whether VoiceOver in Safari says it, with the dialog marked
  // aria-modal, has not been tried; see toast_container.jsx.)
  it("a message that comes while a dialog is open is outside the part react-modal hides", () => {
    const root = document.createElement("div");
    root.id = "root";
    document.body.appendChild(root);
    Modal.setAppElement(root);
    try {
      render(
        <>
          <ToastContainer />
          <Modal isOpen={true} contentLabel="Event Modal">
            <p>The form</p>
          </Modal>
        </>,
        { container: root },
      );
      act(() => {
        toastStore.show(NOT_SAVED, "error");
        toastStore.show("Cooks saved.", "info");
      });

      expect(root).toHaveAttribute("aria-hidden", "true");
      expect(screen.getByRole("alert")).toHaveTextContent(NOT_SAVED);
      expect(screen.getByRole("status")).toHaveTextContent("Cooks saved.");
    } finally {
      cleanup();
      root.remove();
    }
  });

  // The stack is under an open dialog, so a message with a timer would
  // close unseen. The stack tells the store while a dialog is open, and
  // the store runs no timers then (toast_store.ts). Every dialog in the
  // app is a react-modal, and react-modal puts a class on <body> while
  // any of its dialogs is open.
  describe("while a dialog is open", () => {
    function TwoDialogs({ first, second }) {
      return (
        <>
          <Modal isOpen={first} contentLabel="Event Modal" ariaHideApp={false}>
            <p>The form</p>
          </Modal>
          <Modal isOpen={second} contentLabel="Confirm" ariaHideApp={false}>
            <p>Are you sure?</p>
          </Modal>
        </>
      );
    }

    // The page watches <body> with a MutationObserver, and its callback
    // runs after the change, as a microtask.
    async function bodyChanged() {
      await act(async () => {});
    }

    it("a message does not close on its timer until every dialog closes", async () => {
      render(<ToastContainer />);
      const { rerender } = render(<TwoDialogs first={true} second={false} />);
      await bodyChanged();
      act(() => {
        toastStore.show("Cooks saved.", "info");
      });
      rerender(<TwoDialogs first={true} second={true} />);
      await bodyChanged();
      rerender(<TwoDialogs first={false} second={true} />);
      await bodyChanged();

      act(() => {
        vi.advanceTimersByTime(60000);
      });
      expect(wordsOnScreen()).toEqual(["Cooks saved."]);

      rerender(<TwoDialogs first={false} second={false} />);
      await bodyChanged();
      act(() => {
        vi.advanceTimersByTime(4999);
      });
      expect(wordsOnScreen()).toEqual(["Cooks saved."]);
      act(() => {
        vi.advanceTimersByTime(1);
      });
      expect(wordsOnScreen()).toEqual([]);
    });

    it("pauses a message that came before the dialog opened", async () => {
      render(<ToastContainer />);
      act(() => {
        toastStore.show("Cooks saved.", "info");
      });
      const { rerender } = render(<TwoDialogs first={false} second={false} />);
      act(() => {
        vi.advanceTimersByTime(4000);
      });

      rerender(<TwoDialogs first={true} second={false} />);
      await bodyChanged();
      act(() => {
        vi.advanceTimersByTime(60000);
      });

      expect(wordsOnScreen()).toEqual(["Cooks saved."]);
    });

    it("pauses when a dialog is already open as the stack comes onto the page", () => {
      render(<TwoDialogs first={true} second={false} />);
      render(<ToastContainer />);
      act(() => {
        toastStore.show("Cooks saved.", "info");
        vi.advanceTimersByTime(60000);
      });

      expect(wordsOnScreen()).toEqual(["Cooks saved."]);
    });

    // Only the tests take the stack off the page. Once nothing watches
    // for dialogs, nothing could say one closed, so timers run again.
    it("lets timers run again when the stack goes", async () => {
      const stack = render(<ToastContainer />);
      render(<TwoDialogs first={true} second={false} />);
      await bodyChanged();
      act(() => {
        toastStore.show("Cooks saved.", "info");
      });

      stack.unmount();
      vi.advanceTimersByTime(5000);

      expect(toastStore.toasts).toEqual([]);
    });
  });

  it("shows up to three messages, newest on top", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("One", "error");
      toastStore.show("Two", "info");
      toastStore.show("Three", "error");
    });

    expect(wordsOnScreen()).toEqual(["Three", "Two", "One"]);
    expect(screen.queryByRole("button", { name: /more message/ })).toBeNull();
  });

  it("the close button removes only its own message", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("One", "error");
      toastStore.show("Two", "error");
    });

    fireEvent.click(screen.getAllByRole("button", { name: "Dismiss" })[1]);

    expect(wordsOnScreen()).toEqual(["Two"]);
    expect(toastStore.toasts.map((t) => t.message)).toEqual(["Two"]);
  });

  it("an error stays on screen while a newer message comes and goes on its timer", () => {
    render(<ToastContainer />);
    act(() => {
      toastStore.show("It failed.", "error");
      toastStore.show("Cooks saved.", "info");
    });
    expect(wordsOnScreen()).toEqual(["Cooks saved.", "It failed."]);

    act(() => {
      vi.advanceTimersByTime(60000);
    });

    expect(wordsOnScreen()).toEqual(["It failed."]);
  });

  describe("more than three messages", () => {
    function showErrors(names) {
      act(() => {
        names.forEach((name) => toastStore.show(`Error ${name}`, "error"));
      });
    }

    it("shows the newest three and a line that says how many more there are", () => {
      render(<ToastContainer />);
      showErrors(["A", "B", "C", "D", "E"]);

      expect(wordsOnScreen()).toEqual(["Error E", "Error D", "Error C"]);
      expect(
        screen.getByRole("button", { name: "Show 2 more messages" }),
      ).toBeInTheDocument();
    });

    it("says message, not messages, for one more", () => {
      render(<ToastContainer />);
      showErrors(["A", "B", "C", "D"]);

      expect(
        screen.getByRole("button", { name: "Show 1 more message" }),
      ).toBeInTheDocument();
    });

    it("tapping the line shows every message, and the line goes", () => {
      render(<ToastContainer />);
      showErrors(["A", "B", "C", "D", "E"]);

      fireEvent.click(
        screen.getByRole("button", { name: "Show 2 more messages" }),
      );

      expect(wordsOnScreen()).toEqual([
        "Error E",
        "Error D",
        "Error C",
        "Error B",
        "Error A",
      ]);
      expect(screen.queryByRole("button", { name: /more message/ })).toBeNull();
    });

    it("closing an error when every message shows leaves the rest showing", () => {
      render(<ToastContainer />);
      showErrors(["A", "B", "C", "D", "E"]);
      fireEvent.click(
        screen.getByRole("button", { name: "Show 2 more messages" }),
      );

      fireEvent.click(screen.getAllByRole("button", { name: "Dismiss" })[0]);

      expect(wordsOnScreen()).toEqual([
        "Error D",
        "Error C",
        "Error B",
        "Error A",
      ]);
    });

    it("an error that was hidden shows when one on screen is closed", () => {
      render(<ToastContainer />);
      showErrors(["A", "B", "C", "D"]);

      fireEvent.click(screen.getAllByRole("button", { name: "Dismiss" })[0]);

      expect(wordsOnScreen()).toEqual(["Error C", "Error B", "Error A"]);
      expect(screen.queryByRole("button", { name: /more message/ })).toBeNull();
    });
  });
});
