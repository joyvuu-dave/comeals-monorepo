#!/usr/bin/env bash
# Boot Rails for the admin Playwright suite (started by playwright.config.js).
#
# A dedicated database (comeals_admin_e2e), not the RSpec test database:
# the suite's seed rows would otherwise leak into RSpec runs. The seed
# script reloads deterministic data on every start, so the suite never
# depends on leftover state. tests/admin/env.sh holds the database, the
# frozen clock, the port and the read-only token.
set -euo pipefail
cd "$(dirname "$0")/../.."

. tests/admin/env.sh

# db:test:prepare, not db:prepare: on a brand-new database db:prepare
# also runs db/seeds.rb, whose demo events call Pusher over the network
# (broken in CI, and wrong data for this suite anyway). db:test:prepare
# recreates the schema from structure.sql and never seeds; the only
# data comes from tests/admin/seed.rb below.
bundle exec rails db:test:prepare
bundle exec rails runner tests/admin/seed.rb
exec bundle exec rails server -p "$PORT"
