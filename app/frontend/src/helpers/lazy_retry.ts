// React.lazy loads a page's code from its own file (a chunk). After a
// deploy, a page loaded before it can ask for a chunk the server no
// longer has, and the import fails. The page then reloads once, to get
// the new build. A second failure in the same build is a real error, and
// it goes to the error page.
//
// The flag in sessionStorage holds the build that reloaded. A failure
// in that same build is the second one: the reload did not help. A
// failure in any other build is a first one, because the flag was left
// by a reload at an earlier deploy that worked. The flag is not removed
// when a chunk loads: after a reload, one chunk can load while another
// is still missing, and removing it there would reload the page again
// and again.
//
// During a deploy Heroku answers every file with its maintenance page
// (an HTML 503), so a reload at once would land on that page, which
// never reloads itself. So the page first asks the server for its
// version, again every RETRY_MS while the answer is not ok or does not
// come, and reloads once it is ok. Meanwhile the page keeps showing its
// "Loading..." words (the Suspense fallback).
//
// `beforeReload` runs just before the reload. The reload ends every
// request on its way, and WebKit ends them as soon as it starts, before
// the page fires pagehide. index.jsx hands the bills saves on their way
// to the browser there (#150).

// One id per production build (vite.config.mjs).
declare const __BUILD_ID__: string;

const RETRY_MS = 30 * 1000;

function reloadWhenServerAnswers(beforeReload: () => void): void {
  function tryAgainLater(): void {
    setTimeout(function () {
      reloadWhenServerAnswers(beforeReload);
    }, RETRY_MS);
  }
  fetch("/api/v1/version", { cache: "no-store" }).then(function (response) {
    if (response.ok) {
      beforeReload();
      window.location.reload();
    } else {
      tryAgainLater();
    }
  }, tryAgainLater);
}

export function lazyRetry<T>(
  importFn: () => Promise<T>,
  beforeReload: () => void,
): () => Promise<T> {
  return function () {
    return importFn().catch(function (err: unknown) {
      if (sessionStorage.getItem("chunk_retry") !== __BUILD_ID__) {
        sessionStorage.setItem("chunk_retry", __BUILD_ID__);
        reloadWhenServerAnswers(beforeReload);
        return new Promise<T>(function () {});
      }
      sessionStorage.removeItem("chunk_retry");
      throw err;
    });
  };
}
