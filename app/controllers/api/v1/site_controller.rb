# frozen_string_literal: true

module Api
  module V1
    class SiteController < ApiController
      # GET /api/v1/version
      # Cached in process memory — clears on dyno restart (every deploy).
      # Returns nil on API failure so ||= retries on the next request.
      def version
        if Rails.env.production?
          @@cached_version ||= fetch_heroku_version # rubocop:disable Style/ClassVars -- intentional process-memory cache, cleared on dyno restart
          render json: { version: @@cached_version || 1 }
        else
          render json: { version: 0 }
        end
      end

      private

      def fetch_heroku_version
        require 'platform-api'
        heroku = PlatformAPI.connect_oauth(ENV.fetch('HEROKU_OAUTH_TOKEN', nil))
        heroku.release.list('comeals').to_a.last['version']
      rescue StandardError => e
        Rails.logger.info e
        nil # Don't cache failures — ||= will retry on next request
      end
    end
  end
end
