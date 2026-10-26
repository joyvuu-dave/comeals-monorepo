// The post-deploy smoke test bin/smoke runs. Plain Playwright script,
// not a test-runner suite: it drives the LIVE site, so it must be
// read-only — it never submits a form that writes, never touches a
// meal, never creates anything. The sign-in steps are in ./checks.js,
// which says what a login itself writes.
const { launchBrowser } = require("./browser");
const {
  EXIT,
  adminBaseFor,
  redact,
  signInResident,
  checkAdmin,
  unlessRefused,
  countedProblems,
  refusedReport,
} = require("./checks");

const BASE = process.env.SMOKE_URL || "https://comeals.com";
const EMAIL = process.env.SMOKE_EMAIL;
const PASSWORD = process.env.SMOKE_PASSWORD;
const ADMIN_EMAIL = process.env.SMOKE_ADMIN_EMAIL;
const ADMIN_PASSWORD = process.env.SMOKE_ADMIN_PASSWORD;
const SECRETS = [PASSWORD, ADMIN_PASSWORD];

// Every line this script prints goes through redact (./checks.js), so no
// password reaches the terminal, the deploy log or a GitHub Actions log.
const say = (text) => console.log(redact(text, SECRETS));
const sayError = (text) => console.error(redact(text, SECRETS));

// The calendar months to render when logged in: the next November
// (DST fall-back, where the shipped grid bug lived) and the next
// March (DST spring-forward). monthIndex is 0-based.
function nextOccurrence(monthIndex) {
  const now = new Date();
  const year =
    now.getMonth() >= monthIndex ? now.getFullYear() + 1 : now.getFullYear();
  const month = String(monthIndex + 1).padStart(2, "0");
  return { year, date: `${year}-${month}-15` };
}

// Renders /calendar/all/<date>/ and asserts the month's 1st sits in
// its true weekday column.
async function checkMonthGrid(page, base, monthIndex, label) {
  const { year, date } = nextOccurrence(monthIndex);
  await page.goto(`${base}/calendar/all/${date}/`);
  await page.waitForSelector(".rbc-calendar", { timeout: 15000 });
  const grid = await page.$$eval(".rbc-month-row", (rows) =>
    rows.map((row) =>
      Array.from(row.querySelectorAll(".rbc-date-cell"))
        .map(
          (c) =>
            c.textContent.trim() +
            (c.classList.contains("rbc-off-range") ? "*" : ""),
        )
        .join(" "),
    ),
  );
  const startCol = new Date(year, monthIndex, 1).getDay();
  const firstRow = grid[0].split(" ");
  const firstInRange = firstRow.findIndex((cell) => !cell.endsWith("*"));
  if (firstInRange !== startCol || firstRow[startCol] !== "01") {
    throw new Error(
      `${label} ${year} grid misaligned: row 1 is "${grid[0]}", ` +
        `expected the 01 in column ${startCol}`,
    );
  }
  return `${label} ${year} grid aligned`;
}

async function main() {
  const browser = await launchBrowser();
  const context = await browser.newContext({
    timezoneId: "America/Los_Angeles",
  });
  const page = await context.newPage();

  // Each as { text, url }: countedProblems (./checks.js) reads the url.
  const problems = [];
  page.on("pageerror", (e) =>
    problems.push({ text: `page error: ${e}`, url: "" }),
  );
  page.on("console", (m) => {
    if (m.type() === "error") {
      problems.push({
        text: `console error: ${m.text()}`,
        url: m.location().url,
      });
    }
  });
  // The logins the site refused. The rest of the smoke test still runs.
  const refusals = [];

  const checks = [];
  function pass(name) {
    checks.push(name);
    say(`  ok: ${name}`);
  }

  // 1. The API answers.
  const version = await page.request.get(`${BASE}/api/v1/version`);
  if (!version.ok()) {
    throw new Error(`/api/v1/version returned ${version.status()}`);
  }
  pass(`API answers (version ${(await version.text()).trim()})`);

  // 2. The login page renders — proves the SPA build loads and runs.
  await page.goto(`${BASE}/`, { waitUntil: "load" });
  await page.waitForSelector('input[aria-label="email"]', { timeout: 15000 });
  pass("login page renders");

  let residentRefused = false;
  if (EMAIL && PASSWORD) {
    await unlessRefused(refusals, async () => {
      // 3. Log in for real.
      await signInResident(page, EMAIL, PASSWORD);
      await page.waitForSelector(".rbc-calendar", { timeout: 15000 });
      pass("login works, calendar renders");

      // 4. Both DST months render with the 1st under its true weekday.
      pass(await checkMonthGrid(page, BASE, 10, "November"));
      pass(await checkMonthGrid(page, BASE, 2, "March"));

      // 5. The next meal's page renders.
      await page.getByRole("button", { name: "Next Meal" }).click();
      await page.waitForSelector('[aria-label="Enter meal description"]', {
        timeout: 15000,
      });
      pass("meal page renders");
    });
    residentRefused = refusals.length > 0;
  } else {
    say(
      "  note: SMOKE_EMAIL/SMOKE_PASSWORD not set — skipped the " +
        "logged-in checks (calendar, DST month, meal page)",
    );
  }

  // 6. The admin site: sign in, the dashboard, the reconciliations list.
  const adminBase = adminBaseFor(BASE);
  if (!ADMIN_EMAIL || !ADMIN_PASSWORD) {
    say(
      "  note: SMOKE_ADMIN_EMAIL/SMOKE_ADMIN_PASSWORD not set — skipped " +
        "the admin checks",
    );
  } else if (!adminBase) {
    say(`  note: ${BASE} has no admin site — skipped the admin checks`);
  } else {
    const passed = await unlessRefused(refusals, () =>
      checkAdmin(page, adminBase, ADMIN_EMAIL, ADMIN_PASSWORD),
    );
    passed.forEach(pass);
  }

  await browser.close();

  // Nothing is expected on these pages, except the browser's own line for
  // a refused resident login (countedProblems).
  const counted = countedProblems(problems, residentRefused);
  if (counted.length) {
    sayError("Console/page errors during smoke:");
    counted.forEach((p) => sayError(`  ${p}`));
    throw new Error(`${counted.length} console/page error(s)`);
  }

  if (refusals.length) {
    refusedReport(BASE, refusals).forEach(sayError);
    process.exit(EXIT.loginRefused);
  }
  say(`Smoke passed: ${checks.length} check(s) against ${BASE}`);
}

main().catch((error) => {
  sayError(`SMOKE FAILED against ${BASE}: ${error.message || error}`);
  process.exit(EXIT.broken);
});
