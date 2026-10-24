// bin/bundle-budget: the gzipped size of the built JavaScript against
// config/bundle_budgets.json, and the calendar chunk's preload. Each test
// writes a small build of its own and points the script at it with
// BUNDLE_BUDGET_ROOT. `npm run test:bin` runs this file with Node's own
// coverage of the script held at 100%.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");

const repo = path.resolve(__dirname, "../..");
const script = path.join(repo, "bin/bundle-budget");

function run(root) {
  const env = { ...process.env, BUNDLE_BUDGET_ROOT: root };
  if (root === undefined) delete env.BUNDLE_BUDGET_ROOT;
  const result = spawnSync(process.execPath, [script], {
    env,
    encoding: "utf8",
  });
  return { status: result.status, out: result.stdout, err: result.stderr };
}

// Random bytes do not compress, so a file of n KB is about n KB gzipped.
function chunk(kb) {
  return crypto.randomBytes(kb * 1024);
}

function gzippedKB(bytes) {
  return zlib.gzipSync(bytes).length / 1024;
}

// A build: the files under public/, the manifest, and the budgets.
function build({
  files,
  manifest,
  budgets = { firstLoadKB: 100, totalKB: 200 },
}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bundle-budget-"));
  fs.mkdirSync(path.join(root, "config"));
  fs.writeFileSync(
    path.join(root, "config/bundle_budgets.json"),
    JSON.stringify(budgets),
  );
  for (const [name, body] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, "public", name)), {
      recursive: true,
    });
    fs.writeFileSync(path.join(root, "public", name), body);
  }
  if (manifest) {
    fs.mkdirSync(path.join(root, "public/.vite"), { recursive: true });
    fs.writeFileSync(
      path.join(root, "public/.vite/manifest.json"),
      JSON.stringify(manifest),
    );
  }
  return root;
}

// The script app/frontend/preload_calendar.mjs writes into index.html.
const preload =
  '<script id="calendar-preload">var files = ["/vite-assets/show.js"];</script>';
// index.jsx imports a shared chunk twice over (directly and through
// store.js), names one import the manifest does not have, and loads the
// calendar lazily. The CSS file is not JavaScript and counts for neither.
const sizes = { entry: 10, store: 5, shared: 3, show: 20, css: 50 };
function normalBuild(overrides = {}) {
  const files = {
    "vite-assets/index.js": chunk(sizes.entry),
    "vite-assets/store.js": chunk(sizes.store),
    "vite-assets/shared.js": chunk(sizes.shared),
    "vite-assets/show.js": chunk(sizes.show),
    "vite-assets/index.css": chunk(sizes.css),
    "index.html": `<head>${preload}</head>`,
    ...overrides.files,
  };
  const manifest = overrides.manifest || {
    "index.jsx": {
      file: "vite-assets/index.js",
      isEntry: true,
      imports: ["store.js", "shared.js", "_missing.js"],
    },
    "store.js": { file: "vite-assets/store.js", imports: ["shared.js"] },
    "shared.js": { file: "vite-assets/shared.js" },
    "app/frontend/src/components/calendar/show.jsx": {
      file: "vite-assets/show.js",
      isDynamicEntry: true,
    },
    "index.css": { file: "vite-assets/index.css" },
  };
  return {
    files,
    manifest,
    root: build({ files, manifest, budgets: overrides.budgets }),
  };
}

function kb(files, names) {
  return names
    .reduce((sum, name) => sum + gzippedKB(files[`vite-assets/${name}`]), 0)
    .toFixed(1);
}

test("passes within budget, counting the entry and its static imports once each", () => {
  const { files, root } = normalBuild();

  const { status, out, err } = run(root);

  assert.equal(err, "");
  assert.equal(status, 0);
  assert.equal(
    out,
    `ok     first load: ${kb(files, ["index.js", "store.js", "shared.js"])} KB gzipped (budget 100 KB)\n` +
      `ok     total     : ${kb(files, ["index.js", "store.js", "shared.js", "show.js"])} KB gzipped (budget 200 KB)\n` +
      "ok     calendar preload: /vite-assets/show.js\n",
  );
});

test("fails when the first load or the total is over its budget, and says what to do", () => {
  const { root } = normalBuild({ budgets: { firstLoadKB: 1, totalKB: 2 } });

  const { status, out, err } = run(root);

  assert.equal(status, 1);
  assert.equal(out, "ok     calendar preload: /vite-assets/show.js\n");
  assert.match(err, /^OVER {3}first load: [\d.]+ KB gzipped \(budget 1 KB\)\n/);
  assert.match(err, /\nOVER {3}total {5}: [\d.]+ KB gzipped \(budget 2 KB\)\n/);
  assert.match(
    err,
    /raise the budget in config\/bundle_budgets.json in the same commit/,
  );
});

test("fails when index.html does not preload the calendar chunk", () => {
  const { root } = normalBuild({ files: { "index.html": "<head></head>" } });

  const { status, err } = run(root);

  assert.equal(status, 1);
  assert.match(
    err,
    /^MISSING calendar preload: index.html has no modulepreload for \/vite-assets\/show.js\.\nDid calendar\/show.jsx move\?/,
  );
});

// The script is there, but for a chunk the build no longer has.
test("fails when the preload script names another file", () => {
  const { root } = normalBuild({
    files: {
      "index.html":
        '<head><script id="calendar-preload">var files = ["/vite-assets/old.js"];</script></head>',
    },
  });

  const { status, err } = run(root);

  assert.equal(status, 1);
  assert.match(
    err,
    /^MISSING calendar preload: index.html has no modulepreload for \/vite-assets\/show.js\./,
  );
});

test("fails when the manifest has no calendar chunk", () => {
  const manifest = {
    "index.jsx": { file: "vite-assets/index.js", isEntry: true },
  };
  const { root } = normalBuild({ manifest });

  const { status, err } = run(root);

  assert.equal(status, 1);
  assert.match(
    err,
    /^MISSING calendar preload check could not run: no calendar\/show.jsx chunk in the manifest\n/,
  );
});

test("fails when the build has no index.html", () => {
  const { root } = normalBuild();
  fs.rmSync(path.join(root, "public/index.html"));

  const { status, err } = run(root);

  assert.equal(status, 1);
  assert.match(
    err,
    /^MISSING calendar preload check could not run: no built index.html found\n/,
  );
});

test("stops when there is no build", () => {
  const root = build({ files: {} });

  assert.deepEqual(run(root), {
    status: 1,
    out: "",
    err: "No build found. Run `npm run build` first.\n",
  });
});

// Without BUNDLE_BUDGET_ROOT it reads this repository. Whether there is
// a build here depends on the machine, so this checks only that it found
// the repository's own budgets: a wrong folder has no
// config/bundle_budgets.json, and reading it would throw.
test("reads this repository when BUNDLE_BUDGET_ROOT is not set", () => {
  const budgets = JSON.parse(
    fs.readFileSync(path.join(repo, "config/bundle_budgets.json"), "utf8"),
  );

  const { out, err } = run(undefined);

  assert.ok(
    err === "No build found. Run `npm run build` first.\n" ||
      `${out}${err}`.includes(`(budget ${budgets.firstLoadKB} KB)`),
    out + err,
  );
});
