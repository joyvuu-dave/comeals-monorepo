// The post-deploy smoke test bin/smoke runs. Plain Playwright script,
// not a test-runner suite: it drives the LIVE site, so it must be
// read-only — it never submits a form that writes, never touches a
// meal, never creates anything.
const { chromium } = require("@playwright/test");

const BASE = process.env.SMOKE_URL || "https://comeals.com";
const EMAIL = process.env.SMOKE_EMAIL;
const PASSWORD = process.env.SMOKE_PASSWORD;

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
  const browser = await chromium.launch();
  const context = await browser.newContext({
    timezoneId: "America/Los_Angeles",
  });
  const page = await context.newPage();

  const problems = [];
  page.on("pageerror", (e) => problems.push(`page error: ${e}`));
  page.on("console", (m) => {
    if (m.type() === "error") problems.push(`console error: ${m.text()}`);
  });

  const checks = [];
  function pass(name) {
    checks.push(name);
    console.log(`  ok: ${name}`);
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

  if (EMAIL && PASSWORD) {
    // 3. Log in for real.
    await page.fill('input[aria-label="email"]', EMAIL);
    await page.fill('input[aria-label="password"]', PASSWORD);
    await page.getByRole("button", { name: "Submit" }).click();
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
  } else {
    console.log(
      "  note: SMOKE_EMAIL/SMOKE_PASSWORD not set — skipped the " +
        "logged-in checks (calendar, DST month, meal page)",
    );
  }

  await browser.close();

  // Filter expected noise: nothing is expected on these pages.
  if (problems.length) {
    console.error("Console/page errors during smoke:");
    problems.forEach((p) => console.error(`  ${p}`));
    throw new Error(`${problems.length} console/page error(s)`);
  }

  console.log(`Smoke passed: ${checks.length} check(s) against ${BASE}`);
}

main().catch((error) => {
  console.error(`SMOKE FAILED against ${BASE}: ${error.message || error}`);
  process.exit(1);
});
