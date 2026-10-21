// The browser check. vite.config.mjs writes this file into index.html
// as a plain script after the root element, so it runs while the page
// is still being read, before the app's module script, which a browser
// runs only after the whole page is read.
//
// It is old JavaScript (ES5: var and function only) on purpose. It must
// run in the old browsers it is there to turn away. eslint.config.js
// holds this file to ES5, so newer syntax fails the lint.
//
// It tests the features the build needs. When a test fails, it draws a
// message in place of the page, and the app does not start: index.jsx
// reads window.comealsBrowserCheck and stops. When every test passes,
// the page loads as before. Either way it sends one report to
// POST /api/v1/browser-reports, which counts the page load and, for a
// failed check, alerts the owner.
//
// A mistake in this file must never turn away a working browser. So
// everything runs inside a try: an unexpected error lets the app start,
// and the error is reported.
(function (window) {
  "use strict";

  var document = window.document;
  var EMAIL = "david.paul.riddle@gmail.com";
  var REPORT_PATH = "/api/v1/browser-reports";

  // A page runs the check once. If this script were ever written into
  // the page twice, the page load would be counted twice.
  if (window.comealsBrowserCheck) return;

  // Each test, and in `since` the first version of each browser that
  // passes it. The newest version in each column is the oldest browser
  // the check lets through. tests/unit/browser_check.test.js compares
  // that with the build target (browser_target.mjs).
  var TESTS = [
    // A browser that cannot run module scripts never runs the app's
    // code, and the page would stay on "Loading..." forever. The
    // noModule property came with module scripts.
    {
      name: "modules",
      since: "chrome61 edge16 firefox60 safari11 ios11",
      run: function () {
        var Script = window.HTMLScriptElement;
        return !!Script && "noModule" in Script.prototype;
      },
    },
    // The build leaves regular expressions as they are written, so it
    // may ship a lookbehind to any browser in the target. This is the one
    // test that tells Safari 16.4 from Safari 16.3, and on iPads and
    // iPhones, Safari's version is the iOS version.
    {
      name: "lookbehind",
      since: "chrome62 edge79 firefox78 safari16.4 ios16.4",
      run: function () {
        try {
          new window.RegExp("(?<=a)b");
          return true;
        } catch (error) {
          return false;
        }
      },
    },
    // The app's styles mix colors (tokens.css: the focus rings). This is
    // the test that tells Chrome and Edge 111 from 110.
    {
      name: "color_mix",
      since: "chrome111 edge111 firefox113 safari16.2 ios16.2",
      run: function () {
        var css = window.CSS;
        return (
          !!css &&
          typeof css.supports === "function" &&
          css.supports("color", "color-mix(in srgb, red 50%, blue)")
        );
      },
    },
  ];

  // The login is kept in cookies (src/helpers/session.ts). A browser
  // that blocks them signs a person in, loads the page, finds no cookie,
  // and shows the login form again with no word about why. This writes a
  // cookie, reads it back, and removes it.
  function cookiesWork() {
    var cookie = "comeals_cookie_check=1";
    document.cookie = cookie + "; path=/; SameSite=Lax";
    var works = document.cookie.indexOf(cookie) !== -1;
    document.cookie = "comeals_cookie_check=; path=/; max-age=0; SameSite=Lax";
    return works;
  }

  // The messages. Inline styles only: the app's styles may not load,
  // or may be what this browser cannot read. The look follows the crash
  // page (src/helpers/crash_page.ts).
  var TOO_OLD = {
    title: "This browser is too old for Comeals.",
    lines: [
      "Comeals needs a newer browser. Here is what to do.",
      [
        "On an iPad or iPhone: ",
        "open Settings, then General, then Software Update, and install " +
          "the update. If there is no update to install, this iPad or " +
          "iPhone is too old for Comeals, and you need to use another " +
          "device.",
      ],
      [
        "On a computer or an Android phone: ",
        "update your browser, or open Comeals in another browser or on " +
          "another device.",
      ],
    ],
  };

  var NO_COOKIES = {
    title: "Comeals cannot keep you signed in.",
    lines: [
      "This browser blocks cookies. Comeals needs cookies to remember " +
        "who you are.",
      [
        "On an iPad or iPhone: ",
        "open Settings, then Safari, and turn off Block All Cookies. " +
          "Then open Comeals again.",
      ],
      [
        "On a computer or an Android phone: ",
        "open your browser's settings and allow cookies for comeals.com.",
      ],
    ],
  };

  function element(tag, style, text) {
    var node = document.createElement(tag);
    node.setAttribute("style", style);
    if (text) node.appendChild(document.createTextNode(text));
    return node;
  }

  function showMessage(message) {
    var page = element(
      "div",
      "max-width:36rem;margin:0 auto;padding:2rem 1rem;" +
        "font-family:Roboto,Helvetica,Arial,sans-serif;font-size:1.125rem;" +
        "line-height:1.5;color:#1b1b1b;text-align:center;"
    );
    page.appendChild(
      element("h2", "font-size:1.5rem;margin:0 0 1rem;", message.title)
    );
    for (var i = 0; i < message.lines.length; i++) {
      var line = message.lines[i];
      var paragraph = element("p", "margin:0 0 1rem;");
      if (typeof line === "string") {
        paragraph.appendChild(document.createTextNode(line));
      } else {
        paragraph.appendChild(element("strong", "", line[0]));
        paragraph.appendChild(document.createTextNode(line[1]));
      }
      page.appendChild(paragraph);
    }
    var help = element(
      "p",
      "margin:0 0 1rem;",
      "If that does not help, email David at "
    );
    var email = element("a", "color:#1b1b1b;", EMAIL);
    email.setAttribute("href", "mailto:" + EMAIL);
    help.appendChild(email);
    help.appendChild(document.createTextNode("."));
    page.appendChild(help);

    var root = document.getElementById("root") || document.body;
    while (root.firstChild) root.removeChild(root.firstChild);
    root.appendChild(page);
  }

  // One report, with no body: everything is in the URL, and the server
  // reads the browser from the User-Agent header. sendBeacon when the
  // browser has it, because it never holds up the page; otherwise an
  // XMLHttpRequest. A report that cannot be sent is let go.
  function report(query) {
    var touch = window.navigator.maxTouchPoints > 1 ? "1" : "0";
    var url = REPORT_PATH + "?" + query + "&touch=" + touch;
    try {
      var beacon = window.navigator.sendBeacon;
      if (beacon && window.navigator.sendBeacon(url)) return;
      var request = new window.XMLHttpRequest();
      request.open("POST", url, true);
      request.send();
    } catch (error) {
      // Nothing to do: the report is the only thing that failed.
    }
  }

  var check = { result: "passed", failed: [], tests: TESTS };
  window.comealsBrowserCheck = check;

  try {
    for (var i = 0; i < TESTS.length; i++) {
      if (!TESTS[i].run()) check.failed.push(TESTS[i].name);
    }
    var tooOld = check.failed.length > 0;
    if (!cookiesWork()) check.failed.push("cookies");

    if (check.failed.length === 0) {
      report("result=passed");
      return;
    }
    check.result = "failed";
    showMessage(tooOld ? TOO_OLD : NO_COOKIES);
    report("result=failed&tests=" + check.failed.join(","));
  } catch (error) {
    check.result = "error";
    check.failed = [];
    report(
      "result=error&error=" + encodeURIComponent(String(error).slice(0, 200))
    );
  }
})(window);
