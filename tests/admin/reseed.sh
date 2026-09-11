#!/usr/bin/env bash
# Reload tests/admin/seed.rb into the admin e2e database while the suite's
# Rails server keeps running. tests/admin/actions.spec.js runs it before
# and after its tests: those tests write through the admin forms, and the
# files that run after them (admin.spec.js, visual.spec.js) assert on the
# seed as written. The seed truncates every table and restarts the id
# sequences, so ids are the same after a reload as after a fresh start.
set -euo pipefail
cd "$(dirname "$0")/../.."

. tests/admin/env.sh

bundle exec rails runner tests/admin/seed.rb
