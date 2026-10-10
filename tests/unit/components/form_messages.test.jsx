import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";

import useFormMessages from "../../../app/frontend/src/helpers/use_form_messages";
import FormMessages from "../../../app/frontend/src/components/modal_form/form_messages";
import toastStore from "../../../app/frontend/src/stores/toast_store";

// A calendar form's own messages show inside the form, under its title,
// and not in the stack of messages (#137). The stack is drawn under an
// open dialog, so a message there would be hidden while the form is
// open, which is when the person needs it.
describe("a form's own messages", () => {
  // The form's showError, so a test can make a request fail.
  let showError;

  function Form() {
    const messages = useFormMessages();
    showError = messages.showError;
    return (
      <div>
        <h2>New Event</h2>
        <FormMessages messages={messages.messages} close={messages.close} />
      </div>
    );
  }

  // The words of every message in the form, top to bottom.
  function wordsInForm() {
    return Array.from(document.querySelectorAll(".form-message__text")).map(
      (node) => node.textContent,
    );
  }

  function fail(error) {
    act(() => {
      showError(error);
    });
  }

  const REFUSED = { response: { status: 400, data: { message: "No." } } };

  beforeEach(() => {
    toastStore.clearAll();
    vi.spyOn(Element.prototype, "scrollIntoView");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("draws nothing while the form has no message", () => {
    render(<Form />);

    expect(document.querySelector(".form-messages")).toBeNull();
    expect(Element.prototype.scrollIntoView).not.toHaveBeenCalled();
  });

  // A screen reader says it at once. The form is inside the dialog,
  // which is the part of the page a screen reader reads while the
  // dialog is open.
  it("shows a failed request inside the form as an alert, and not in the stack", () => {
    render(<Form />);

    fail(REFUSED);

    const alert = screen.getByRole("alert");
    expect(alert).toHaveTextContent("No.");
    expect(alert).toHaveAttribute("aria-live", "assertive");
    expect(alert).toHaveClass("form-message", "form-message--error");
    expect(toastStore.toasts).toHaveLength(0);
  });

  // The words and the kind of message are the stack's own
  // (handle_axios_error.js).
  it.each([
    ["a response with a message", REFUSED, "No.", "error"],
    [
      "an answer marked as a warning",
      { response: { data: { message: "Careful.", type: "warning" } } },
      "Careful.",
      "error",
    ],
    [
      "a response with no message",
      { response: { status: 500, data: "<html>500</html>" } },
      "The server had a problem. Please try again.",
      "error",
    ],
    [
      "a request that got no response",
      { request: {} },
      "Error: no response received from server.",
      "error",
    ],
    [
      "a request that never went out",
      new Error("boom"),
      "Error: could not submit form.",
      "error",
    ],
  ])("says what the stack would say for %s", (_label, error, words, type) => {
    render(<Form />);

    fail(error);

    expect(wordsInForm()).toEqual([words]);
    expect(document.querySelector(".form-message")).toHaveClass(
      `form-message--${type}`,
    );
  });

  it("puts a newer message on top", () => {
    render(<Form />);

    fail(REFUSED);
    fail({ request: {} });

    expect(wordsInForm()).toEqual([
      "Error: no response received from server.",
      "No.",
    ]);
  });

  // A person who tries again and gets the same error can tell the
  // second try failed too: the message is drawn as a new alert, so a
  // screen reader says it again.
  it("draws the same words again as a new alert on top, not as a second copy", () => {
    render(<Form />);
    fail(REFUSED);
    fail({ request: {} });
    const first = screen.getByText("No.").closest(".form-message");

    fail(REFUSED);

    expect(wordsInForm()).toEqual([
      "No.",
      "Error: no response received from server.",
    ]);
    expect(screen.getByText("No.").closest(".form-message")).not.toBe(first);
  });

  it("the close button takes away only its own message", () => {
    render(<Form />);
    fail(REFUSED);
    fail({ request: {} });

    fireEvent.click(screen.getAllByRole("button", { name: "Dismiss" })[1]);

    expect(wordsInForm()).toEqual(["Error: no response received from server."]);
  });

  // An error stays until a person closes it, the same as in the stack.
  it("keeps an error however long the form is open", () => {
    vi.useFakeTimers();
    try {
      render(<Form />);
      fail(REFUSED);

      act(() => {
        vi.advanceTimersByTime(60000);
      });

      expect(wordsInForm()).toEqual(["No."]);
    } finally {
      vi.useRealTimers();
    }
  });

  // On a phone the form is taller than the screen, and the person
  // tapped Create at the bottom of it. The message is at the top, so
  // the form scrolls to show it.
  it("scrolls each new message into view", () => {
    render(<Form />);

    fail(REFUSED);
    expect(Element.prototype.scrollIntoView).toHaveBeenCalledTimes(1);
    expect(Element.prototype.scrollIntoView).toHaveBeenLastCalledWith({
      block: "nearest",
    });
    expect(Element.prototype.scrollIntoView.mock.contexts[0]).toBe(
      document.querySelector(".form-messages"),
    );

    fail(REFUSED);
    expect(Element.prototype.scrollIntoView).toHaveBeenCalledTimes(2);
  });

  it("does not scroll when a message is closed", () => {
    render(<Form />);
    fail(REFUSED);
    fail({ request: {} });

    fireEvent.click(screen.getAllByRole("button", { name: "Dismiss" })[1]);

    expect(Element.prototype.scrollIntoView).toHaveBeenCalledTimes(2);
  });

  // The messages are the form's, so they go with it.
  it("takes the messages away with the form", () => {
    const { unmount } = render(<Form />);
    fail(REFUSED);

    unmount();

    expect(document.querySelector(".form-message")).toBeNull();
    expect(toastStore.toasts).toHaveLength(0);
  });

  it("keeps showError the same function from one render to the next", () => {
    const { rerender } = render(<Form />);
    const first = showError;

    rerender(<Form />);

    expect(showError).toBe(first);
  });
});
