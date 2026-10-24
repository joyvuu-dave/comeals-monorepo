import { describe, it, expect, afterEach } from "vitest";
import preloadCalendarPlugin from "../../app/frontend/preload_calendar.mjs";

// The calendar's code is preloaded from index.html, so it downloads
// beside the main bundle instead of after it (#44). index.html is the
// same page for every address (FallbackController serves it), so a
// script in it adds the preload only on a calendar address. The login
// page and the meal page do not run the calendar's code, and on a slow
// phone the 77 kB download took bandwidth from their first screen.

const TEMPLATE =
  "<!doctype html>\n<html>\n  <head>\n    " +
  '<meta charset="utf-8" />\n    <title>Comeals</title>\n' +
  '    <script type="module" src="/vite-assets/index.js"></script>\n' +
  "  </head>\n</html>\n";

// What Vite hands the plugin for a build: the entry, the calendar chunk,
// and the calendar chunk's own imports, one of which the entry already
// loads.
const BUNDLE = {
  "vite-assets/index.js": {
    fileName: "vite-assets/index.js",
    isEntry: true,
    imports: ["vite-assets/helpers.js"],
  },
  "vite-assets/show.js": {
    fileName: "vite-assets/show.js",
    facadeModuleId: "/repo/app/frontend/src/components/calendar/show.jsx",
    imports: ["vite-assets/helpers.js", "vite-assets/icon.js"],
  },
  "vite-assets/helpers.js": { fileName: "vite-assets/helpers.js" },
  "vite-assets/icon.js": { fileName: "vite-assets/icon.js" },
};

function transform(html, bundle = BUNDLE) {
  return preloadCalendarPlugin().transformIndexHtml.handler(html, { bundle });
}

// Runs the page's preload script at `path` and returns the hrefs of the
// modulepreload links it added.
function preloadsAt(path, html) {
  window.history.replaceState(null, "", path);
  const source = /<script id="calendar-preload">([\s\S]*?)<\/script>/.exec(
    html,
  )[1];
  new Function(source)();
  return [...document.head.querySelectorAll('link[rel="modulepreload"]')].map(
    (link) => link.getAttribute("href"),
  );
}

afterEach(() => {
  document.head
    .querySelectorAll('link[rel="modulepreload"]')
    .forEach((link) => link.remove());
  window.history.replaceState(null, "", "/");
});

describe("the calendar preload", () => {
  it("runs right after <meta charset>, before anything else in the head", () => {
    const html = transform(TEMPLATE);
    expect(html).toMatch(
      /<meta charset="utf-8" \/>\n {4}<script id="calendar-preload">/,
    );
    // The page has no plain modulepreload link for the calendar.
    expect(html).not.toContain('rel="modulepreload"');
  });

  it.each([
    "/calendar/all/2026-10-01/",
    "/calendar/meals/2026-10-01/",
    "/calendar/all/2026-10-01/guest-room/new/",
  ])("preloads the calendar's code on %s", (path) => {
    expect(preloadsAt(path, transform(TEMPLATE))).toEqual([
      "/vite-assets/show.js",
      "/vite-assets/icon.js",
    ]);
  });

  it.each(["/", "/reset-password/abc/", "/meals/12/edit/", "/calendarx/"])(
    "preloads nothing on %s",
    (path) => {
      expect(preloadsAt(path, transform(TEMPLATE))).toEqual([]);
    },
  );

  it("leaves the page alone in the dev server, which has no bundle", () => {
    const handler = preloadCalendarPlugin().transformIndexHtml.handler;
    expect(handler(TEMPLATE, {})).toBeUndefined();
  });

  // bin/bundle-budget fails the build when the preload is missing, so a
  // moved calendar/show.jsx does not drop it with no error.
  it("leaves the page alone when the build has no calendar chunk", () => {
    const bundle = { "vite-assets/index.js": BUNDLE["vite-assets/index.js"] };
    expect(transform(TEMPLATE, bundle)).toBeUndefined();
  });

  it("refuses a page with no <meta charset> line to put it after", () => {
    expect(() => transform("<html><head></head></html>")).toThrow(
      /no <meta charset="utf-8" \/> line/,
    );
  });
});
