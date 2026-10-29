// What the browser check in index.html found (app/frontend/
// browser_check.js). It runs before the app and leaves its answer on
// window.comealsBrowserCheck.
//
// True only when the check turned this browser away. It has then drawn
// its message in the root, so the app must not start and draw over it,
// and must not send error reports from a browser it knows cannot run
// the app. "error" means the check itself broke, which says nothing
// about the browser, so the app starts. No answer at all means the
// check did not run (a unit test, or a page built without it), and the
// app starts too.
export function browserTurnedAway(): boolean {
  return window.comealsBrowserCheck?.result === "failed";
}

// Tells the browser check the app has started. Until then the check
// shows a message for an error thrown while the page starts, which the
// app's own error handling cannot catch (#253).
export function markAppStarted(): void {
  if (window.comealsBrowserCheck) window.comealsBrowserCheck.appStarted = true;
}
