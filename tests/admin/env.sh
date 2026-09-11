#!/usr/bin/env bash
# Environment for the admin Playwright suite's Rails processes. Sourced by
# tests/admin/server.sh (the server) and tests/admin/reseed.sh (a reload of
# the seed between test files), so the two can never disagree about which
# database, clock, port or token they use.

export RAILS_ENV=test

# The clock stands still at this day for the seed and the server
# (config/initializers/integration_fake_time.rb, shared with the
# integration suite). Every value a page shows is then the same on every
# run: created_at columns, the settlement date, and the sign-in time
# Devise writes when the visual suite logs in. tests/admin/seed.rb reads
# its "now" from this clock.
export INTEGRATION_FAKE_TODAY=2026-01-20

# Port and database name come from .env when bin/agent-worktree wrote
# them there (#65), so each worktree's admin suite has its own server
# and its own database. A real environment variable wins over the .env
# line; the main checkout and CI, which set neither, keep 3038 and
# comeals_admin_e2e. playwright.config.js resolves the same port line
# (tests/helpers/ports.js), so its webServer entry and this script
# cannot disagree. `|| true` because .env does not exist in CI, and
# under `set -e` a failed sed would end the script with sed's exit code.
PORT="${TEST_PORT_ADMIN_E2E:-$(sed -n 's/^TEST_PORT_ADMIN_E2E=//p' .env 2>/dev/null || true)}"
export PORT="${PORT:-3038}"
DB_SUFFIX="${TEST_DB_SUFFIX:-$(sed -n 's/^TEST_DB_SUFFIX=//p' .env 2>/dev/null || true)}"

# Local runs use a socket connection as the current OS user. CI sets
# ADMIN_E2E_DATABASE_URL because its Postgres is a TCP service with a
# password. Both point at an admin e2e database, never comeals_test.
export DATABASE_URL="${ADMIN_E2E_DATABASE_URL:-postgres:///comeals_admin_e2e${DB_SUFFIX}}"

# The read-only token from the reconciliation emails
# (ApplicationController#read_only_admin_token?). tests/admin/actions.spec.js
# opens pages with it. It runs as admin 2, the plain admin the seed
# creates, the same way production points READ_ONLY_ADMIN_ID at a plain
# admin.
export READ_ONLY_ADMIN_TOKEN=admin-e2e-readonly-token
export READ_ONLY_ADMIN_ID=2
