import Bugsnag from "@bugsnag/js";
import { pageSetting } from "./page_settings";

// Browser-side error tracking, reporting to the same Bugsnag project as
// Rails. One project, both halves of the app.
//
// Two conditions must both hold before anything starts:
//
//   the key is present   the page carries one only when Rails sends it in
//                        production (app/services/page_settings.rb), so a
//                        local checkout has no key and does nothing.
//   the build is prod    import.meta.env.PROD is false under `vite dev`
//                        and under vitest, so neither reports. This is the
//                        check that stops reports if the key ever does end
//                        up in a local .env.
//
// The key is in the page, so anyone can read it, and that is fine. That is
// how every browser error tracker works — the key identifies the project
// to send to, it does not grant access to read anything. It is read from
// the page, not built into the JavaScript, because the Deploy workflow
// builds on staging, which has no key (#257).
//
// Bugsnag.start() installs handlers for window.onerror and
// unhandledrejection by itself, which covers most of what breaks. The
// React render path is the gap: React catches those and hands them to the
// nearest error boundary instead of letting them reach window.onerror, so
// components/app/error_boundary.jsx (around the pages) and
// components/app/outer_error_boundary.tsx (around the whole app) report
// them through notifyError.

let started = false;

export function startBugsnag() {
  if (started) return false;
  const apiKey = pageSetting("comeals-bugsnag-api-key");
  if (!apiKey) return false;
  if (!import.meta.env.PROD) return false;

  Bugsnag.start({
    apiKey: apiKey,
    releaseStage: "production",
    enabledReleaseStages: ["production"],
  });
  started = true;
  return true;
}

// Report an error we caught ourselves. Does nothing when Bugsnag never
// started, because calling notify before start only logs a warning to the
// console and drops the error.
export function notifyError(error, metadata) {
  if (!started) return false;

  Bugsnag.notify(error, function (event) {
    if (metadata) {
      event.addMetadata("react", metadata);
    }
  });
  return true;
}
