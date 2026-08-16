// Test-server ports, one block per worktree (#65).
//
// bin/agent-worktree writes TEST_PORT_INTEGRATION, TEST_PORT_E2E, and
// TEST_PORT_ADMIN_E2E into the worktree's .env, so each worktree's
// browser suites listen on their own ports and bin/check can run
// everywhere at once. Resolution order: a real environment variable,
// then the .env line, then the fixed default — so the main checkout
// and CI keep 3001/3037/3038 without setting anything.
//
// The bash consumers (bin/test-integration, tests/admin/server.sh)
// read the same .env lines with sed; this module is the node side.
const fs = require("fs");
const path = require("path");

let envText = "";
try {
  envText = fs.readFileSync(path.join(__dirname, "..", "..", ".env"), "utf8");
} catch {
  // No .env (CI checks out a bare tree): defaults apply.
}

function port(name, fallback) {
  if (process.env[name]) return Number(process.env[name]);
  const match = envText.match(new RegExp(`^${name}=(\\d+)$`, "m"));
  return match ? Number(match[1]) : fallback;
}

module.exports = {
  INTEGRATION_PORT: port("TEST_PORT_INTEGRATION", 3001),
  E2E_PORT: port("TEST_PORT_E2E", 3037),
  ADMIN_E2E_PORT: port("TEST_PORT_ADMIN_E2E", 3038),
};
