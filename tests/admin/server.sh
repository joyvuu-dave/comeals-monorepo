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
export DATABASE_URL=postgres:///comeals_admin_e2e

bundle exec rails db:prepare
bundle exec rails runner tests/admin/seed.rb
exec bundle exec rails server -p 3038
