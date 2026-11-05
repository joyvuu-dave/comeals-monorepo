// bin/npm-installed-check: does node_modules hold what package-lock.json
// names? Each test writes a package-lock.json and the record npm keeps of
// what it installed (node_modules/.package-lock.json) into a folder of its
// own, and points the script there with NPM_INSTALLED_ROOT. `npm run
// test:bin` runs this file with Node's own coverage of the script held at
// 100%.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const repo = path.resolve(__dirname, "../..");
const script = path.join(repo, "bin/npm-installed-check");

// lock and installed are the `packages` of each file. The root package
// ("") is in the lock only, as npm writes it.
function check({ lock, installed }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "npm-installed-"));
  fs.writeFileSync(
    path.join(root, "package-lock.json"),
    JSON.stringify({ packages: { "": { name: "comeals" }, ...lock } }),
  );
  if (installed) {
    fs.mkdirSync(path.join(root, "node_modules"));
    fs.writeFileSync(
      path.join(root, "node_modules/.package-lock.json"),
      JSON.stringify({ packages: installed }),
    );
  }
  const result = spawnSync(process.execPath, [script], {
    encoding: "utf8",
    env: { ...process.env, NPM_INSTALLED_ROOT: root },
  });
  return { status: result.status, output: result.stdout + result.stderr };
}

const mobx = (version) => ({ "node_modules/mobx": { version } });

test("passes when every package is the version the lock names", () => {
  const result = check({ lock: mobx("7.1.3"), installed: mobx("7.1.3") });

  assert.equal(result.status, 0);
  assert.equal(result.output, "");
});

// The case of #262: a merge changed the lock, and nothing installed it.
test("fails, and names the package, when a version differs", () => {
  const result = check({ lock: mobx("7.1.3"), installed: mobx("6.16.1") });

  assert.equal(result.status, 1);
  assert.equal(
    result.output,
    "  node_modules does not match package-lock.json:\n" +
      "    mobx: 6.16.1 installed, 7.1.3 in the lock\n" +
      "  Run npm ci, then rerun bin/dev.\n",
  );
});

test("fails when a package the lock names is not installed", () => {
  const result = check({ lock: mobx("7.1.3"), installed: {} });

  assert.equal(result.status, 1);
  assert.match(result.output, /mobx: not installed, 7\.1\.3 in the lock/);
});

// npm leaves out an optional package built for another system, such as
// a Linux build of a native tool on a Mac.
test("passes when an optional package is not installed", () => {
  const result = check({
    lock: {
      "node_modules/@rollup/rollup-linux-x64-gnu": {
        version: "4.0.0",
        optional: true,
      },
    },
    installed: {},
  });

  assert.equal(result.status, 0);
});

test("names a package inside another package by its own name", () => {
  const nested = "node_modules/a/node_modules/@scope/b";
  const result = check({
    lock: { [nested]: { version: "2.0.0" } },
    installed: { [nested]: { version: "1.0.0" } },
  });

  assert.match(
    result.output,
    /@scope\/b: 1\.0\.0 installed, 2\.0\.0 in the lock/,
  );
});

test("lists five packages, then says how many more differ", () => {
  const lock = {};
  for (let n = 0; n < 7; n++) lock[`node_modules/p${n}`] = { version: "2.0.0" };

  const result = check({ lock, installed: {} });

  assert.equal(result.status, 1);
  assert.match(result.output, /p4: not installed/);
  assert.doesNotMatch(result.output, /p5:/);
  assert.match(result.output, / {4}and 2 more\n/);
});

test("fails when npm has installed nothing here", () => {
  const result = check({ lock: mobx("7.1.3") });

  assert.equal(result.status, 1);
  assert.equal(
    result.output,
    "  node_modules has no record of what npm installed.\n" +
      "  Run npm ci, then rerun bin/dev.\n",
  );
});

// CI and bin/check run this after npm ci, so the repo's own node_modules
// must match its lock.
test("checks the repo's own node_modules when NPM_INSTALLED_ROOT is not set", () => {
  const env = { ...process.env };
  delete env.NPM_INSTALLED_ROOT;

  const result = spawnSync(process.execPath, [script], {
    encoding: "utf8",
    env,
  });

  assert.equal(result.status, 0, result.stdout);
});
