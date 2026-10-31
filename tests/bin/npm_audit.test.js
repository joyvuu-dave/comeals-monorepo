// bin/npm-audit: npm audit, with an allow list for advisories that reach
// dev tools only. Each test puts a fake npm first on the PATH and points
// the script at an allow list of its own with NPM_AUDIT_ROOT. `npm run
// test:bin` runs this file with Node's own coverage of the script held at
// 100%.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const repo = path.resolve(__dirname, "../..");
const script = path.join(repo, "bin/npm-audit");

const ALLOWED = "GHSA-aaaa-aaaa-aaaa";
const OTHER = "GHSA-bbbb-bbbb-bbbb";

// A report as `npm audit --json` writes it. One package names the advisory.
// The other only depends on that package, so its `via` is a name.
function report(id) {
  return JSON.stringify({
    vulnerabilities: {
      lib: {
        via: [
          {
            title: "A problem in lib",
            url: `https://github.com/advisories/${id}`,
            severity: "moderate",
          },
        ],
      },
      "lint-tool": { via: ["lib"] },
    },
  });
}

const CLEAN = JSON.stringify({ vulnerabilities: {} });

// all: what plain `npm audit --json` writes. production: what it writes
// with --omit=dev.
function run({ all = CLEAN, production = CLEAN, allowed = "" }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "npm-audit-"));
  fs.mkdirSync(path.join(root, "config"));
  fs.mkdirSync(path.join(root, "fakebin"));
  fs.writeFileSync(
    path.join(root, "config", "npm_audit_allowed_dev.txt"),
    `# Why this list exists.\n\n${allowed}`,
  );
  fs.writeFileSync(path.join(root, "all.json"), all);
  fs.writeFileSync(path.join(root, "production.json"), production);
  fs.writeFileSync(
    path.join(root, "fakebin", "npm"),
    `#!/bin/sh
case "$*" in
  *--omit=dev*) cat "${root}/production.json" ;;
  *) cat "${root}/all.json" ;;
esac
exit 1
`,
    { mode: 0o755 },
  );
  const result = spawnSync(process.execPath, [script], {
    env: {
      ...process.env,
      NPM_AUDIT_ROOT: root,
      PATH: `${path.join(root, "fakebin")}:${process.env.PATH}`,
    },
    encoding: "utf8",
  });
  return { status: result.status, out: result.stdout + result.stderr };
}

test("passes when npm audit finds nothing", () => {
  const { status, out } = run({});
  assert.equal(status, 0);
  assert.equal(out, "no vulnerabilities\n");
});

test("fails on an advisory the list does not name", () => {
  const { status, out } = run({ all: report(OTHER) });
  assert.equal(status, 1);
  assert.match(out, new RegExp(OTHER));
  assert.match(out, /lib: A problem in lib \(moderate\)/);
});

test("passes on a listed advisory that reaches dev tools only", () => {
  const { status, out } = run({
    all: report(ALLOWED),
    allowed: `${ALLOWED}  dev tools only\n`,
  });
  assert.equal(status, 0);
  assert.equal(out, `no new vulnerabilities, 1 allowed: ${ALLOWED}\n`);
});

test("fails on a listed advisory that reaches a production package", () => {
  const { status, out } = run({
    all: report(ALLOWED),
    production: report(ALLOWED),
    allowed: `${ALLOWED}  dev tools only\n`,
  });
  assert.equal(status, 1);
  assert.match(out, new RegExp(`${ALLOWED}.*production`));
});

test("fails on an unlisted advisory beside a listed one", () => {
  const all = JSON.parse(report(ALLOWED));
  all.vulnerabilities.other = JSON.parse(report(OTHER)).vulnerabilities.lib;
  const { status, out } = run({
    all: JSON.stringify(all),
    allowed: `${ALLOWED}  dev tools only\n`,
  });
  assert.equal(status, 1);
  assert.match(out, new RegExp(OTHER));
  assert.doesNotMatch(out, new RegExp(`${ALLOWED}:`));
});

test("fails when a listed advisory is no longer reported, so the list stays short", () => {
  const { status, out } = run({ allowed: `${ALLOWED}  dev tools only\n` });
  assert.equal(status, 1);
  assert.match(out, new RegExp(`${ALLOWED}.*no longer reports`));
});

test("says it could not run when npm answers with an error", () => {
  const { status, out } = run({
    all: JSON.stringify({ message: "request to registry failed" }),
  });
  assert.equal(status, 2);
  assert.match(out, /npm audit could not run, so no package was checked/);
});

test("says it could not run when npm's answer is not JSON", () => {
  const { status, out } = run({ production: "not json" });
  assert.equal(status, 2);
  assert.match(out, /npm audit could not run, so no package was checked/);
});
