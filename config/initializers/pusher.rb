# frozen_string_literal: true

require 'pusher'

# Pusher credentials for real-time WebSocket push notifications.
# Production: Heroku config vars (PUSHER_APP_ID, PUSHER_KEY, PUSHER_SECRET, PUSHER_CLUSTER)
# Local dev:  .env file (loaded by dotenv-rails)
Pusher.app_id = ENV.fetch('PUSHER_APP_ID')
Pusher.key = ENV.fetch('PUSHER_KEY')
Pusher.secret = ENV.fetch('PUSHER_SECRET')
Pusher.cluster = ENV.fetch('PUSHER_CLUSTER')
Pusher.logger = Rails.logger
Pusher.encrypted = true
