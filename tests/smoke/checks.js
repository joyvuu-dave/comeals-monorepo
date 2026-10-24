// The sign-in steps of the post-deploy smoke test (tests/smoke/smoke.js),
// apart from it so they can be tested: the resident and admin logins,
// where the admin pages are, and keeping passwords out of what it prints.
// tests/unit/smoke_checks.test.js and tests/admin/smoke_admin.spec.js
// test them.
//
// Like the rest of the smoke test, these only read. A login itself does
// write one thing: Devise records each admin sign-in (the time, the IP
// address and the count) on the admin's row. The smoke test unticks
// "Remember me", so no remember token is written, and it never signs
// out: with expire_all_remember_me_on_sign_out (config/initializers/
// devise.rb) a sign-out would end that admin's remembered sessions on
// every other device.

const RESIDENT_REFUSED =
  "smoke login refused for the resident account — update " +
  "SMOKE_EMAIL/SMOKE_PASSWORD (or RESIDENT_*) in .env and the GitHub secrets";
const ADMIN_REFUSED =
  "smoke login refused for the admin account — update " +
  "SMOKE_ADMIN_* (or ADMIN_*) in .env and the GitHub secrets";

// The admin site for a site address, the way config/routes.rb finds it:
// the "admin" subdomain of the same host (admin.comeals.com). Development
// serves admin at admin.lvh.me, a name that points at this machine, since
// localhost cannot have a subdomain. Heroku answers only the app's own
// herokuapp.com name, so staging has no admin site: null.
function adminBaseFor(base) {
  const url = new URL(base);
  if (url.hostname === "localhost" || url.hostname === "127.0.0.1") {
    url.hostname = "admin.lvh.me";
  } else if (url.hostname.endsWith(".herokuapp.com")) {
    return null;
  } else {
    url.hostname = `admin.${url.hostname.replace(/^www\./, "")}`;
  }
  return url.origin;
}

// `text` with every secret that is set replaced by [hidden]. Everything
// the smoke test prints goes through this, so a password can never reach
// a terminal, a deploy log or a GitHub Actions log, even inside an error
// message.
function redact(text, secrets) {
  let out = String(text);
  for (const secret of secrets) {
    if (secret) out = out.split(secret).join("[hidden]");
  }
  return out;
}

// Signs in on the SPA's login page, which must be open. The login is one
// POST; its answer says whether the credentials were refused (400, from
// Api::V1::ResidentsController#token), so it is tried exactly once.
async function signInResident(page, email, password) {
  await page.fill('input[aria-label="email"]', email);
  await page.fill('input[aria-label="password"]', password);
  const [response] = await Promise.all([
    page.waitForResponse(
      (r) =>
        r.url().endsWith("/api/v1/residents/token") &&
        r.request().method() === "POST",
    ),
    page.getByRole("button", { name: "Submit" }).click(),
  ]);
  if (response.status() === 400) throw new Error(RESIDENT_REFUSED);
  if (response.status() !== 200) {
    throw new Error(`the resident login answered ${response.status()}`);
  }
}

// Opens an admin page and checks it answered 200 with its title.
async function expectAdminPage(page, url, title) {
  const response = await page.goto(url);
  if (response.status() !== 200) {
    throw new Error(`${url} answered ${response.status()}`);
  }
  const shown = (await page.locator("#page_title").textContent()).trim();
  if (shown !== title) {
    throw new Error(`${url} has the title "${shown}", not "${title}"`);
  }
}

// Signs in to the admin site once, then opens the dashboard and the
// reconciliations list (money pages that only read). Returns the names
// of the checks that passed. AdminUser has no lockout (it does not use
// Devise's :lockable), and the login is tried once a run anyway.
async function checkAdmin(page, adminBase, email, password) {
  const passed = [];
  await page.goto(`${adminBase}/login`);
  await page.fill("#admin_user_email", email);
  await page.fill("#admin_user_password", password);
  await page.uncheck("#admin_user_remember_me");
  await page.click('input[type="submit"]');
  // A signed-in page has the header; a refused login shows the login
  // page again, with an alert.
  await page.locator("#header, .flash_alert").first().waitFor();
  if (await page.locator("#admin_user_password").count()) {
    throw new Error(ADMIN_REFUSED);
  }
  passed.push("admin login works");

  await expectAdminPage(page, `${adminBase}/`, "Meal Reconciliation");
  passed.push("admin dashboard renders");
  await expectAdminPage(
    page,
    `${adminBase}/reconciliations`,
    "Reconciliations",
  );
  passed.push("admin reconciliations page renders");
  return passed;
}

module.exports = {
  RESIDENT_REFUSED,
  ADMIN_REFUSED,
  adminBaseFor,
  redact,
  signInResident,
  checkAdmin,
};
