// What a person sees when a request fails. The server's own answers carry
// a sentence in `message`, and that sentence is shown. An answer with no
// sentence is a page the app did not write: during a deploy, Heroku
// answers 503 with its maintenance page (HTML), and a page that showed
// nothing then left a person looking at a sign-up box that flipped back
// with no word.
import { afterEach, describe, expect, it, vi } from "vitest";

import handleAxiosError from "../../../app/frontend/src/helpers/handle_axios_error.js";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";

function shown() {
  return toastStore.toasts.map(function (t) {
    return [t.message, t.type];
  });
}

afterEach(function () {
  toastStore.toasts.splice(0);
  vi.restoreAllMocks();
});

describe("handleAxiosError", () => {
  it("shows the server's sentence", () => {
    const type = handleAxiosError({
      response: { status: 400, data: { message: "That dinner is full." } },
    });

    expect(type).toBe("error");
    expect(shown()).toEqual([["That dinner is full.", "error"]]);
  });

  it("shows a warning sentence as a warning", () => {
    handleAxiosError({
      response: {
        status: 409,
        data: { message: "Try again.", type: "warning" },
      },
    });

    expect(shown()).toEqual([["Try again.", "warning"]]);
  });

  it("says Comeals is being updated when Heroku answers with its maintenance page", () => {
    vi.spyOn(console, "error").mockImplementation(function () {});
    const type = handleAxiosError({
      response: {
        status: 503,
        data: "<html><head><title>Offline for maintenance | Heroku</title></head></html>",
      },
    });

    expect(type).toBe("warning");
    expect(shown()).toEqual([
      ["Comeals is being updated. Please try again in a minute.", "warning"],
    ]);
  });

  it("says Comeals could not do it when an answer has no sentence", () => {
    vi.spyOn(console, "error").mockImplementation(function () {});
    const type = handleAxiosError({
      response: { status: 503, data: "<html>Application error</html>" },
    });

    expect(type).toBe("error");
    expect(shown()).toEqual([
      [
        "Comeals could not do that just now. Please try again in a minute.",
        "error",
      ],
    ]);
  });

  it("shows nothing for an answer with no sentence when asked to stay silent", () => {
    vi.spyOn(console, "error").mockImplementation(function () {});
    handleAxiosError({ response: { status: 503, data: "" } }, { silent: true });

    expect(shown()).toEqual([]);
  });

  it("says no answer came when the request got none", () => {
    handleAxiosError({ request: {} });

    expect(shown()).toEqual([
      ["Error: no response received from server.", "error"],
    ]);
  });
});
