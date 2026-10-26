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
// never reloads itself. So the page reloads only once the server answers
// (when_server_answers.ts). Meanwhile the page keeps showing its
// "Loading..." words (the Suspense fallback).
//
// A browser set to block site data throws on any use of sessionStorage
// (#162), and one that is out of space throws on a write. Then the page
// cannot remember that it reloaded, so a reload could not tell the first
// failure from the second, and a file that stays missing would reload
// the page over and over. So when the flag cannot be read or written,
// the page counts the failure as the second one: no reload, and the
// chunk's own error goes on. The storage error is never thrown.
//
// `beforeReload` runs just before the reload. The reload ends every
// request on its way, and WebKit ends them as soon as it starts, before
// the page fires pagehide. index.jsx hands the bills saves on their way
// to the browser there (#150).

import { whenServerAnswers } from "./when_server_answers";

// One id per production build (vite.config.mjs).
declare const __BUILD_ID__: string;

const FLAG = "chunk_retry";

// True when this is the first failure in this build and the flag that
// says so is saved, so the page may reload. False when the page already
// reloaded in this build, or when sessionStorage cannot be used.
function firstFailureSaved(): boolean {
  try {
    if (window.sessionStorage.getItem(FLAG) === __BUILD_ID__) {
      window.sessionStorage.removeItem(FLAG);
      return false;
    }
    window.sessionStorage.setItem(FLAG, __BUILD_ID__);
    return true;
  } catch (error) {
    console.warn("This browser refuses sessionStorage:", error);
    return false;
  }
}

export function lazyRetry<T>(
  importFn: () => Promise<T>,
  beforeReload: () => void,
): () => Promise<T> {
  return function () {
    return importFn().catch(function (err: unknown) {
      if (firstFailureSaved()) {
        whenServerAnswers(function () {
          beforeReload();
          window.location.reload();
        });
        return new Promise<T>(function () {});
      }
      throw err;
    });
  };
}
