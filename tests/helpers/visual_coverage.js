// The screen-state measure, test side. tests/helpers/test.js calls
// saveCoverage with the istanbul counters a page handed out; each call
// becomes one JSON file that bin/visual-coverage merges into a report.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const RAW_DIR = path.join(
  __dirname,
  "..",
  "..",
  "tmp",
  "visual-coverage",
  "raw",
);

function saveCoverage(json, testInfo) {
  fs.mkdirSync(RAW_DIR, { recursive: true });
  const name = `${testInfo.testId}-${crypto.randomUUID()}.json`;
  fs.writeFileSync(path.join(RAW_DIR, name), json);
}

module.exports = { saveCoverage, RAW_DIR };
