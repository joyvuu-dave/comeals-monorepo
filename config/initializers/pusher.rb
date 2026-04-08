# frozen_string_literal: true

require 'pusher'

# Pusher credentials for real-time WebSocket push notifications.
# Production/dev: env vars (Heroku config vars or .env via dotenv-rails)
# Test/CI:        placeholder defaults — Pusher.trigger is stubbed in all specs
if Rails.env.test?
  Pusher.app_id  = ENV.fetch('PUSHER_APP_ID', 'test')
  Pusher.key     = ENV.fetch('PUSHER_KEY', 'test')
  Pusher.secret  = ENV.fetch('PUSHER_SECRET', 'test')
  Pusher.cluster = ENV.fetch('PUSHER_CLUSTER', 'test')
else
  Pusher.app_id  = ENV.fetch('PUSHER_APP_ID')
  Pusher.key     = ENV.fetch('PUSHER_KEY')
  Pusher.secret  = ENV.fetch('PUSHER_SECRET')
  Pusher.cluster = ENV.fetch('PUSHER_CLUSTER')
end
Pusher.logger = Rails.logger
Pusher.encrypted = true
