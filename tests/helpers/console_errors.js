// The browser's own log line when a <link rel="preconnect"> fails, as
// WebKit writes it while the machine is offline. A preconnect is only a
// hint, and the app does not use its result, so this is never an app
// error (#236). Chromium logs nothing for it.
const failedPreconnectPattern = /^Failed to preconnect to /;

/**
 * Whether a console error from the page fails the test. `allowed` is
 * the test's allowedConsoleErrors option: one RegExp, or null.
 */
function failsTheTest(text, allowed) {
  if (failedPreconnectPattern.test(text)) return false;
  if (allowed && allowed.test(text)) return false;
  return true;
}

module.exports = { failsTheTest };
