import { describe, it, expect, beforeEach, vi } from "vitest";
import handleAxiosError from "../../../app/frontend/src/helpers/handle_axios_error.js";
import toastStore from "../../../app/frontend/src/stores/toast_store";

// What every failed request turns into: a message the person sees, on
// top of the ones on screen, or a console line when the caller asked for
// silence.
describe("handleAxiosError", () => {
  beforeEach(() => {
    toastStore.clearAll();
  });

  // The messages on screen, newest first, as [message, type].
  function toastsOnScreen() {
    return toastStore.toasts.map((t) => [t.message, t.type]);
  }

  describe("a response with a message", () => {
    it("shows it as an error", () => {
      handleAxiosError({ response: { data: { message: "No." } } });

      expect(toastsOnScreen()).toEqual([["No.", "error"]]);
    });

    // An answer with an error status is an error, whatever its body
    // says. The one answer the server marks "warning", the bills write's
    // third-cook advice, is a 200, so it never comes here: the bills
    // save reads it on success (data_store_bills.ts).
    it("shows an answer marked as a warning as an error too", () => {
      handleAxiosError({
        response: { data: { message: "Careful.", type: "warning" } },
      });

      expect(toastsOnScreen()).toEqual([["Careful.", "error"]]);
    });

    it("logs instead of showing when silent", () => {
      handleAxiosError(
        { response: { data: { message: "No." } } },
        { silent: true },
      );

      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith("No.");
    });
  });

  // Only the errors ApiController rescues carry a message. Any other
  // exception gets Rails' own page (public/500.html), and a Heroku
  // router error gets Heroku's page, so the person who tapped would see
  // nothing unless the helper says something itself (#108).
  describe("a response with no message", () => {
    it.each([
      [
        "Rails' public 500 page",
        500,
        "<!doctype html><html><head><title>We're sorry, but something went wrong (500)</title></head></html>",
      ],
      [
        "a Heroku router error page",
        503,
        "<!DOCTYPE html><html><head><title>Application Error</title></head></html>",
      ],
      [
        "Rails' JSON error body",
        500,
        { status: 500, error: "Internal Server Error" },
      ],
      ["an empty body", 502, ""],
      ["no body at all", 502, undefined],
    ])("shows a plain error for %s, and logs it", (_label, status, data) => {
      const error = { response: { status, data } };

      handleAxiosError(error);

      expect(toastsOnScreen()).toEqual([
        ["The server had a problem. Please try again.", "error"],
      ]);
      expect(console.error).toHaveBeenCalledWith(
        "Bad response from server",
        error,
      );
    });

    it("only logs when silent", () => {
      const error = { response: { status: 500, data: "<html>500</html>" } };

      handleAxiosError(error, { silent: true });

      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Bad response from server",
        error,
      );
    });
  });

  describe("a request that got no response", () => {
    it("says so", () => {
      handleAxiosError({ request: {} });

      expect(toastsOnScreen()).toEqual([
        ["Error: no response received from server.", "error"],
      ]);
    });

    it("logs when silent", () => {
      handleAxiosError({ request: {} }, { silent: true });

      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Error: no response received from server.",
      );
    });
  });

  describe("a request that never went out", () => {
    it("says the form could not be submitted", () => {
      handleAxiosError(new Error("boom"));

      expect(toastsOnScreen()).toEqual([
        ["Error: could not submit form.", "error"],
      ]);
    });

    it("logs when silent", () => {
      handleAxiosError(new Error("boom"), { silent: true });

      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Error: could not submit form.",
      );
    });
  });

  // A new failure does not take the place of a message on screen
  // (#137).
  it("shows a new message on top of the one on screen", () => {
    handleAxiosError({ request: {} });
    handleAxiosError({ response: { data: { message: "No." } } });

    expect(toastsOnScreen()).toEqual([
      ["No.", "error"],
      ["Error: no response received from server.", "error"],
    ]);
  });

  it("hands back the id of the message it showed", () => {
    const id = handleAxiosError({ request: {} });

    expect(toastStore.toasts.map((t) => t.id)).toEqual([id]);
  });

  it("hands back null when silent", () => {
    expect(handleAxiosError({ request: {} }, { silent: true })).toBeNull();
  });

  // A calendar form shows its own failures inside itself
  // (use_form_messages.ts), with the same words and kind, and the stack
  // gets nothing.
  it.each([
    [
      "a response with a message",
      { response: { data: { message: "No." } } },
      "No.",
      "error",
    ],
    [
      "an answer marked as a warning",
      { response: { data: { message: "Careful.", type: "warning" } } },
      "Careful.",
      "error",
    ],
    [
      "a response with no message",
      { response: { status: 500, data: "" } },
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
  ])(
    "shows %s where the caller says, and hands back what it hands back",
    (_label, error, words, type) => {
      const show = vi.fn(() => "shown");

      expect(handleAxiosError(error, { show })).toBe("shown");

      expect(show.mock.calls).toEqual([[words, type]]);
      expect(toastStore.toasts).toHaveLength(0);
    },
  );

  it("shows in the stack when the caller names no other place", () => {
    handleAxiosError({ request: {} }, {});

    expect(toastsOnScreen()).toEqual([
      ["Error: no response received from server.", "error"],
    ]);
  });
});
