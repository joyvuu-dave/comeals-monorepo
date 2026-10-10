// How long a crashed page waits before it loads itself again.
//
// Two parts of the page catch a crash and then load the page by
// themselves after a wait: ErrorBoundary, around the pages, through the
// idle timer (components/app/back_to_today.tsx), and OuterErrorBoundary,
// around the whole app. If the page crashes every time it loads, a fixed
// five minutes would load it again every five minutes all day, and
// report the same crash each time. So the wait grows with each crash,
// when the crashes come one after another: 5 minutes, then 10, 20, 40,
// and at most 60.
//
// The count is kept in sessionStorage, because a crash is followed by a
// page load, and sessionStorage keeps its values through a load in the
// same tab. It starts again once a page has run an hour without a crash
// (forgetCrashesAfterAnHourWithout). If the browser refuses
// sessionStorage, or it holds something that is not a count, the page
// cannot tell whether it keeps crashing, so it waits the longest time.

const MINUTE = 60 * 1000;

// The wait after the first crash, the second one after it, and so on.
// The last one is the wait for every crash after that.
const WAITS = [5, 10, 20, 40, 60].map((minutes) => minutes * MINUTE);
// The longest wait. The store also uses it for a crash noted with no
// usable wait (stores/data_store_app.js).
export const LONGEST_CRASH_WAIT_MS = WAITS[WAITS.length - 1];

// How long a page must run without a crash before the count starts
// again.
const HOUR_WITHOUT_CRASH_MS = 60 * MINUTE;

const KEY = "crashReloads";

// The timer that starts the count again, while this page has not
// crashed.
let forgetTimer: ReturnType<typeof setTimeout> | undefined;

// Notes a crash of this page, and answers how long to wait before the
// page loads itself again. Never throws: the page has already crashed.
export function waitAfterCrash(): number {
  // This page has crashed, so it will not run an hour without one.
  clearTimeout(forgetTimer);
  forgetTimer = undefined;
  try {
    const count = Number(window.sessionStorage.getItem(KEY) ?? "0");
    if (!Number.isInteger(count) || count < 0) return LONGEST_CRASH_WAIT_MS;
    // The count stops at the last wait, so it stays small.
    window.sessionStorage.setItem(
      KEY,
      String(Math.min(count + 1, WAITS.length - 1)),
    );
    return WAITS[Math.min(count, WAITS.length - 1)];
  } catch {
    return LONGEST_CRASH_WAIT_MS;
  }
}

// Called once when the page starts (index.jsx). If the page runs an
// hour without a crash, the crashes before it are forgotten, and the
// next crash waits five minutes again.
export function forgetCrashesAfterAnHourWithout(): void {
  clearTimeout(forgetTimer);
  forgetTimer = setTimeout(function () {
    forgetTimer = undefined;
    try {
      window.sessionStorage.removeItem(KEY);
    } catch {
      // Nothing to forget: the count could not be kept either.
    }
  }, HOUR_WITHOUT_CRASH_MS);
}
