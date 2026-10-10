import { useEffect, useRef } from "react";
import { comparer, reaction } from "mobx";
import { useLocation, useNavigate } from "react-router";

import { communityNow } from "../../helpers/helpers";
import { loadAfterBillsSaves } from "../../helpers/load_after_bills_saves";
import {
  IDLE_MS,
  pathAfterIdle,
  pathAfterNewDay,
  pathToLoadAfterIdle,
} from "../../helpers/screen_home";
import { signedIn } from "../../helpers/session";
import toastStore from "../../stores/toast_store";

// What this uses in the DataStore.
interface ScreenStore {
  // The community's day, which the store moves at the community's
  // midnight and on a wake from sleep.
  readonly communityToday: string;
  // ErrorBoundary caught a crash.
  readonly pageCrashed: boolean;
  // VersionBanner found a newer build on the server.
  readonly newVersionAvailable: boolean;
  // The wait for the bills saves on their way, before a page load.
  finishBillsSaves(): Promise<boolean>;
}

// Mouse, touch and scroll events that count as someone using the screen.
// A scroll inside an element does not bubble, so every one is caught on
// its way down to the element.
const ACTIVITY_EVENTS = [
  "mousemove",
  "mousedown",
  "click",
  "scroll",
  "touchstart",
] as const;

// A modifier key alone is not someone typing.
const MODIFIER_KEYS = ["Shift", "Control", "Alt", "Meta"];

// What a page change calls while the timer is off.
function timerOff() {}

// Brings the shared screen back to today's calendar by itself, inside
// the app, with no page load. A page load would take away every message
// on screen, read or not (#137), and a meal page's cost still waiting to
// save would be sent only on the way out of the page. A move inside the
// app keeps the messages, and leaving a meal sends its waiting costs the
// way the meal's Calendar button does (teardownMealPage, called by the
// calendar as it mounts). Two things move it (helpers/screen_home.ts
// says where to):
//
// - Nobody used the screen for IDLE_MS: no mouse, key, touch or scroll,
//   and no page change. The page load counts too, so a page loaded with
//   nobody there (Refresh after a deploy, a browser that reopens its
//   last page) goes home as well. Before, the timer started only at the
//   first touch.
// - The community's day changed while the calendar showed the old day's
//   month.
//
// Neither ever closes an open calendar form (ADR 0006), and neither
// moves a signed-out page.
//
// Two things a move inside the app cannot fix: a crashed page, whose
// error page stays when the address changes, and old code after a
// deploy. For those the timer loads today's calendar from the server
// instead, once the bills saves on their way are answered
// (pathToLoadAfterIdle says when). The crash and the new version each
// start the five minutes again, so a screen nobody uses gets the load
// five minutes later. Without that, the timer could have run out
// already, and nothing would start it until someone touched the screen.
export default function BackToToday({ store }: { store: ScreenStore }) {
  const location = useLocation();
  const navigate = useNavigate();
  // The timer and the day watcher are set up once, and read the page
  // and the router as they are when they fire.
  const pathname = useRef(location.pathname);
  pathname.current = location.pathname;
  const navigateTo = useRef(navigate);
  navigateTo.current = navigate;
  // Starts the five minutes again. Does nothing while the timer is off.
  const restart = useRef(timerOff);

  useEffect(
    function () {
      // tests/helpers/browser_setup.js turns the timer off, so the browser
      // tests are not sent home in the middle of a test.
      if (window.__COMEALS_NO_IDLE_TIMER__) return;
      let timer: ReturnType<typeof setTimeout> | undefined;
      function goHome() {
        // Today is read now, the way a click reads it: a "today" kept from
        // before can be stale after the device slept.
        const today = communityNow().format("YYYY-MM-DD");
        const load = pathToLoadAfterIdle(pathname.current, today, signedIn(), {
          crashed: store.pageCrashed,
          newVersion: store.newVersionAvailable,
          errorShown: toastStore.toasts.some((toast) => toast.type === "error"),
        });
        if (load !== null) {
          loadAfterBillsSaves(store, function () {
            window.location.assign(load);
          });
          return;
        }
        const path = pathAfterIdle(pathname.current, today, signedIn());
        if (path !== null) navigateTo.current(path);
      }
      function startAgain() {
        clearTimeout(timer);
        timer = setTimeout(goHome, IDLE_MS);
      }
      function onKeyDown(event: KeyboardEvent) {
        if (!MODIFIER_KEYS.includes(event.key)) startAgain();
      }
      const listening = { capture: true, passive: true };
      ACTIVITY_EVENTS.forEach((name) =>
        window.addEventListener(name, startAgain, listening),
      );
      window.addEventListener("keydown", onKeyDown, listening);
      restart.current = startAgain;
      return function () {
        clearTimeout(timer);
        ACTIVITY_EVENTS.forEach((name) =>
          window.removeEventListener(name, startAgain, listening),
        );
        window.removeEventListener("keydown", onKeyDown, listening);
        restart.current = timerOff;
      };
    },
    [store],
  );

  // A page change counts as activity, and the first page is the page
  // load. This runs after the effect above, which set up the timer.
  useEffect(
    function () {
      restart.current();
    },
    [location.key],
  );

  // A crash or a new version starts the five minutes again. Each flag
  // goes from false to true once.
  useEffect(
    function () {
      return reaction(
        () => [store.pageCrashed, store.newVersionAvailable],
        function () {
          restart.current();
        },
        { equals: comparer.structural },
      );
    },
    [store],
  );

  useEffect(
    function () {
      return reaction(
        () => store.communityToday,
        function (newToday, oldToday) {
          const path = pathAfterNewDay(pathname.current, oldToday, newToday);
          // In place of the old day's address: nobody went anywhere.
          if (path !== null) navigateTo.current(path, { replace: true });
        },
      );
    },
    [store],
  );

  return null;
}
