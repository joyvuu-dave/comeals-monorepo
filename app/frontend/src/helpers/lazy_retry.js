// React.lazy loads a page's code from its own file (a chunk). After a
// deploy, a page loaded before it can ask for a chunk the server no
// longer has, and the import fails. The page then reloads once, to get
// the new build. A second failure in a row is a real error, and it goes
// to the error page.
//
// The mark in sessionStorage holds the build that reloaded
// (__BUILD_ID__, vite.config.mjs). A failure in that same build is the
// second one: the reload did not help. A failure in any other build is a
// first one, because the mark was left by a reload at an earlier deploy
// that worked. The mark is not removed when a chunk loads: after a
// reload one chunk can load while another is still missing, and
// removing it there would reload the page again and again.
//
// During a deploy Heroku answers every file with its maintenance page,
// which never reloads. So the reload waits until /api/v1/version
// answers, asking every 30 seconds. The page shows "Loading..." until
// then.
const RETRY_MS = 30 * 1000;

function reloadWhenServerAnswers() {
  function tryAgainLater() {
    setTimeout(reloadWhenServerAnswers, RETRY_MS);
  }
  fetch("/api/v1/version", { cache: "no-store" }).then(function (response) {
    if (response.ok) {
      window.location.reload();
    } else {
      tryAgainLater();
    }
  }, tryAgainLater);
}

export default function lazyRetry(importFn) {
  return function () {
    return importFn().catch(function (err) {
      if (sessionStorage.getItem("chunk_retry") !== __BUILD_ID__) {
        sessionStorage.setItem("chunk_retry", __BUILD_ID__);
        reloadWhenServerAnswers();
        return new Promise(function () {});
      }
      sessionStorage.removeItem("chunk_retry");
      throw err;
    });
  };
}
