// Large text in real iOS Safari (challenge 32).
//
// The Playwright suites run desktop WebKit, which cannot do what an
// iPhone's aA button does: make the text larger while the page keeps
// its width. This script drives Safari itself, in the iPhone and iPad
// simulators that come with Xcode, through safaridriver (Apple's
// WebDriver server, part of macOS). For each device it opens every
// screen at normal text, at 200% text, and with the device's own Larger
// Text setting at its largest, and fails when:
//
//   - the page is wider than the screen,
//   - two controls are drawn on top of each other, or a box cuts off
//     text (findLayoutProblems in tests/helpers/accessibility.js, the
//     same check the Playwright text-size spec runs), or
//   - a form's main button is not on screen without scrolling, or
//   - the root's font size is not the one the text setting asks for
//     (helpers/system_text_size.ts).
//
// 200% text is set with -webkit-text-size-adjust on the page's root.
// In iOS Safari that draws every font twice as large while the page
// keeps its width in CSS pixels, which is what a larger setting of the
// iPhone's aA button does. (Desktop WebKit and Chromium ignore the
// property, so this check can only run in the simulator.)
//
// The Larger Text setting is set with `xcrun simctl ui <device>
// content_size`, as Settings → Accessibility → Display & Text Size does.
// Its largest size makes the system's text 312% of the default; the app
// follows it up to 200%. The setting goes back to the default when the
// run ends, even when it fails.
//
// It runs against the real Rails test server and the seeded data, so
// run it through bin/test-ios, which seeds, starts the server and stops
// it afterwards. A picture of every screen is saved in tmp/ios/.

import { execFileSync, spawn } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const require = createRequire(import.meta.url);
const { findLayoutProblems } = require("../helpers/accessibility.js");
const ports = require("../helpers/ports.js");

const ROOT = path.resolve(
  path.dirname(new URL(import.meta.url).pathname),
  "../..",
);
const BASE = `http://localhost:${ports.INTEGRATION_PORT}`;
const SHOTS = path.join(ROOT, "tmp/ios");
const auth = JSON.parse(
  fs.readFileSync(path.join(ROOT, "tmp/integration_auth.json"), "utf-8"),
);

// The newest iOS runtime installed, and on it one phone and one iPad.
// The iPhone 17 is 402 CSS pixels wide, the iPad mini 744 upright.
const DEVICES = ["iPhone 17", "iPad mini (A17 Pro)"];
// Each text setting: its name in the results, the -webkit-text-size-adjust
// it sets, the Larger Text setting, and the root font size the app must
// then have.
const DEFAULT_CONTENT_SIZE = "large";
const TEXT_SETTINGS = [
  {
    name: "text 100%",
    adjust: 100,
    contentSize: DEFAULT_CONTENT_SIZE,
    rootPx: 16,
  },
  {
    name: "text 200%",
    adjust: 200,
    contentSize: DEFAULT_CONTENT_SIZE,
    rootPx: 16,
  },
  {
    name: "Larger Text at its largest",
    adjust: 100,
    contentSize: "accessibility-extra-extra-extra-large",
    rootPx: 32,
  },
];

const CALENDAR = "/calendar/all/2026-01-15/";
const SCREENS = [
  {
    name: "login",
    url: "/",
    signedIn: false,
    ready: 'input[aria-label="email"]',
  },
  { name: "calendar", url: CALENDAR, ready: ".rbc-event" },
  { name: "meal", url: `/meals/${auth.meals.today.id}/edit/`, ready: "table" },
  {
    name: "closed meal",
    url: `/meals/${auth.meals.closed.id}/edit/`,
    ready: "table",
  },
  {
    name: "new event",
    url: `${CALENDAR}events/new/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "new Common House booking",
    url: `${CALENDAR}common-house-reservations/new/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "new guest room booking",
    url: `${CALENDAR}guest-room-reservations/new/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "profile",
    url: `${CALENDAR}profile/edit/`,
    ready: "form",
    scope: "[role='dialog']",
  },
  {
    name: "rotation",
    url: `${CALENDAR}rotations/show/${auth.rotations.first.id}/`,
    ready: "[data-populated='true']",
    scope: "[role='dialog']",
  },
];

function simulators() {
  const list = JSON.parse(
    execFileSync(
      "xcrun",
      ["simctl", "list", "devices", "available", "--json"],
      {
        encoding: "utf-8",
      },
    ),
  );
  const runtimes = Object.keys(list.devices)
    .filter((r) => r.includes("SimRuntime.iOS"))
    .sort((a, b) => {
      const v = (r) => r.split("iOS-")[1].split("-").map(Number);
      const [x, y] = [v(a), v(b)];
      return y[0] - x[0] || (y[1] || 0) - (x[1] || 0);
    });
  if (runtimes.length === 0) {
    throw new Error(
      "No iOS simulator runtime is installed (Xcode → Settings → Components).",
    );
  }
  const devices = list.devices[runtimes[0]];
  return DEVICES.map((name) => {
    const device = devices.find((d) => d.name === name);
    if (!device) {
      throw new Error(
        `No "${name}" simulator on ${runtimes[0]}. Add it in Xcode → Window → Devices and Simulators.`,
      );
    }
    return device;
  });
}

// bootstatus -b boots the device only when it is not booted yet, and
// waits until it is ready. A separate `simctl boot` chosen from the
// state read at the start failed when the device was booted after that
// read: "Unable to boot device in current state: Booted".
function boot(device) {
  execFileSync("xcrun", ["simctl", "bootstatus", device.udid, "-b"], {
    stdio: "ignore",
  });
}

// The device's Larger Text setting. Safari uses the new size from the
// next page it opens.
function contentSize(device, size) {
  execFileSync("xcrun", ["simctl", "ui", device.udid, "content_size", size]);
}

function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function startSafariDriver() {
  const port = await freePort();
  const child = spawn("safaridriver", ["-p", String(port)], {
    stdio: "ignore",
  });
  for (let i = 0; i < 50; i++) {
    try {
      await fetch(`http://localhost:${port}/status`);
      return { port, child };
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  child.kill();
  throw new Error("safaridriver did not start");
}

// A minimal WebDriver client: the four commands this check needs.
function webdriver(port) {
  const call = async (method, url, body) => {
    const response = await fetch(`http://localhost:${port}${url}`, {
      method,
      headers: { "content-type": "application/json" },
      body: body && JSON.stringify(body),
    });
    const json = await response.json();
    if (!response.ok) {
      throw new Error(`${method} ${url}: ${json.value && json.value.message}`);
    }
    return json.value;
  };
  return {
    async open(udid) {
      const { sessionId } = await call("POST", "/session", {
        capabilities: {
          alwaysMatch: {
            browserName: "safari",
            platformName: "iOS",
            "safari:useSimulator": true,
            "safari:deviceUDID": udid,
          },
        },
      });
      const s = `/session/${sessionId}`;
      return {
        go: (url) => call("POST", `${s}/url`, { url }),
        run: (script, args = []) =>
          call("POST", `${s}/execute/sync`, { script, args }),
        addCookie: (cookie) => call("POST", `${s}/cookie`, { cookie }),
        clearCookies: () => call("DELETE", `${s}/cookie`),
        screenshot: () => call("GET", `${s}/screenshot`),
        close: () => call("DELETE", s),
      };
    },
  };
}

async function signIn(session, signedIn) {
  await session.go(`${BASE}/api/v1/version`);
  await session.clearCookies();
  if (!signedIn) return;
  const cookies = {
    token: auth.token,
    community_id: String(auth.community_id),
    resident_id: String(auth.resident_id),
    username: auth.username,
    timezone: "America/Los_Angeles",
  };
  for (const [name, value] of Object.entries(cookies)) {
    await session.addCookie({ name, value, path: "/" });
  }
}

async function waitFor(session, selector) {
  for (let i = 0; i < 100; i++) {
    const found = await session.run(
      "const el = document.querySelector(arguments[0]); return !!el && el.checkVisibility();",
      [selector],
    );
    if (found) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`"${selector}" did not appear`);
}

async function check(session, screen, setting) {
  await signIn(session, screen.signedIn !== false);
  await session.go(`${BASE}${screen.url}`);
  await waitFor(session, screen.ready);
  await session.run(
    "document.documentElement.style.webkitTextSizeAdjust = arguments[0];",
    [`${setting.adjust}%`],
  );
  // Let the page lay itself out again with the new text size.
  await new Promise((r) => setTimeout(r, 500));

  const problems = [];
  const rootPx = await session.run(
    // The size the app set (helpers/system_text_size.ts), not the
    // computed size, which -webkit-text-size-adjust also changes.
    "return parseFloat(document.documentElement.style.fontSize);",
  );
  // NaN, when the app set no size, comes back from WebDriver as null.
  if (rootPx === null) {
    problems.push(
      `the app set no root font size; this text setting needs ${setting.rootPx}px`,
    );
  } else if (Math.abs(rootPx - setting.rootPx) > 0.01) {
    problems.push(
      `the root's font size is ${rootPx}px; this text setting needs ${setting.rootPx}px`,
    );
  }
  const { pageWidth, screenWidth } = await session.run(
    "return { pageWidth: document.documentElement.scrollWidth, screenWidth: window.innerWidth };",
  );
  if (pageWidth > screenWidth) {
    // The elements that reach past the right edge with none of their
    // own children doing so: the ones whose width is the cause. A box
    // that scrolls sideways or clips holds its content, so what is
    // inside one does not widen the page.
    const wide = await session.run(`
      const width = window.innerWidth;
      const holds = (el) => {
        for (let p = el.parentElement; p; p = p.parentElement) {
          if (getComputedStyle(p).overflowX !== "visible") return true;
        }
        return false;
      };
      const past = (el) => el.getBoundingClientRect().right > width + 1 && !holds(el);
      return [...document.body.querySelectorAll("*")]
        .filter((el) => past(el) && ![...el.children].some(past))
        .slice(0, 3)
        .map((el) => {
          const r = el.getBoundingClientRect();
          const name = (el.getAttribute("aria-label") || el.textContent || "")
            .trim().replace(/\\s+/g, " ").slice(0, 30);
          return el.tagName.toLowerCase() +
            (el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\\s+/).join(".") : "") +
            ' "' + name + '" ' + Math.round(r.left) + " to " + Math.round(r.right);
        });
    `);
    problems.push(
      `the page is ${pageWidth} wide on a ${screenWidth} screen` +
        (wide.length ? `; past the edge: ${wide.join("; ")}` : ""),
    );
  }
  problems.push(
    ...(await session.run(
      `return (${findLayoutProblems.toString()})(arguments[0]);`,
      [screen.scope || "body"],
    )),
  );
  if (screen.scope) {
    const offScreen = await session.run(
      `const b = document.querySelector(arguments[0] + " button[type=submit]");
       if (!b) return false;
       const r = b.getBoundingClientRect();
       return r.top < 0 || r.bottom > window.innerHeight;`,
      [screen.scope],
    );
    if (offScreen) problems.push("the form's main button is not on screen");
  }
  return problems;
}

async function checkDevice(device, failures) {
  boot(device);
  // One safaridriver for each device: it drives one simulator at a time.
  const driver = await startSafariDriver();
  let checked = 0;
  try {
    const session = await webdriver(driver.port).open(device.udid);
    try {
      for (const setting of TEXT_SETTINGS) {
        contentSize(device, setting.contentSize);
        for (const screen of SCREENS) {
          const label = `${device.name}, ${setting.name}, ${screen.name}`;
          let problems;
          try {
            problems = await check(session, screen, setting);
          } catch (error) {
            problems = [error.message];
          }
          const file = `${device.name}-${setting.name}-${screen.name}`.replace(
            /[^\w-]+/g,
            "-",
          );
          fs.writeFileSync(
            path.join(SHOTS, `${file}.png`),
            Buffer.from(await session.screenshot(), "base64"),
          );
          checked++;
          if (problems.length) {
            failures.push(label);
            console.log(`  ✗ ${label}\n      ${problems.join("\n      ")}`);
          } else {
            console.log(`  ✓ ${label}`);
          }
        }
      }
    } finally {
      await session.close();
    }
  } finally {
    driver.child.kill();
    contentSize(device, DEFAULT_CONTENT_SIZE);
    execFileSync("xcrun", ["simctl", "shutdown", device.udid]);
  }
  return checked;
}

// Screens that fail today, each with the issue that will fix it. A
// screen on this list may fail; when it passes, the run fails until it
// is taken off, so the list only gets shorter. Any other failure fails
// the run.
const KNOWN_FAILURES_FILE = path.join(ROOT, "tests/ios/known_failures.txt");

function knownFailures() {
  return new Set(
    fs
      .readFileSync(KNOWN_FAILURES_FILE, "utf-8")
      .split("\n")
      .map((line) => line.replace(/#.*/, "").trim())
      .filter(Boolean),
  );
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const known = knownFailures();
  const failures = [];
  let checked = 0;
  for (const device of simulators()) {
    checked += await checkDevice(device, failures);
  }
  const failed = new Set(failures);
  const unexpected = failures.filter((label) => !known.has(label));
  const nowPassing = [...known].filter((label) => !failed.has(label));
  console.log("");
  console.log(
    `${checked} screens: ${failures.length} failed, ` +
      `${failures.length - unexpected.length} of them known ` +
      `(tests/ios/known_failures.txt). Pictures: ${SHOTS}`,
  );
  if (unexpected.length) {
    console.log("\nNew failures:\n  " + unexpected.join("\n  "));
  }
  if (nowPassing.length) {
    console.log(
      "\nThese now pass. Take them off tests/ios/known_failures.txt:\n  " +
        nowPassing.join("\n  "),
    );
  }
  if (unexpected.length || nowPassing.length) process.exit(1);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
