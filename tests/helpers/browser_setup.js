/**
 * Page setup that both browser suites share: the mocked e2e suite
 * (setup.js) and the real-backend integration suite
 * (integration_setup.js). One copy, so a fix here reaches both.
 */

/**
 * Turn off the idle timer (app/frontend/src/components/app/
 * back_to_today.tsx), which sends the screen to today's calendar five
 * minutes after the page loads or changes, or after the last mouse,
 * key, scroll or touch event. Call it before the first goto: the timer
 * reads the flag once, when the app starts. It does not turn off the
 * move to the new month at the community's midnight.
 * tests/integration/idle-timer.spec.js checks the flag and the timer.
 */
async function disableIdleTimer(page) {
  await page.addInitScript(() => {
    window.__COMEALS_NO_IDLE_TIMER__ = true;
  });
}

/**
 * Empty the app's browser caches, so the next load can show only what
 * the server sends. The meal page and the calendar keep a copy of what
 * they last loaded in IndexedDB and draw that copy before the server
 * answers. The app uses idb-keyval's default store: database
 * "keyval-store", object store "keyval". sessionStorage holds the
 * chunk-retry flag.
 *
 * Call it on a page that has loaded the app. It fails if the database
 * is missing, because then the app keeps its cache somewhere else and
 * this helper would be clearing nothing.
 */
async function clearStorage(page) {
  const left = await page.evaluate(async () => {
    window.sessionStorage.clear();
    const names = (await window.indexedDB.databases()).map((db) => db.name);
    if (!names.includes("keyval-store")) {
      throw new Error(
        `clearStorage: no "keyval-store" database (found: ${names.join(", ")})`,
      );
    }
    return new Promise((resolve, reject) => {
      const open = window.indexedDB.open("keyval-store");
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction("keyval", "readwrite");
        const store = tx.objectStore("keyval");
        store.clear();
        const count = store.count();
        tx.oncomplete = () => {
          db.close();
          resolve(count.result);
        };
        tx.onerror = () => {
          db.close();
          reject(tx.error);
        };
      };
    });
  });
  if (left !== 0) {
    throw new Error(`clearStorage: ${left} cached entries are still there`);
  }
}

module.exports = { disableIdleTimer, clearStorage };
