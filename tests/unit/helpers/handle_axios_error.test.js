import { describe, it, expect, beforeEach } from "vitest";
import handleAxiosError from "../../../app/frontend/src/helpers/handle_axios_error.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// What every failed request turns into: a toast the person sees, or a
// console line when the caller asked for silence. It returns the id of
// the toast it showed, so a caller can tell later whether that toast is
// still on screen, or null when it showed none.
describe("handleAxiosError", () => {
  beforeEach(() => {
    toastStore.clearAll();
  });

  // The one toast on screen, as [id, message, type].
  function toastsOnScreen() {
    return toastStore.toasts.map((t) => [t.id, t.message, t.type]);
  }

  describe("a response with a message", () => {
    it("shows it as an error toast, and returns the toast's id", () => {
      const id = handleAxiosError({ response: { data: { message: "No." } } });

      expect(toastsOnScreen()).toEqual([[id, "No.", "error"]]);
      expect(id).toEqual(expect.any(Number));
    });

    it("shows a warning as a warning toast, and returns the toast's id", () => {
      const id = handleAxiosError({
        response: { data: { message: "Careful.", type: "warning" } },
      });

      expect(toastsOnScreen()).toEqual([[id, "Careful.", "warning"]]);
    });

    it("logs instead of toasting when silent, and returns null", () => {
      const id = handleAxiosError(
        { response: { data: { message: "No." } } },
        { silent: true },
      );

      expect(id).toBeNull();
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
    ])(
      "shows a plain error toast for %s, logs it, and returns the toast's id",
      (_label, status, data) => {
        const error = { response: { status, data } };

        const id = handleAxiosError(error);

        expect(toastsOnScreen()).toEqual([
          [id, "The server had a problem. Please try again.", "error"],
        ]);
        expect(console.error).toHaveBeenCalledWith(
          "Bad response from server",
          error,
        );
      },
    );

    it("only logs when silent, and returns null", () => {
      const error = { response: { status: 500, data: "<html>500</html>" } };

      expect(handleAxiosError(error, { silent: true })).toBeNull();
      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Bad response from server",
        error,
      );
    });
  });

  describe("a request that got no response", () => {
    it("says so in a toast, and returns the toast's id", () => {
      const id = handleAxiosError({ request: {} });

      expect(toastsOnScreen()).toEqual([
        [id, "Error: no response received from server.", "error"],
      ]);
    });

    it("logs when silent, and returns null", () => {
      expect(handleAxiosError({ request: {} }, { silent: true })).toBeNull();
      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Error: no response received from server.",
      );
    });
  });

  describe("a request that never went out", () => {
    it("says the form could not be submitted, and returns the toast's id", () => {
      const id = handleAxiosError(new Error("boom"));

      expect(toastsOnScreen()).toEqual([
        [id, "Error: could not submit form.", "error"],
      ]);
    });

    it("logs when silent, and returns null", () => {
      expect(handleAxiosError(new Error("boom"), { silent: true })).toBeNull();
      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Error: could not submit form.",
      );
    });
  });

  // Toast ids are never used twice, so the id of a toast that is gone
  // matches no toast on screen.
  it("returns a new id for each toast", () => {
    const first = handleAxiosError({ request: {} });
    const second = handleAxiosError({ request: {} });

    expect(second).not.toBe(first);
    expect(toastsOnScreen()).toEqual([
      [second, "Error: no response received from server.", "error"],
    ]);
  });
});
