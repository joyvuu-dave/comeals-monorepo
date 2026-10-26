// The browser the post-deploy smoke test (tests/smoke/smoke.js) drives.
//
// On a laptop it is Playwright's own Chromium, which bin/deploy installs.
// In the Deploy and Rollback workflows SMOKE_BROWSER_CHANNEL is "chrome":
// the Google Chrome that GitHub's Ubuntu runner image already has, with
// every library it needs. Playwright's Chromium needs system packages
// from Ubuntu's mirror there (--with-deps), and on a slow mirror that
// install ran out of time after a rollback, so nobody tested the site
// (#251).
//
// Run directly (node tests/smoke/browser.js), it starts that browser,
// opens a blank page and closes it. The workflows do this before they
// change anything, so a browser that does not start stops the run then.
const { chromium } = require("@playwright/test");

// The options for chromium.launch: a channel only when one is set.
function launchOptions(env) {
  const channel = env.SMOKE_BROWSER_CHANNEL;
  return channel ? { channel } : {};
}

function launchBrowser(env = process.env) {
  return chromium.launch(launchOptions(env));
}

async function checkBrowserStarts() {
  const channel = process.env.SMOKE_BROWSER_CHANNEL;
  const name = channel ? `Playwright channel "${channel}"` : "Chromium";
  const browser = await launchBrowser();
  const page = await browser.newPage();
  await page.close();
  console.log(`The smoke test's browser starts: ${name} ${browser.version()}`);
  await browser.close();
}

if (require.main === module) {
  checkBrowserStarts().catch((error) => {
    console.error(
      `The smoke test's browser did not start: ${error.message || error}`,
    );
    process.exit(1);
  });
}

module.exports = { launchOptions, launchBrowser };
