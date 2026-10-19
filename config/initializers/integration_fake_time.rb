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
#
# A method, called once at boot below, so a spec can call it with other
# values (spec/config/initializers/integration_fake_time_spec.rb). It
# returns the object that holds the frozen clock, or nil when it froze
# nothing; travel_back on that object starts the clock again.
module IntegrationFakeTime
  def self.freeze_clock(env:, today:)
    return unless env.test? && today.present?

    require 'active_support/testing/time_helpers'

    clock = Object.new.extend(ActiveSupport::Testing::TimeHelpers)
    clock.travel_to(Time.zone.parse("#{today} 12:00:00"))
    clock
  end
end

IntegrationFakeTime.freeze_clock(env: Rails.env, today: ENV.fetch('INTEGRATION_FAKE_TODAY', nil))
