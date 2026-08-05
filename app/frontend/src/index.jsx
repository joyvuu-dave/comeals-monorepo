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
import Cookie from "js-cookie";
import { installAuthInterceptor } from "./helpers/axios_auth";
installAuthInterceptor();
import VersionBanner from "./components/app/version_banner";
import ToastContainer from "./components/app/toast_container";
import SessionExpiredBanner from "./components/app/session_expired_banner";

import {
  BrowserRouter as Router,
  Routes,
  Route,
  Navigate,
  useLocation,
} from "react-router";

import { DataStore } from "./stores/data_store";
import { clear } from "idb-keyval";

import ResidentsLogin from "./components/residents/login";
import PrivateRoute from "./components/app/private_route";

import ScrollToTop from "./components/app/scroll_to_top";
import ErrorBoundary from "./components/app/error_boundary";
import { CALENDAR_PATH, MEAL_EDIT_PATH, LOGIN_PATH } from "./routes";

function TrailingSlash() {
  var location = useLocation();
  if (!location.pathname.endsWith("/")) {
    return <Navigate to={location.pathname + "/" + location.search} replace />;
  }
  return null;
}

function lazyRetry(importFn) {
  return function () {
    return importFn().catch(function (err) {
      if (!sessionStorage.getItem("chunk_retry")) {
        sessionStorage.setItem("chunk_retry", "1");
        window.location.reload();
        return new Promise(function () {});
      }
      sessionStorage.removeItem("chunk_retry");
      throw err;
    });
  };
}

const Calendar = React.lazy(
  lazyRetry(function () {
    return import("./components/calendar/show");
  }),
);

const MealsEdit = React.lazy(
  lazyRetry(function () {
    return import("./components/meals/edit");
  }),
);

document.addEventListener("DOMContentLoaded", () => {
  // Bump this version to force-clear all cached calendar/meal data on next visit.
  // clear() is async but completes well before any user navigation
  // triggers a data load, so no race condition in practice.
  const CACHE_VERSION = "3";
  if (localStorage.getItem("cacheVersion") !== CACHE_VERSION) {
    clear();
    // Version 3 switched the cache from localforage to idb-keyval, which
    // uses its own IndexedDB database. Delete the old localforage one so
    // it does not sit on disk forever. Safe if it never existed.
    indexedDB.deleteDatabase("localforage");
    localStorage.setItem("cacheVersion", CACHE_VERSION);
  }

  const store = DataStore.create();

  window.addEventListener("load", function () {
    function updateOnlineStatus() {
      if (navigator.onLine) {
        console.warn(`back online at ${new Date().toLocaleTimeString()}`);
        store.setIsOnline(true);
        // Background tabs throttle timers, so the store's midnight timer
        // may not have fired yet; coming back online is a reliable moment
        // to roll the observable "today" forward.
        store.recomputeCommunityToday();
        // Unsaved menu text first: most save failures are network blips,
        // and coming back online is the moment to resend (issue #35).
        store.retryDirtyDescriptions();
        if (store.meal && store.meal.id) {
          store.loadDataAsync();
        }
        if (typeof Cookie.get("community_id") !== "undefined") {
          store.loadMonthAsync();
        }
      } else {
        console.warn(`offline at ${new Date().toLocaleTimeString()}`);
        store.setIsOnline(false);
      }
    }

    window.addEventListener("online", updateOnlineStatus);
    window.addEventListener("offline", updateOnlineStatus);
  });

  createRoot(document.getElementById("root")).render(
    <StoreContext.Provider value={store}>
      <ToastContainer />
      <SessionExpiredBanner />
      <Router>
        <VersionBanner />
        <TrailingSlash />
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
    </StoreContext.Provider>,
  );
  // Unregister any leftover service worker from previous deploys.
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.getRegistrations().then(function (registrations) {
      registrations.forEach(function (registration) {
        registration.unregister();
      });
    });
  }
});
