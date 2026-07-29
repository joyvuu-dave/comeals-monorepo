import Bugsnag from "@bugsnag/js";

// Browser-side error tracking, reporting to the same Bugsnag project as
// Rails. One project, both halves of the app.
//
// Two conditions must both hold before anything starts:
//
//   the key is present   VITE_BUGSNAG_API_KEY is set on Heroku and nowhere
//                        else, so a local checkout has no key and does
//                        nothing.
//   the build is prod    import.meta.env.PROD is false under `vite dev`
//                        and under vitest, so neither reports. This is the
//                        one that matters if the key ever does end up in a
//                        local .env.
//
// The key is baked into the JavaScript bundle at build time and is public.
// That is how every browser error tracker works — the key identifies the
// project to send to, it does not grant access to read anything.
//
// Bugsnag.start() installs handlers for window.onerror and
// unhandledrejection by itself, which covers most of what breaks. The
// React render path is the gap: React catches those and hands them to the
// nearest error boundary instead of letting them reach window.onerror, so
// components/app/error_boundary.jsx reports them through notifyError.

const apiKey = import.meta.env.VITE_BUGSNAG_API_KEY;

let started = false;

export function startBugsnag() {
  if (started) return false;
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
