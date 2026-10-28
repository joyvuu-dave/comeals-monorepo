# typed: false
# frozen_string_literal: true

require 'pusher'

# Pusher credentials for real-time WebSocket push notifications.
# Production/dev: env vars (Heroku config vars or .env via dotenv-rails)
# Test/CI:        placeholder defaults — Pusher.trigger is stubbed in all specs
#
# The rules are methods, and the last lines call them once at boot, so a
# spec can call them with another environment (spec/config/initializers/
# pusher_spec.rb). Code that runs only at boot runs in one environment only.
module PusherSetup
  NAMES = { app_id: 'PUSHER_APP_ID', key: 'PUSHER_KEY', secret: 'PUSHER_SECRET', cluster: 'PUSHER_CLUSTER' }.freeze

  def self.configure(pusher, env:, vars:, logger:)
    NAMES.each do |setting, name|
      pusher.public_send(:"#{setting}=", env.test? ? vars.fetch(name, 'test') : vars.fetch(name))
    end
    pusher.logger = logger
    pusher.encrypted = true
  end

  # Integration test server and the staging app: suppress Pusher to avoid
  # network calls. RSpec already stubs Pusher per-test via rails_helper;
  # this handles the non-RSpec cases — `rails server` for Playwright
  # integration tests, and comeals-staging, which runs with placeholder
  # Pusher credentials and must never broadcast (Pusher.trigger raises on
  # bad credentials, and it runs unrescued after every meal write).
  def self.silence_outside_production(pusher, vars:)
    return unless silenced?(vars)

    pusher.define_singleton_method(:trigger) { |*_args| true }
  end

  # Also read by PageSettings: a page sent where the server sends nothing
  # gets no Pusher key, so it never connects.
  def self.silenced?(vars)
    vars['INTEGRATION_SERVER'].present? || vars['COMEALS_STAGING'].present?
  end
end

PusherSetup.configure(Pusher, env: Rails.env, vars: ENV, logger: Rails.logger)
PusherSetup.silence_outside_production(Pusher, vars: ENV)
