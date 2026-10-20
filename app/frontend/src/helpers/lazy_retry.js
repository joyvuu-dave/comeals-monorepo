// React.lazy loads a page's code from its own file (a chunk). After a
// deploy, a page loaded before it can ask for a chunk the server no
// longer has, and the import fails. The page then reloads once, to get
// the new build. A second failure in a row is a real error, and it goes
// to the error page.
//
// The mark is cleared when an import works, so a tab that reloaded at one
// deploy can reload again at the next.
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
    return importFn().then(
      function (chunk) {
        sessionStorage.removeItem("chunk_retry");
        return chunk;
      },
      function (err) {
        if (!sessionStorage.getItem("chunk_retry")) {
          sessionStorage.setItem("chunk_retry", "1");
          reloadWhenServerAnswers();
          return new Promise(function () {});
        }
        sessionStorage.removeItem("chunk_retry");
        throw err;
      },
    );
  };
}
