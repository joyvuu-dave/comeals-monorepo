import { notifyError } from "./bugsnag";
import { waitAfterCrash } from "./crash_reload_wait";
import {
  CRASH_ADVICE,
  CRASH_BUTTON_STYLE,
  CRASH_CONTAINER_STYLE,
  CRASH_EMAIL,
  CRASH_TITLE,
} from "./crash_page";

// A crash while the page starts, before React draws anything (index.jsx).
// OuterErrorBoundary covers only what React draws, so such a crash left
// the root empty, and a shared screen stayed blank until someone came
// and reloaded it (#162). This draws the crash page in plain HTML,
// because React or the store may be what broke, reports the error, and
// loads "/" after the same wait as a crash inside React.
//
// There are no cost saves to send first: the store is made during the
// start-up, so no cost can have been typed yet.
export function showBootCrash(root: HTMLElement, error: unknown): void {
  console.error("The page crashed while it started:", error);
  // A caught error never reaches Bugsnag's own handlers.
  notifyError(error);

  const page = document.createElement("div");
  Object.assign(page.style, CRASH_CONTAINER_STYLE);

  const title = document.createElement("h2");
  title.textContent = CRASH_TITLE;

  const advice = document.createElement("p");
  const email = document.createElement("a");
  email.href = `mailto:${CRASH_EMAIL}`;
  email.textContent = CRASH_EMAIL;
  advice.append(`${CRASH_ADVICE} `, email, ".");

  const refresh = document.createElement("button");
  Object.assign(refresh.style, CRASH_BUTTON_STYLE);
  refresh.textContent = "Refresh";
  refresh.addEventListener("click", function () {
    window.location.reload();
  });

  page.append(title, advice, refresh);
  root.replaceChildren(page);

  setTimeout(function () {
    window.location.assign("/");
  }, waitAfterCrash());
}
