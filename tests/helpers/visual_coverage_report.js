// The screen-state measure, report side. Merges the counters the visual
// suite saved (tests/helpers/visual_coverage.js) and reports how much of
// the components' markup branches rendered while the visual suite ran.
//
// A screen state is a branch in the markup: a `? :` or `&&` inside the
// JSX, which chooses what is drawn. That includes a branch inside a
// function the markup calls to draw its rows (`rows.map((row) => ...)`).
// Branches in event handlers, effects and request callbacks are not
// looks, so they are left out, and so is a handler written inline as an
// attribute's value (`onClick={() => ...}`). A branch outside any JSX,
// such as an early `return null` or a helper that builds a label, is
// left out too; those few states live in unit tests. The all-branches
// number is printed as well, for a sense of scale, but only the markup
// number is held to the thresholds.
//
// A branch counts when it rendered at any moment of a visual test, not
// only when a screenshot was taken. So a state that shows for a moment
// before the data arrives (a "Loading..." line) counts once any test
// passes through it. The visual spec gives such a state its own golden
// when it can hold the page in it.
//
// A component file that no visual test loads has no counters at all. It
// would drop out of both totals, so the report names it and fails.
//
// Prints the files that fall short with the lines of their unseen
// markup branches, and fails below the thresholds.
//
// Usage: node tests/helpers/visual_coverage_report.js
const fs = require("fs");
const path = require("path");
const libCoverage = require("istanbul-lib-coverage");
const { parse } = require("@babel/parser");
const traverse = require("@babel/traverse").default;
const { RAW_DIR } = require("./visual_coverage");

const ROOT = path.join(__dirname, "..", "..");
// The components are the screens. Stores and helpers have no look of
// their own, and the unit suite covers every line of them.
const INCLUDE =
  path.join(ROOT, "app", "frontend", "src", "components") + path.sep;

// Every markup branch, the same rule the unit suites hold to. A look the
// app cannot reach is not a reason to lower this: change the code so
// the branch is gone.
const THRESHOLD = 100;

// The (line, column) ranges of every JSX expression in a source, minus
// the handlers written inline as an attribute's value
// (`onClick={() => ...}`, `ref={(el) => ...}`). A function elsewhere in
// the markup, such as the callback of a `.map()` that draws list rows,
// stays in: its branches choose what is drawn.
function markupRanges(source) {
  const ast = parse(source, {
    sourceType: "module",
    plugins: ["jsx", "typescript"],
  });
  const containers = [];
  const functions = [];
  traverse(ast, {
    JSXExpressionContainer(nodePath) {
      containers.push(nodePath.node.loc);
    },
    Function(nodePath) {
      const parent = nodePath.parentPath;
      if (
        parent.isJSXExpressionContainer() &&
        parent.parentPath.isJSXAttribute()
      ) {
        functions.push(nodePath.node.loc);
      }
    },
  });
  return { containers, functions };
}

function before(a, b) {
  return a.line < b.line || (a.line === b.line && a.column <= b.column);
}

function inside(point, range) {
  return before(range.start, point) && before(point, range.end);
}

function isMarkupBranch(location, ranges) {
  const point = location.start;
  return (
    ranges.containers.some((range) => inside(point, range)) &&
    !ranges.functions.some((range) => inside(point, range))
  );
}

// Every source file under dir, with its full path.
function sourceFiles(dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...sourceFiles(full));
    } else if (/\.(js|jsx|ts|tsx)$/.test(entry.name)) {
      files.push(full);
    }
  }
  return files.sort();
}

// The files under dir that draw markup but have no counters: no visual
// test loaded them, so none of their looks has a golden.
function neverLoaded(loadedFiles, dir) {
  const loaded = new Set(loadedFiles);
  return sourceFiles(dir).filter(
    (file) =>
      !loaded.has(file) &&
      markupRanges(fs.readFileSync(file, "utf8")).containers.length > 0,
  );
}

function merged() {
  const map = libCoverage.createCoverageMap({});
  if (!fs.existsSync(RAW_DIR)) return map;
  for (const file of fs.readdirSync(RAW_DIR)) {
    if (!file.endsWith(".json")) continue;
    const data = JSON.parse(fs.readFileSync(path.join(RAW_DIR, file), "utf8"));
    map.merge(data);
  }
  map.filter((file) => file.startsWith(INCLUDE));
  return map;
}

function pct(covered, total) {
  return total === 0 ? 100 : (covered / total) * 100;
}

// The markup branches of one file: how many, how many ran, and the
// lines of those that did not.
function markupBranches(fileCoverage, ranges) {
  const result = { total: 0, covered: 0, unseenLines: new Set() };
  const branchMap = fileCoverage.branchMap;
  for (const [id, counts] of Object.entries(fileCoverage.b)) {
    const branch = branchMap[id];
    if (!isMarkupBranch(branch.loc, ranges)) continue;
    counts.forEach((count, index) => {
      result.total += 1;
      if (count > 0) {
        result.covered += 1;
        return;
      }
      const location =
        branch.locations[index] && branch.locations[index].start.line
          ? branch.locations[index]
          : branch.loc;
      result.unseenLines.add(location.start.line);
    });
  }
  return result;
}

function main() {
  const map = merged();
  const files = map.files().sort();
  if (files.length === 0) {
    console.error("No coverage was collected. Run bin/visual-coverage.");
    process.exit(1);
  }

  const markup = { covered: 0, total: 0 };
  const all = { covered: 0, total: 0 };
  const rows = [];
  for (const file of files) {
    const fc = map.fileCoverageFor(file);
    const summary = fc.toSummary();
    all.covered += summary.branches.covered;
    all.total += summary.branches.total;
    const branches = markupBranches(
      fc,
      markupRanges(fs.readFileSync(file, "utf8")),
    );
    markup.covered += branches.covered;
    markup.total += branches.total;
    rows.push({
      file: path.relative(path.join(ROOT, "app", "frontend", "src"), file),
      branches,
    });
  }

  const unloaded = neverLoaded(files, INCLUDE);

  console.log(
    "Screen states: markup branches of app/frontend/src/components rendered during the visual suite",
  );
  console.log("");
  for (const row of rows) {
    const b = row.branches;
    if (b.covered === b.total) continue;
    const lines = [...b.unseenLines].sort((x, y) => x - y);
    console.log(
      `  ${row.file}  ${b.covered}/${b.total}  unseen at lines ${lines.join(", ")}`,
    );
  }
  for (const file of unloaded) {
    console.log(
      `  ${path.relative(path.join(ROOT, "app", "frontend", "src"), file)}  never loaded, so all its markup branches are unseen`,
    );
  }
  const markupPct = pct(markup.covered, markup.total);
  const allPct = pct(all.covered, all.total);
  console.log("");
  console.log(
    `Markup branches : ${markupPct.toFixed(2)}% (${markup.covered}/${markup.total})`,
  );
  console.log(
    `All branches    : ${allPct.toFixed(2)}% (${all.covered}/${all.total}), for scale`,
  );

  if (unloaded.length > 0) {
    console.error(
      `ERROR: ${unloaded.length} component file(s) with markup were never loaded by the visual suite`,
    );
    process.exit(1);
  }
  if (markupPct < THRESHOLD) {
    console.error(
      `ERROR: markup branches ${markupPct.toFixed(2)}% is below the threshold ${THRESHOLD}%`,
    );
    process.exit(1);
  }
}

if (require.main === module) main();

module.exports = { markupRanges, isMarkupBranch, neverLoaded };
