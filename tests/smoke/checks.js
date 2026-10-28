// The sign-in steps of the post-deploy smoke test (tests/smoke/smoke.js),
// apart from it so they can be tested: the resident and admin logins,
// where the admin pages are, keeping passwords out of what it prints, and
// how a refused login ends the run.
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

// bin/smoke's exit codes. The top of bin/smoke says what each one means,
// and bin/deploy, the Deploy and Rollback workflows and
// bin/staging-rehearsal act on them.
const EXIT = Object.freeze({ passed: 0, broken: 1, loginRefused: 2 });

// A login the site answered and refused: the site works, and the smoke
// credentials are wrong. Any other error means the site is broken.
class LoginRefused extends Error {
  constructor(message) {
    super(message);
    this.name = "LoginRefused";
  }
}

function refused(account, reason, names) {
  return (
    `the site refused the ${account} login (${reason}) — check ${names} ` +
    "in .env and the GitHub secrets"
  );
}
const RESIDENT_NAMES = "SMOKE_EMAIL/SMOKE_PASSWORD (or RESIDENT_*)";
const RESIDENT_WRONG_PASSWORD = refused(
  "resident",
  "it says the password is wrong",
  RESIDENT_NAMES,
);
const RESIDENT_UNKNOWN_EMAIL = refused(
  "resident",
  "it has no resident with that email",
  RESIDENT_NAMES,
);
const ADMIN_REFUSED = refused(
  "admin",
  "it says the email or the password is wrong",
  "SMOKE_ADMIN_* (or ADMIN_*)",
);

// Devise's words for a wrong email and for a wrong password
// (config/locales/devise.en.yml, invalid and not_found_in_database, with
// the field name "email" filled in).
// tests/admin/smoke_admin.spec.js checks them against the real server.
const ADMIN_REFUSED_ALERT = "Invalid email or password.";

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

// What is wrong with the keys in the page, or null. Rails writes them as
// it sends the page (app/services/page_settings.rb), one <meta> tag each,
// so a page with a tag missing or twice did not come from Rails. The
// real site must carry a Pusher key, or open screens never update by
// themselves (#257). Staging (herokuapp.com) sends no Pusher key on
// purpose, and a server on this machine may have none, so only the tags
// are checked there. `tags` is each tag's name and content.
//
// A page with no tags at all is from a release before #257, which built
// its keys into the JavaScript: production before this change, and
// production after a rollback to such a release. That is not a problem
// here, so pageKeysOlderRelease says so and the check passes.
const PAGE_KEYS = [
  "comeals-pusher-key",
  "comeals-pusher-cluster",
  "comeals-bugsnag-api-key",
];

function pageKeysOlderRelease(tags) {
  return tags.length === 0;
}

function pageKeysProblem(base, tags) {
  if (pageKeysOlderRelease(tags)) return null;
  for (const name of PAGE_KEYS) {
    const count = tags.filter((tag) => tag.name === name).length;
    if (count !== 1) return `the page has ${count} ${name} tag(s), not 1`;
  }
  const { hostname } = new URL(base);
  const realSite =
    hostname !== "localhost" &&
    hostname !== "127.0.0.1" &&
    !hostname.endsWith(".herokuapp.com");
  const pusherKey = tags.find((tag) => tag.name === "comeals-pusher-key");
  if (realSite && !pusherKey.content) {
    return "the page has no Pusher key, so screens will not update by themselves";
  }
  return null;
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
// POST, tried exactly once. Api::V1::ResidentsController#token answers
// 400 with "Incorrect password" for a wrong password and "No resident
// with email <email>" for an unknown email (both pinned in
// spec/requests/api/v1/residents_controller_spec.rb); only those two are
// a refused login. Rails also answers 400 for a request it cannot read,
// and that is a broken site. The second message names the email, so it
// is never printed.
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
  if (response.status() === 200) return;
  if (response.status() === 400) {
    const { message } = await response.json().catch(() => ({}));
    if (message === "Incorrect password") {
      throw new LoginRefused(RESIDENT_WRONG_PASSWORD);
    }
    if (String(message).startsWith("No resident with email ")) {
      throw new LoginRefused(RESIDENT_UNKNOWN_EMAIL);
    }
  }
  throw new Error(`the resident login answered ${response.status()}`);
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
  // page again, with an alert. The login page can also come back with
  // another alert ("You need to sign in before continuing.") when the
  // sign-in worked but the next page did not keep it, a broken session
  // cookie, say. Then no admin can sign in: the site is broken.
  await page.locator("#header, .flash_alert").first().waitFor();
  if (await page.locator("#admin_user_password").count()) {
    const alert = (
      await page.locator(".flash_alert").first().textContent()
    ).trim();
    if (alert === ADMIN_REFUSED_ALERT) throw new LoginRefused(ADMIN_REFUSED);
    throw new Error(
      `the admin login page came back with "${alert}" — the site did not ` +
        "keep the sign-in",
    );
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

// Runs a sign-in and the checks behind it, and returns the names of the
// checks that passed. A refused login is noted in `refusals` and ends only
// these checks: the rest of the smoke test still runs, so a refused
// resident login cannot hide a broken admin site. Any other failure goes
// through.
async function unlessRefused(refusals, run) {
  try {
    return await run();
  } catch (error) {
    if (!(error instanceof LoginRefused)) throw error;
    refusals.push(error.message);
    return [];
  }
}

// The text of each console or page error that counts. `problems` holds
// { text, url }, url being the line's location. The browser logs the
// answer of a refused resident login itself ("Failed to load resource:
// ... status of 400"), with the token address as its location. When that
// login was refused, that line is the refusal, not a second problem.
function countedProblems(problems, residentRefused) {
  return problems
    .filter(
      (p) =>
        !(
          residentRefused &&
          p.url.endsWith("/api/v1/residents/token") &&
          p.text.includes("Failed to load resource") &&
          p.text.includes("status of 400")
        ),
    )
    .map((p) => p.text);
}

// What bin/smoke prints last when a login was refused and nothing else
// failed.
function refusedReport(base, refusals) {
  return [
    `SMOKE LOGIN REFUSED against ${base}:`,
    ...refusals.map((r) => `  ${r}`),
    "The site answered, and every check that could run passed, but it " +
      "refused a login, so the checks behind that login did not run. " +
      "This is not a pass. Check the SMOKE_* credentials. If they are " +
      "right, sign in by hand: if that fails too, the site is broken.",
  ];
}

module.exports = {
  EXIT,
  LoginRefused,
  RESIDENT_WRONG_PASSWORD,
  RESIDENT_UNKNOWN_EMAIL,
  ADMIN_REFUSED,
  adminBaseFor,
  pageKeysOlderRelease,
  pageKeysProblem,
  redact,
  signInResident,
  checkAdmin,
  unlessRefused,
  countedProblems,
  refusedReport,
};
