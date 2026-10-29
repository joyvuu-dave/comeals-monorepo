import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { BUILD_TARGET } from "../../app/frontend/browser_target.mjs";
import viteConfig from "../../vite.config.mjs";

// app/frontend/browser_check.js is a plain script that vite.config.mjs
// writes into index.html, so it runs before the app's code. It is
// written in old JavaScript (ES5) on purpose: it must run in the old
// browsers it is there to turn away. These tests run its text with a
// window made for each test, so a test can take a feature away without
// changing the real one.

const SOURCE = fs.readFileSync(
  path.resolve(__dirname, "../../app/frontend/browser_check.js"),
  "utf8",
);

const TOO_OLD = "This browser is too old for Comeals.";
const NO_COOKIES = "Comeals cannot keep you signed in.";

// A browser with every feature the check asks for. `changes` replaces
// parts of it.
function makeWindow(changes = {}) {
  const sendBeacon = vi.fn(() => true);
  // The window's own events (an error a script threw), apart from the
  // document's.
  const events = new EventTarget();
  const win = {
    addEventListener: events.addEventListener.bind(events),
    dispatchEvent: events.dispatchEvent.bind(events),
    document,
    navigator: { sendBeacon, maxTouchPoints: 0 },
    RegExp,
    CSS: { supports: () => true },
    HTMLScriptElement: { prototype: { noModule: false } },
    XMLHttpRequest: undefined,
    ...changes,
  };
  return win;
}

function runCheck(win) {
  new Function("window", SOURCE)(win);
  return win.comealsBrowserCheck;
}

// A RegExp that refuses lookbehind, like Safari before 16.4.
function RegExpWithoutLookbehind(source, flags) {
  if (String(source).indexOf("(?<") !== -1) {
    throw new SyntaxError("Invalid regular expression: invalid group");
  }
  return new RegExp(source, flags);
}

function root() {
  return document.getElementById("root");
}

function reportUrl(win) {
  return win.navigator.sendBeacon.mock.calls[0][0];
}

beforeEach(() => {
  document.body.innerHTML =
    '<div id="root"><header class="shell-header"></header>' +
    '<h3 class="shell-loading">Loading...</h3></div>';
});

afterEach(() => {
  // A test that blocks cookies puts its own cookie property on the
  // document; deleting it brings back jsdom's.
  delete document.cookie;
  document.body.innerHTML = "";
});

describe("a browser that has every feature", () => {
  it("passes, leaves the page alone, and reports that it passed", () => {
    const win = makeWindow();
    const check = runCheck(win);

    expect(check.result).toBe("passed");
    expect(check.failed).toEqual([]);
    expect(root().textContent).toBe("Loading...");
    expect(win.navigator.sendBeacon).toHaveBeenCalledTimes(1);
    expect(reportUrl(win)).toBe(
      "/api/v1/browser-reports?result=passed&touch=0",
    );
  });

  it("leaves no test cookie behind", () => {
    runCheck(makeWindow());
    expect(document.cookie).not.toContain("comeals_cookie_check");
  });

  // An iPad's Safari says it is a Mac. A touch screen with more than
  // one touch point is how the server tells the two apart.
  it("says when the screen takes touch, so the server can tell an iPad from a Mac", () => {
    const win = makeWindow();
    win.navigator.maxTouchPoints = 5;
    runCheck(win);
    expect(reportUrl(win)).toBe(
      "/api/v1/browser-reports?result=passed&touch=1",
    );
  });

  // The script is written into the page once, but if it ever ran twice
  // in one page, the page would be counted twice.
  it("runs once per page, even when the script runs twice", () => {
    const win = makeWindow();
    runCheck(win);
    runCheck(win);
    expect(win.navigator.sendBeacon).toHaveBeenCalledTimes(1);
  });
});

describe("a browser that is too old", () => {
  it("refuses Safari before 16.4, which has no regular expression lookbehind", () => {
    const win = makeWindow({ RegExp: RegExpWithoutLookbehind });
    const check = runCheck(win);

    expect(check.result).toBe("failed");
    expect(check.failed).toEqual(["lookbehind"]);
    expect(reportUrl(win)).toBe(
      "/api/v1/browser-reports?result=failed&tests=lookbehind&touch=0",
    );
  });

  it("refuses a browser that cannot mix colors in CSS (Chrome before 111)", () => {
    const win = makeWindow({
      CSS: { supports: (property, value) => !/color-mix/.test(value) },
    });
    expect(runCheck(win).failed).toEqual(["color_mix"]);
  });

  it("refuses a browser with no CSS.supports at all", () => {
    expect(runCheck(makeWindow({ CSS: undefined })).failed).toEqual([
      "color_mix",
    ]);
  });

  it("refuses a browser that cannot run the app's modules", () => {
    const win = makeWindow({ HTMLScriptElement: { prototype: {} } });
    expect(runCheck(win).failed).toEqual(["modules"]);
  });

  it("shows what is wrong and what to do, in place of the page", () => {
    runCheck(makeWindow({ RegExp: RegExpWithoutLookbehind }));

    const text = root().textContent;
    expect(root().querySelector("h2").textContent).toBe(TOO_OLD);
    expect(text).not.toContain("Loading...");
    expect(text).toContain(
      "On an iPad or iPhone: open Settings, then General, then Software Update, and install the update.",
    );
    expect(text).toContain(
      "On a computer or an Android phone: update your browser, or open Comeals in another browser or on another device.",
    );
    const email = root().querySelector("a");
    expect(email.getAttribute("href")).toBe(
      "mailto:david.paul.riddle@gmail.com",
    );
  });

  it("lists every failed test in the report", () => {
    const win = makeWindow({
      RegExp: RegExpWithoutLookbehind,
      CSS: undefined,
      HTMLScriptElement: undefined,
    });
    expect(runCheck(win).failed).toEqual([
      "modules",
      "lookbehind",
      "color_mix",
    ]);
    expect(reportUrl(win)).toBe(
      "/api/v1/browser-reports?result=failed&tests=modules,lookbehind,color_mix&touch=0",
    );
  });
});

describe("a browser that blocks cookies", () => {
  function blockCookies() {
    Object.defineProperty(document, "cookie", {
      configurable: true,
      get: () => "",
      set: () => {},
    });
  }

  // The login is kept in cookies (helpers/session.ts). With cookies
  // blocked, a person signs in, the page loads, finds no cookie, and
  // shows the login form again, with no word about why.
  it("refuses, and says how to allow cookies", () => {
    blockCookies();
    const win = makeWindow();
    const check = runCheck(win);

    expect(check.result).toBe("failed");
    expect(check.failed).toEqual(["cookies"]);
    expect(root().querySelector("h2").textContent).toBe(NO_COOKIES);
    expect(root().textContent).toContain(
      "On an iPad or iPhone: open Settings, then Safari, and turn off Block All Cookies.",
    );
    expect(reportUrl(win)).toBe(
      "/api/v1/browser-reports?result=failed&tests=cookies&touch=0",
    );
  });

  // Updating fixes the old browser; the cookie setting can wait until
  // the new browser asks for it.
  it("shows the old-browser message when the browser is also too old", () => {
    blockCookies();
    const check = runCheck(makeWindow({ RegExp: RegExpWithoutLookbehind }));
    expect(check.failed).toEqual(["lookbehind", "cookies"]);
    expect(root().querySelector("h2").textContent).toBe(TOO_OLD);
  });
});

describe("the report", () => {
  it("is sent by XMLHttpRequest when the browser has no sendBeacon", () => {
    const sent = [];
    function FakeRequest() {
      this.open = (method, url, async) => sent.push([method, url, async]);
      this.send = () => sent.push(["send"]);
    }
    const win = makeWindow({ XMLHttpRequest: FakeRequest });
    win.navigator.sendBeacon = undefined;
    runCheck(win);
    expect(sent).toEqual([
      ["POST", "/api/v1/browser-reports?result=passed&touch=0", true],
      ["send"],
    ]);
  });

  it("is sent by XMLHttpRequest when sendBeacon refuses it", () => {
    const sent = [];
    function FakeRequest() {
      this.open = (method, url) => sent.push(url);
      this.send = () => {};
    }
    const win = makeWindow({ XMLHttpRequest: FakeRequest });
    win.navigator.sendBeacon = vi.fn(() => false);
    runCheck(win);
    expect(sent).toEqual(["/api/v1/browser-reports?result=passed&touch=0"]);
  });

  it("never stops the page when it cannot be sent", () => {
    const win = makeWindow();
    win.navigator.sendBeacon = () => {
      throw new TypeError("blocked");
    };
    expect(runCheck(win).result).toBe("passed");
  });
});

describe("a check that breaks", () => {
  // The check is there to turn away old browsers. A mistake in the
  // check itself must never turn away a working one.
  it("lets the app start and reports the error", () => {
    const win = makeWindow({
      CSS: {
        supports: () => {
          throw new TypeError("boom");
        },
      },
    });
    const check = runCheck(win);

    expect(check.result).toBe("error");
    expect(root().textContent).toBe("Loading...");
    expect(reportUrl(win)).toBe(
      "/api/v1/browser-reports?result=error&error=TypeError%3A%20boom&touch=0",
    );
  });

  it("cuts a long error message to 200 characters", () => {
    const win = makeWindow({
      CSS: {
        supports: () => {
          throw new Error("x".repeat(500));
        },
      },
    });
    runCheck(win);
    const sentError = decodeURIComponent(
      reportUrl(win).match(/error=([^&]*)/)[1],
    );
    expect(sentError).toHaveLength(200);
  });
});

// The check stands for the build target: a browser it lets through must
// be one the build supports, and a browser below the build target should
// be turned away. Each test says, in `since`, the first version of each
// browser that has its feature. The newest of those, per browser, is
// the oldest version the check lets through. That must equal the build
// target in vite.config.mjs, so one cannot change without the other.
describe("the check and the build target", () => {
  function parse(list) {
    const versions = {};
    for (const entry of list) {
      const [, browser, version] = entry.match(/^([a-z]+)([\d.]+)$/);
      versions[browser] = Number(version);
    }
    return versions;
  }

  function checkMinimum() {
    const check = runCheck(makeWindow());
    const minimum = {};
    for (const test of check.tests) {
      for (const [browser, version] of Object.entries(
        parse(test.since.split(" ")),
      )) {
        minimum[browser] = Math.max(minimum[browser] || 0, version);
      }
    }
    return minimum;
  }

  // Firefox 114 added nothing a feature test can see at once (module
  // workers can only be tried by starting one), so the check lets
  // Firefox 113 through. Firefox updates itself, and 113 was replaced in
  // June 2023, so this is the one gap, and it is written here.
  const KNOWN_GAPS = { firefox: 113 };

  it("lets through exactly the browsers the build supports", () => {
    expect(checkMinimum()).toEqual({ ...parse(BUILD_TARGET), ...KNOWN_GAPS });
  });

  it("never turns away a browser the build supports", () => {
    const target = parse(BUILD_TARGET);
    for (const [browser, version] of Object.entries(checkMinimum())) {
      expect(version, browser).toBeLessThanOrEqual(target[browser]);
    }
  });
});

describe("the build", () => {
  const config = viteConfig({ command: "build", mode: "production" });

  it("builds the scripts and the styles for the target the check stands for", () => {
    expect(config.build.target).toEqual(BUILD_TARGET);
    expect(config.build.cssTarget).toEqual(BUILD_TARGET);
  });

  // The check must run before the app's module script, which a browser
  // runs only after the whole page is read. A plain script in the page
  // runs as soon as it is read, so it always runs first.
  it("writes the check into index.html as a plain script, after the root", () => {
    const html = fs.readFileSync(
      path.resolve(__dirname, "../../app/frontend/index.html"),
      "utf8",
    );
    const plugin = config.plugins.find((p) => p.name === "browser-check");
    const out = plugin.transformIndexHtml.handler(html);

    expect(out).not.toContain("<!-- browser-check -->");
    const script = `<script>\n${SOURCE}</script>`;
    expect(out).toContain(script);
    expect(out.indexOf(script)).toBeGreaterThan(out.indexOf('<div id="root">'));
    expect(out.indexOf(script)).toBeLessThan(
      out.indexOf('<script type="module"'),
    );
  });

  // A browser with JavaScript turned off runs none of this. The page
  // itself says what to do, and hides the "Loading..." that would
  // otherwise stay on the screen.
  it("tells a browser with JavaScript off how to turn it on", () => {
    const html = fs.readFileSync(
      path.resolve(__dirname, "../../app/frontend/index.html"),
      "utf8",
    );
    const text = html.replace(/\s+/g, " ");
    expect(text).toContain("Comeals needs JavaScript");
    expect(text).toContain(
      "open Settings, then Safari, then Advanced, and turn on JavaScript",
    );
    expect(html).toMatch(
      /<noscript>\s*<style>\s*#root\s*\{\s*display: none;\s*\}\s*<\/style>/,
    );
  });
});

// The check also watches the app's module script. When it cannot load,
// the page reloads once, and on a second failure shows a message with a
// Reload button and sends one report (tests/e2e/browser-check.spec.js
// runs the same in a real browser, against the build). Each test here
// has its own document, so the listeners one test adds never hear
// another test's events.
describe("when the app's code does not load", () => {
  const ORIGIN = "https://comeals.com";
  const FILE = "/vite-assets/index-abc123.js";
  const COULD_NOT_LOAD = "Comeals could not load.";

  // A sessionStorage, or one that throws on any use, like a browser set
  // to block site data.
  function makeStorage(blocked) {
    const items = {};
    return {
      items,
      getItem(key) {
        if (blocked) throw new Error("SecurityError");
        return key in items ? items[key] : null;
      },
      setItem(key, value) {
        if (blocked) throw new Error("SecurityError");
        items[key] = String(value);
      },
      removeItem(key) {
        if (blocked) throw new Error("SecurityError");
        delete items[key];
      },
    };
  }

  // Answers each version request with the next status in `statuses`;
  // 0 means the request failed with no answer.
  function makeVersionRequest(statuses) {
    const opened = [];
    function FakeRequest() {
      this.open = (method, url) => opened.push([method, url]);
      this.send = () => {
        const status = statuses.shift();
        if (status === 0) {
          this.onerror();
        } else {
          this.status = status;
          this.onload();
        }
      };
    }
    FakeRequest.opened = opened;
    return FakeRequest;
  }

  function makePage({ blocked = false, statuses = [200], changes = {} } = {}) {
    const doc = document.implementation.createHTMLDocument("Comeals");
    // A document made this way has no cookies, and the check would turn
    // the browser away for that. This one keeps the check's test cookie.
    let cookie = "";
    Object.defineProperty(doc, "cookie", {
      get: () => cookie,
      set: (value) => {
        cookie = /max-age=0/.test(value) ? "" : value.split(";")[0];
      },
    });
    doc.body.innerHTML =
      '<div id="root"><header class="shell-header"></header>' +
      '<h3 class="shell-loading">Loading...</h3></div>';
    const script = doc.createElement("script");
    script.type = "module";
    script.setAttribute("src", FILE);
    doc.head.appendChild(script);
    const win = makeWindow({
      document: doc,
      sessionStorage: makeStorage(blocked),
      location: { origin: ORIGIN, reload: vi.fn() },
      setTimeout: vi.fn((fn) => fn()),
      XMLHttpRequest: makeVersionRequest(statuses),
      ...changes,
    });
    return { win, doc, script };
  }

  function fire(target, type) {
    target.dispatchEvent(new Event(type));
  }

  function reports(win) {
    return win.navigator.sendBeacon.mock.calls.map((call) => call[0]);
  }

  it("reloads once, after the server answers, and remembers the file", () => {
    const { win, script } = makePage();
    runCheck(win);

    fire(script, "error");

    expect(win.location.reload).toHaveBeenCalledTimes(1);
    expect(win.XMLHttpRequest.opened).toEqual([["GET", "/api/v1/version"]]);
    expect(win.sessionStorage.items.app_retry).toBe(FILE);
    expect(reports(win)).toEqual([
      "/api/v1/browser-reports?result=passed&touch=0",
    ]);
  });

  // During a deploy every request gets Heroku's maintenance page, which
  // never reloads itself. So the page asks again until the server
  // answers.
  it("waits while the server does not answer, then reloads", () => {
    const { win, script } = makePage({ statuses: [503, 0, 200] });
    runCheck(win);

    fire(script, "error");

    expect(win.XMLHttpRequest.opened).toHaveLength(3);
    expect(win.setTimeout).toHaveBeenCalledTimes(2);
    expect(win.setTimeout.mock.calls[0][1]).toBe(30000);
    expect(win.location.reload).toHaveBeenCalledTimes(1);
  });

  it("on the second failure of the same file, shows a message and reports once", () => {
    const { win, doc, script } = makePage();
    win.sessionStorage.setItem("app_retry", FILE);
    runCheck(win);

    fire(script, "error");
    fire(script, "error");

    expect(win.location.reload).not.toHaveBeenCalled();
    const root = doc.getElementById("root");
    expect(root.querySelector("h2").textContent).toBe(COULD_NOT_LOAD);
    expect(root.textContent).not.toContain("Loading...");
    expect(reports(win)).toEqual([
      "/api/v1/browser-reports?result=passed&touch=0",
      `/api/v1/browser-reports?result=load_failed&error=${encodeURIComponent(
        `Could not load ${FILE}`,
      )}&touch=0`,
    ]);
    // The flag stays, so the Reload button cannot start a loop either.
    expect(win.sessionStorage.items.app_retry).toBe(FILE);
  });

  it("the Reload button reloads the page", () => {
    const { win, doc, script } = makePage();
    win.sessionStorage.setItem("app_retry", FILE);
    runCheck(win);
    fire(script, "error");

    const button = doc.querySelector("button");
    expect(button.textContent).toBe("Reload");
    expect(button.getAttribute("type")).toBe("button");
    button.click();
    expect(win.location.reload).toHaveBeenCalledTimes(1);
  });

  // A new deploy names its files anew. A flag left by a reload for an
  // older build says nothing about this one.
  it("counts a failure of a different file as a first failure", () => {
    const { win, script } = makePage();
    win.sessionStorage.setItem("app_retry", "/vite-assets/index-old.js");
    runCheck(win);

    fire(script, "error");

    expect(win.location.reload).toHaveBeenCalledTimes(1);
    expect(win.sessionStorage.items.app_retry).toBe(FILE);
  });

  it("never reloads when sessionStorage cannot be used, and reports at once", () => {
    const { win, doc, script } = makePage({ blocked: true });
    runCheck(win);

    fire(script, "error");

    expect(win.location.reload).not.toHaveBeenCalled();
    expect(doc.querySelector("h2").textContent).toBe(COULD_NOT_LOAD);
    expect(reports(win)).toHaveLength(2);
  });

  it("clears the flag when the script loads, so a later deploy can reload again", () => {
    const { win, script } = makePage();
    win.sessionStorage.setItem("app_retry", FILE);
    runCheck(win);

    fire(script, "load");

    expect(win.sessionStorage.items.app_retry).toBeUndefined();
  });

  // In dev, Vite's own module script loads before the app's. Clearing the
  // app's flag there would let a missing app file reload over and over.
  it("keeps the flag when another module script loads", () => {
    const { win, doc } = makePage();
    win.sessionStorage.setItem("app_retry", FILE);
    runCheck(win);
    const other = doc.createElement("script");
    other.type = "module";
    other.setAttribute("src", "/@vite/client");
    doc.head.appendChild(other);

    fire(other, "load");

    expect(win.sessionStorage.items.app_retry).toBe(FILE);
  });

  it("does not throw on a load when sessionStorage cannot be used", () => {
    const { win, script } = makePage({ blocked: true });
    runCheck(win);
    expect(() => fire(script, "load")).not.toThrow();
  });

  it("ignores errors from anything that is not a module script with a file", () => {
    const { win, doc } = makePage();
    runCheck(win);
    const image = doc.createElement("img");
    const plain = doc.createElement("script");
    plain.setAttribute("src", "/pusher.js");
    const inline = doc.createElement("script");
    inline.type = "module";
    doc.body.append(image, plain, inline);

    fire(image, "error");
    fire(plain, "error");
    fire(inline, "error");
    fire(doc, "error");

    expect(win.location.reload).not.toHaveBeenCalled();
    expect(reports(win)).toHaveLength(1);
  });

  // The check's own message says what to do about an old browser. A
  // failed script must not replace it.
  it("leaves the old-browser message alone", () => {
    const { win, doc, script } = makePage({
      changes: { RegExp: RegExpWithoutLookbehind },
    });
    runCheck(win);

    fire(script, "error");

    expect(win.location.reload).not.toHaveBeenCalled();
    expect(doc.querySelector("h2").textContent).toBe(TOO_OLD);
    expect(reports(win)).toHaveLength(1);
  });

  it("cuts a long file name in the report to 200 characters", () => {
    const { win, script } = makePage({ blocked: true });
    script.setAttribute("src", "/" + "x".repeat(300));
    runCheck(win);

    fire(script, "error");

    const sentError = decodeURIComponent(
      reports(win)[1].match(/error=([^&]*)/)[1],
    );
    expect(sentError).toHaveLength(200);
  });

  // A file the app imports throws while it runs, before index.jsx's own
  // code. The script has downloaded, so the browser fires "load" on it,
  // not "error", and the throw goes only to the window. Without this the
  // page stays on "Loading..." with no report (#253).
  describe("when the app's code throws before it starts", () => {
    const CRASHED = "Comeals could not load.";

    function throwIn(win, file, message = "TypeError: x is not a function") {
      win.dispatchEvent(
        new ErrorEvent("error", { message, filename: file, lineno: 3 }),
      );
    }

    it("shows a message with a Reload button and reports once", () => {
      const { win, doc } = makePage();
      runCheck(win);

      throwIn(win, `${ORIGIN}/vite-assets/dayjs-abc.js`);
      throwIn(win, `${ORIGIN}/vite-assets/dayjs-abc.js`);

      expect(doc.querySelector("h2").textContent).toBe(CRASHED);
      expect(doc.getElementById("root").textContent).toContain(
        "Something went wrong while the page was starting.",
      );
      expect(doc.querySelector("button").textContent).toBe("Reload");
      expect(win.location.reload).not.toHaveBeenCalled();
      expect(reports(win)).toEqual([
        "/api/v1/browser-reports?result=passed&touch=0",
        `/api/v1/browser-reports?result=load_failed&error=${encodeURIComponent(
          "Crashed while starting: TypeError: x is not a function " +
            "(/vite-assets/dayjs-abc.js:3)",
        )}&touch=0`,
      ]);
    });

    // Once index.jsx has started the app, its own error handling and
    // Bugsnag take over.
    it("leaves errors alone once the app has started", () => {
      const { win, doc } = makePage();
      runCheck(win).appStarted = true;

      throwIn(win, `${ORIGIN}/vite-assets/index-abc123.js`);

      expect(doc.querySelector("h2")).toBeNull();
      expect(reports(win)).toHaveLength(1);
    });

    // A browser extension or another site's script can throw on this
    // page too. That says nothing about the app. Another site's error
    // reaches the page as "Script error." with no file.
    it("leaves errors from scripts that are not this site's alone", () => {
      const { win, doc } = makePage();
      runCheck(win);

      throwIn(win, "chrome-extension://abc/content.js");
      throwIn(win, "https://example.com/comeals.com/app.js");
      throwIn(win, "", "Script error.");

      expect(doc.querySelector("h2")).toBeNull();
      expect(reports(win)).toHaveLength(1);
    });

    it("leaves the old-browser message alone", () => {
      const { win, doc } = makePage({
        changes: { RegExp: RegExpWithoutLookbehind },
      });
      runCheck(win);

      throwIn(win, `${ORIGIN}/vite-assets/index-abc123.js`);

      expect(doc.querySelector("h2").textContent).toBe(TOO_OLD);
      expect(reports(win)).toHaveLength(1);
    });

    // One message and one report, whichever comes first.
    it("adds nothing when the script also failed to load", () => {
      const { win, doc, script } = makePage({ blocked: true });
      runCheck(win);

      fire(script, "error");
      throwIn(win, `${ORIGIN}/vite-assets/index-abc123.js`);

      expect(doc.querySelector("h2").textContent).toBe(COULD_NOT_LOAD);
      expect(doc.getElementById("root").textContent).toContain(
        "Part of the page did not download.",
      );
      expect(reports(win)).toHaveLength(2);
    });

    it("cuts a long error in the report to 200 characters", () => {
      const { win } = makePage();
      runCheck(win);

      throwIn(win, `${ORIGIN}/vite-assets/a.js`, "x".repeat(300));

      const sentError = decodeURIComponent(
        reports(win)[1].match(/error=([^&]*)/)[1],
      );
      expect(sentError).toHaveLength(200);
    });
  });
});
