// During a deploy Heroku answers every request with its maintenance page
// (an HTML 503), and that page never reloads itself. So a page that is
// about to load itself from the server first asks the server for its
// version, again every RETRY_MS while the answer is not ok or does not
// come, and runs `then` once the answer is ok. lazy_retry.ts and
// components/app/back_to_today.tsx use it.
const RETRY_MS = 30 * 1000;

export function whenServerAnswers(then: () => void): void {
  function tryAgainLater(): void {
    setTimeout(function () {
      whenServerAnswers(then);
    }, RETRY_MS);
  }
  fetch("/api/v1/version", { cache: "no-store" }).then(function (response) {
    if (response.ok) {
      then();
    } else {
      tryAgainLater();
    }
  }, tryAgainLater);
}
