// The oldest browsers the build supports. vite.config.mjs builds the
// scripts and the styles for this list, and the browser check
// (browser_check.js) turns away browsers older than it. A test
// (tests/unit/browser_check.test.js) fails when the two disagree, so a
// change here needs a matching change to the check.
//
// This is Vite 8's own default ("baseline-widely-available",
// ESBUILD_BASELINE_WIDELY_AVAILABLE_TARGET in Vite's source), written
// out so that a Vite upgrade cannot change it without a commit here.
export const BUILD_TARGET = [
  "chrome111",
  "edge111",
  "firefox114",
  "safari16.4",
  "ios16.4",
];
