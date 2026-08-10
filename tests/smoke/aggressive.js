// The aggressive smoke: real writes through real user flows, against
// the STAGING app only. bin/staging-rehearsal runs it after restoring
// a production backup — the data is a disposable copy, so writing to
// it is the point: this proves the write paths (login, attendance
// toggle with the meal lock, modal open/close) work on today's real
// data, not just on fixtures.
//
// The lock: /api/v1/version must answer `staging: true` (set only by
// the COMEALS_STAGING config var on comeals-staging). Any other
// answer — production, localhost, anything — and this script refuses
// before logging in. bin/smoke stays the read-only script for
// production; this one must never point there.
//
// Required env:
//   SMOKE_URL       target base URL
//   SMOKE_EMAIL     the smoke resident (bin/lib/staging_smoke_seed.rb)
//   SMOKE_PASSWORD  its per-rehearsal password
//   SMOKE_MEAL_ID   the open far-future meal the seed created
const { chromium } = require("@playwright/test");

const BASE = process.env.SMOKE_URL;
const EMAIL = process.env.SMOKE_EMAIL;
const PASSWORD = process.env.SMOKE_PASSWORD;
const MEAL_ID = process.env.SMOKE_MEAL_ID;

for (const [name, value] of Object.entries({
  SMOKE_URL: BASE,
  SMOKE_EMAIL: EMAIL,
  SMOKE_PASSWORD: PASSWORD,
  SMOKE_MEAL_ID: MEAL_ID,
})) {
  if (!value) {
    console.error(`aggressive smoke: ${name} is required`);
    process.exit(1);
  }
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

  // 0. The lock: refuse anything that does not declare itself staging.
  const version = await page.request.get(`${BASE}/api/v1/version`);
  if (!version.ok()) {
    throw new Error(`/api/v1/version returned ${version.status()}`);
  }
  const info = await version.json();
  if (info.staging !== true) {
    throw new Error(
      `refusing: ${BASE} does not declare staging:true ` +
        `(got ${JSON.stringify(info)}) — this script writes real data`,
    );
  }
  pass("target declares itself staging");

  // 1. Log in as the smoke resident.
  await page.goto(`${BASE}/`, { waitUntil: "load" });
  await page.fill('input[aria-label="email"]', EMAIL);
  await page.fill('input[aria-label="password"]', PASSWORD);
  await page.getByRole("button", { name: "Submit" }).click();
  await page.waitForSelector(".rbc-calendar", { timeout: 15000 });
  pass("smoke resident logs in");

  // 2. Attendance toggle on the seeded open meal: on, persisted, off,
  // persisted. This exercises the locked meal write path end to end.
  const mealUrl = `${BASE}/meals/${MEAL_ID}/edit/`;
  // The clickable name cell alone carries background-transition; the
  // row's toggle cells also contain "Smoke Test" in their aria-labels.
  const smokeCell = () =>
    page.locator("td.background-transition", { hasText: "Smoke Test" });

  await page.goto(mealUrl);
  await smokeCell().waitFor({ timeout: 15000 });
  const attending = async () =>
    /background-green/.test((await smokeCell().getAttribute("class")) || "");

  if (await attending()) {
    throw new Error("smoke resident already attending the seeded meal");
  }
  const greenSmokeCell = page.locator("td.background-green", {
    hasText: "Smoke Test",
  });
  await smokeCell().click();
  await greenSmokeCell.waitFor({ timeout: 10000 });
  await page.goto(mealUrl);
  await smokeCell().waitFor({ timeout: 15000 });
  if (!(await attending())) {
    throw new Error("attendance toggle did not persist across a reload");
  }
  pass("attendance on: saved and persisted");

  await smokeCell().click();
  await greenSmokeCell.waitFor({ state: "detached", timeout: 10000 });
  await page.goto(mealUrl);
  await smokeCell().waitFor({ timeout: 15000 });
  if (await attending()) {
    throw new Error("attendance un-toggle did not persist across a reload");
  }
  pass("attendance off: saved and persisted");

  // 3. A reservation modal opens and closes cleanly.
  await page.goto(
    `${BASE}/calendar/all/${new Date().toISOString().slice(0, 10)}/`,
  );
  await page.waitForSelector(".rbc-calendar", { timeout: 15000 });
  await page.locator("text=Common House").first().click();
  await page.waitForSelector("#ch-new-title", { timeout: 10000 });
  await page.locator(".close-button").click();
  await page.waitForSelector(".ReactModal__Content--after-open", {
    state: "detached",
    timeout: 10000,
  });
  pass("reservation modal opens and closes");

  await browser.close();

  if (problems.length) {
    console.error("Console/page errors during aggressive smoke:");
    problems.forEach((p) => console.error(`  ${p}`));
    throw new Error(`${problems.length} console/page error(s)`);
  }

  console.log(
    `Aggressive smoke passed: ${checks.length} check(s) against ${BASE}`,
  );
}

main().catch((error) => {
  console.error(
    `AGGRESSIVE SMOKE FAILED against ${BASE}: ${error.message || error}`,
  );
  process.exit(1);
});
