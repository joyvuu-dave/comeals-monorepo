#!/usr/bin/env bash
# Boot Rails for the admin Playwright suite (started by playwright.config.js).
#
# A dedicated database (comeals_admin_e2e), not the RSpec test database:
# the suite's seed rows would otherwise leak into RSpec runs. The seed
# script reloads deterministic data on every start, so the suite never
# depends on leftover state.
set -euo pipefail
cd "$(dirname "$0")/../.."

export RAILS_ENV=test

# Port and database name come from .env when bin/agent-worktree wrote
# them there (#65), so each worktree's admin suite has its own server
# and its own database. A real environment variable wins over the .env
# line; the main checkout and CI, which set neither, keep 3038 and
# comeals_admin_e2e. playwright.config.js resolves the same port line
# (tests/helpers/ports.js), so its webServer entry and this script
# cannot disagree. `|| true` because .env does not exist in CI, and
# under `set -e` a failed sed would end the script with sed's exit code.
PORT="${TEST_PORT_ADMIN_E2E:-$(sed -n 's/^TEST_PORT_ADMIN_E2E=//p' .env 2>/dev/null || true)}"
PORT="${PORT:-3038}"
DB_SUFFIX="${TEST_DB_SUFFIX:-$(sed -n 's/^TEST_DB_SUFFIX=//p' .env 2>/dev/null || true)}"

# Local runs use a socket connection as the current OS user. CI sets
# ADMIN_E2E_DATABASE_URL because its Postgres is a TCP service with a
# password. Both point at an admin e2e database, never comeals_test.
export DATABASE_URL="${ADMIN_E2E_DATABASE_URL:-postgres:///comeals_admin_e2e${DB_SUFFIX}}"

# db:test:prepare, not db:prepare: on a brand-new database db:prepare
# also runs db/seeds.rb, whose demo events call Pusher over the network
# (broken in CI, and wrong data for this suite anyway). db:test:prepare
# recreates the schema from structure.sql and never seeds; the only
# data comes from tests/admin/seed.rb below.
bundle exec rails db:test:prepare
bundle exec rails runner tests/admin/seed.rb
exec bundle exec rails server -p "$PORT"
