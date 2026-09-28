import { describe, it, expect, beforeEach } from "vitest";
import handleAxiosError from "../../../app/frontend/src/helpers/handle_axios_error.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

// What every failed request turns into: a toast the person sees, or a
// console line when the caller asked for silence, and the toast type as
// the return value so a caller can tell a warning from an error.
describe("handleAxiosError", () => {
  beforeEach(() => {
    toastStore.clearAll();
  });

  describe("a response with a message", () => {
    it("shows it as an error toast", () => {
      const type = handleAxiosError({ response: { data: { message: "No." } } });

      expect(type).toBe("error");
      expect(toastStore.toasts.map((t) => [t.message, t.type])).toEqual([
        ["No.", "error"],
      ]);
    });

    it("shows a warning as a warning toast", () => {
      const type = handleAxiosError({
        response: { data: { message: "Careful.", type: "warning" } },
      });

      expect(type).toBe("warning");
      expect(toastStore.toasts[0].type).toBe("warning");
    });

    it("logs instead of toasting when silent", () => {
      const type = handleAxiosError(
        { response: { data: { message: "No." } } },
        { silent: true },
      );

      expect(type).toBe("error");
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
      "shows a plain error toast for %s, and logs it",
      (_label, status, data) => {
        const error = { response: { status, data } };

        expect(handleAxiosError(error)).toBe("error");
        expect(toastStore.toasts.map((t) => [t.message, t.type])).toEqual([
          ["The server had a problem. Please try again.", "error"],
        ]);
        expect(console.error).toHaveBeenCalledWith(
          "Bad response from server",
          error,
        );
      },
    );

    it("only logs when silent", () => {
      const error = { response: { status: 500, data: "<html>500</html>" } };

      expect(handleAxiosError(error, { silent: true })).toBe("error");
      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Bad response from server",
        error,
      );
    });
  });

  describe("a request that got no response", () => {
    it("says so in a toast", () => {
      expect(handleAxiosError({ request: {} })).toBe("error");
      expect(toastStore.toasts[0].message).toBe(
        "Error: no response received from server.",
      );
    });

    it("logs when silent", () => {
      expect(handleAxiosError({ request: {} }, { silent: true })).toBe("error");
      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Error: no response received from server.",
      );
    });
  });

  describe("a request that never went out", () => {
    it("says the form could not be submitted", () => {
      expect(handleAxiosError(new Error("boom"))).toBe("error");
      expect(toastStore.toasts[0].message).toBe(
        "Error: could not submit form.",
      );
    });

    it("logs when silent", () => {
      expect(handleAxiosError(new Error("boom"), { silent: true })).toBe(
        "error",
      );
      expect(toastStore.toasts).toHaveLength(0);
      expect(console.error).toHaveBeenCalledWith(
        "Error: could not submit form.",
      );
    });
  });
});
