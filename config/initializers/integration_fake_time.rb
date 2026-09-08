# typed: false
# frozen_string_literal: true

# The frozen clock of the integration suite (docs/deploy-confidence-plan.md,
# item 3) and of the admin Playwright suite. bin/test-integration sets
# INTEGRATION_FAKE_TODAY for the seed task and the test server, and the
# Playwright side freezes the browser to the same instant — so seeds,
# server, and page all agree on what "today" is, and screenshots against
# the real backend are the same on any day the suite runs.
# tests/admin/server.sh sets it for the admin seed and server the same
# way, so the admin goldens see fixed timestamps too.
#
# Test-only by construction: the guard requires the test environment,
# so a stray env var cannot freeze development or production.
if Rails.env.test? && ENV['INTEGRATION_FAKE_TODAY'].present?
  require 'active_support/testing/time_helpers'

  Object.new.extend(ActiveSupport::Testing::TimeHelpers).travel_to(
    Time.zone.parse("#{ENV.fetch('INTEGRATION_FAKE_TODAY', nil)} 12:00:00")
  )
end
