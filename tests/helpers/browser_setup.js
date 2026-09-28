/**
 * Page setup that both browser suites share: the mocked e2e suite
 * (setup.js) and the real-backend integration suite
 * (integration_setup.js). One copy, so a fix here reaches both.
 */

/**
 * Turn off the idle timer in app/frontend/index.html, which sends the
 * page to "/" after 5 minutes with no mouse, key, scroll or touch
 * event. Call it before the first goto.
 *
 * The timer returns at once when this flag is set. Replacing
 * window.idleTimer with a stub does not work: index.html declares
 * `function idleTimer()` in a plain script, and that declaration
 * replaces the stub before the call on the next line runs (#118).
 * tests/integration/idle-timer.spec.js checks the flag and the timer.
 */
async function disableIdleTimer(page) {
  await page.addInitScript(() => {
    window.__COMEALS_NO_IDLE_TIMER__ = true;
  });
}

module.exports = { disableIdleTimer };
