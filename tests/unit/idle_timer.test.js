// The idle timer in index.html (a plain script, so it runs even when the
// app's bundle does not). After 5 minutes with no touch it sends the page
// back to the calendar, but only when nothing on the page can be lost and
// the server answers. During a deploy Heroku answers with its maintenance
// page, which never reloads, so a screen sent there would stay on it.
import fs from "node:fs";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const html = fs.readFileSync(
  path.resolve(__dirname, "../../app/frontend/index.html"),
  "utf8",
);
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

const FIVE_MINUTES = 5 * 60 * 1000;
const THIRTY_SECONDS = 30 * 1000;

let win;
let fetchMock;

function answer(ok) {
  return Promise.resolve({ ok: ok });
}

function touch() {
  win.onmousemove();
}

beforeEach(function () {
  vi.useFakeTimers();
  document.body.innerHTML = "";
  fetchMock = vi.fn(function () {
    return answer(true);
  });
  win = {
    location: { href: "https://comeals.com/meals/1/edit/" },
    Comeals: { modalDirty: false },
    addEventListener: vi.fn(),
  };
  new Function("window", "document", "fetch", script)(win, document, fetchMock);
});

afterEach(function () {
  vi.clearAllTimers();
  vi.useRealTimers();
});

describe("the idle timer", () => {
  it("does nothing on a page nobody touched", async () => {
    await vi.advanceTimersByTimeAsync(4 * FIVE_MINUTES);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(win.location.href).toBe("https://comeals.com/meals/1/edit/");
  });

  it("asks the server, then goes to the calendar 5 minutes after the last touch", async () => {
    touch();
    await vi.advanceTimersByTimeAsync(FIVE_MINUTES - 1);
    expect(fetchMock).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(1);

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/version", {
      cache: "no-store",
    });
    expect(win.location.href).toBe("/");
  });

  it("waits while the server answers with an error, and goes once it answers", async () => {
    fetchMock.mockImplementationOnce(function () {
      return answer(false);
    });
    touch();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES);
    expect(win.location.href).toBe("https://comeals.com/meals/1/edit/");

    await vi.advanceTimersByTimeAsync(THIRTY_SECONDS);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(win.location.href).toBe("/");
  });

  it("waits while the server cannot be reached", async () => {
    fetchMock.mockImplementationOnce(function () {
      return Promise.reject(new TypeError("Failed to fetch"));
    });
    touch();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES);
    expect(win.location.href).toBe("https://comeals.com/meals/1/edit/");

    await vi.advanceTimersByTimeAsync(THIRTY_SECONDS);
    expect(win.location.href).toBe("/");
  });

  it("waits while a calendar form holds unsaved changes", async () => {
    win.Comeals.modalDirty = true;
    touch();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES + 3 * THIRTY_SECONDS);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(win.location.href).toBe("https://comeals.com/meals/1/edit/");

    win.Comeals.modalDirty = false;
    await vi.advanceTimersByTimeAsync(THIRTY_SECONDS);
    expect(win.location.href).toBe("/");
  });

  it("waits while a text field with text in it has the focus", async () => {
    document.body.innerHTML = '<textarea id="menu">Soup and</textarea>';
    const menu = document.getElementById("menu");
    menu.focus();
    touch();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES + THIRTY_SECONDS);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(win.location.href).toBe("https://comeals.com/meals/1/edit/");

    menu.blur();
    await vi.advanceTimersByTimeAsync(THIRTY_SECONDS);
    expect(win.location.href).toBe("/");
  });

  it("is not held by an empty text field that has the focus", async () => {
    document.body.innerHTML = '<input id="email" type="email" value="">';
    document.getElementById("email").focus();
    touch();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES);
    expect(win.location.href).toBe("/");
  });

  it("is not held by a focused checkbox", async () => {
    document.body.innerHTML = '<input id="veg" type="checkbox" value="on">';
    document.getElementById("veg").focus();
    touch();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES);
    expect(win.location.href).toBe("/");
  });

  it("stays when the page is touched while the server check is on its way", async () => {
    let respond;
    fetchMock.mockImplementationOnce(function () {
      return new Promise(function (resolve) {
        respond = resolve;
      });
    });
    touch();
    await vi.advanceTimersByTimeAsync(FIVE_MINUTES);

    touch();
    respond({ ok: true });
    await vi.advanceTimersByTimeAsync(0);

    expect(win.location.href).toBe("https://comeals.com/meals/1/edit/");
  });

  it("can be started by the version banner on a page nobody touched", async () => {
    win.idleTimerKick();

    await vi.advanceTimersByTimeAsync(FIVE_MINUTES);
    expect(win.location.href).toBe("/");
  });
});
