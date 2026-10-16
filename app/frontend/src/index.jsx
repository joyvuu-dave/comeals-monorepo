import "./styles.css";
// Installs the window.onerror and unhandledrejection handlers. This runs
// after every import in this file has been evaluated, because imports are
// hoisted — so an error thrown while a module is still being evaluated is
// not caught. Everything after startup is, which is where the errors we
// care about happen.
import { startBugsnag } from "./helpers/bugsnag";
startBugsnag();

import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import timezone from "dayjs/plugin/timezone";
import advancedFormat from "dayjs/plugin/advancedFormat";
import relativeTime from "dayjs/plugin/relativeTime";
dayjs.extend(utc);
dayjs.extend(timezone);
dayjs.extend(advancedFormat);
dayjs.extend(relativeTime);

import React, { Suspense } from "react";
import { createRoot } from "react-dom/client";
import { StoreContext } from "./helpers/store_context";
import { setLivelinessChecking } from "mobx-state-tree";

// React 19 dev mode iterates over all component props for DevTools diffing
// (addObjectDiffToProperties), which reads properties on detached MST nodes.
// This is harmless and doesn't occur in production builds.
// See: https://github.com/mobxjs/mobx-state-tree/issues/2279
if (import.meta.env.DEV) {
  setLivelinessChecking("ignore");
}
import { installAuthInterceptor } from "./helpers/axios_auth";
installAuthInterceptor();
import VersionBanner from "./components/app/version_banner";
import ToastContainer from "./components/app/toast_container";
import SessionExpiredBanner from "./components/app/session_expired_banner";
import BackToToday from "./components/app/back_to_today";

import {
  BrowserRouter as Router,
  Routes,
  Route,
  Navigate,
  useLocation,
  matchPath,
} from "react-router";

import { DataStore } from "./stores/data_store";
import { sendBillsOnPageClose } from "./helpers/send_bills_on_page_close";
import { communityId } from "./helpers/session";
import { lazyRetry } from "./helpers/lazy_retry";
import { prefetchMonth } from "./stores/month_fetch";
import { clear } from "idb-keyval";

import ResidentsLogin from "./components/residents/login";
import PrivateRoute from "./components/app/private_route";

import ScrollToTop from "./components/app/scroll_to_top";
import ErrorBoundary from "./components/app/error_boundary";
import OuterErrorBoundary from "./components/app/outer_error_boundary";
import { forgetCrashesAfterAnHourWithout } from "./helpers/crash_reload_wait";
import { showBootCrash } from "./helpers/boot_crash";
import { CALENDAR_PATH, MEAL_EDIT_PATH, LOGIN_PATH } from "./routes";

function TrailingSlash() {
  var location = useLocation();
  if (!location.pathname.endsWith("/")) {
    return <Navigate to={location.pathname + "/" + location.search} replace />;
  }
  return null;
}

// The store, once the page has made it (below). A page's code is only
// asked for after the page renders, so it is there by then.
let appStore = null;

// The reload after a page's code fails to load ends every bills save on
// its way, so each one is sent again with keepalive first (#150).
function sendBillsBeforeChunkReload() {
  appStore.sendBillsAgainBeforeClose();
}

const Calendar = React.lazy(
  lazyRetry(function () {
    return import("./components/calendar/show");
  }, sendBillsBeforeChunkReload),
);

const MealsEdit = React.lazy(
  lazyRetry(function () {
    return import("./components/meals/edit");
  }, sendBillsBeforeChunkReload),
);

// Clear all cached calendar/meal data the first time a browser loads
// a new build. A deploy can change any cached payload — the Aug 2026
// migration that darkened rotation red did, and every stale month
// then flashed the old color before revalidation replaced it — and
// nothing else tells a browser its copies are stale: Pusher only
// covers the month on screen and its two neighbors. Keying on the
// build id (vite.config.mjs bakes one into each production build)
// makes this automatic; it used to be a hand-bumped constant, and
// the hand forgot. clear() is async but completes well before any
// user navigation triggers a data load, so no race in practice.
function clearCachesForNewBuild() {
  const CACHE_VERSION = __BUILD_ID__;
  // A browser set to block site data throws on any use of localStorage.
  // The device's copies then cannot be checked, and the app starts
  // without the check: nothing else uses localStorage, and sign-in uses
  // a cookie (#162).
  let seen;
  try {
    seen = localStorage.getItem("cacheVersion");
  } catch (error) {
    console.warn("This browser blocks localStorage:", error);
    return;
  }
  if (seen !== CACHE_VERSION) {
    clear();
    // Cache version 3 (2026) switched from localforage to idb-keyval,
    // which uses its own IndexedDB database. Delete the old localforage
    // one so it does not sit on disk forever. Safe if it never existed,
    // so it can run again on every version change.
    indexedDB.deleteDatabase("localforage");
    localStorage.setItem("cacheVersion", CACHE_VERSION);
  }
}

document.addEventListener("DOMContentLoaded", () => {
  try {
    startApp();
  } catch (error) {
    showBootCrash(document.getElementById("root"), error);
  }
});

function startApp() {
  clearCachesForNewBuild();

  const store = DataStore.create();
  appStore = store;
  // A cost still in its row's wait, or a bills save on its way, is
  // handed to the browser when the page is hidden or closed (#150).
  sendBillsOnPageClose(store);

  // Landing on the calendar: start the month data download now, in
  // parallel with the calendar chunk (preloaded from index.html).
  // Without this the fetch only starts after the chunk loads and the
  // calendar mounts. The mount's own goToMonth then finds the month
  // cached, or adopts the still-in-flight request — see revalidate in
  // stores/month_fetch.js — instead of starting the download from zero.
  // Matched against CALENDAR_PATH itself, not a hand-written copy of it.
  // A copy would stop matching after a route change, and then the
  // prefetch would stop running with no error.
  // The store is made above, so it hears the zone this prefetch's
  // answer carries (onServerZone in stores/month_fetch.js).
  const calendarBoot = matchPath(CALENDAR_PATH, window.location.pathname);
  if (calendarBoot && communityId() !== null) {
    prefetchMonth(calendarBoot.params.date);
  }

  window.addEventListener("load", function () {
    function updateOnlineStatus() {
      if (navigator.onLine) {
        console.warn(`back online at ${new Date().toLocaleTimeString()}`);
        store.setIsOnline(true);
        // The same recovery the Pusher reconnect runs — one path for
        // both wake-up signals.
        store.handleReconnect();
      } else {
        console.warn(`offline at ${new Date().toLocaleTimeString()}`);
        store.setIsOnline(false);
      }
    }

    window.addEventListener("online", updateOnlineStatus);
    window.addEventListener("offline", updateOnlineStatus);
  });

  // A page that runs an hour without a crash forgets the crashes before
  // it, so the next crash waits five minutes again before the page
  // loads itself (helpers/crash_reload_wait.ts).
  forgetCrashesAfterAnHourWithout();

  // OuterErrorBoundary is around everything, because a crash outside
  // ErrorBoundary (the message stack, the banners, the idle timer) took
  // the whole page away and left the shared screen blank. It reads
  // nothing from the store, which may be what broke. It only asks the
  // store to send the cost saves that wait before it loads the page.
  createRoot(document.getElementById("root")).render(
    <OuterErrorBoundary
      sendWaitingSaves={function () {
        return store.finishBillsSaves();
      }}
    >
      <StoreContext.Provider value={store}>
        <ToastContainer />
        <SessionExpiredBanner />
        <Router>
          <VersionBanner />
          <TrailingSlash />
          <BackToToday store={store} />
          <ScrollToTop>
            <main>
              <Suspense fallback={<h3>Loading...</h3>}>
                <ErrorBoundary>
                  <Routes>
                    <Route
                      path={CALENDAR_PATH}
                      element={
                        <PrivateRoute>
                          <Calendar />
                        </PrivateRoute>
                      }
                    />
                    <Route
                      path={MEAL_EDIT_PATH}
                      element={
                        <PrivateRoute>
                          <MealsEdit />
                        </PrivateRoute>
                      }
                    />
                    <Route path={LOGIN_PATH} element={<ResidentsLogin />} />
                  </Routes>
                </ErrorBoundary>
              </Suspense>
            </main>
          </ScrollToTop>
        </Router>
      </StoreContext.Provider>
    </OuterErrorBoundary>,
  );
  // Unregister any leftover service worker from previous deploys.
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.getRegistrations().then(function (registrations) {
      registrations.forEach(function (registration) {
        registration.unregister();
      });
    });
  }
}
