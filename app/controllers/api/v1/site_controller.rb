# frozen_string_literal: true

module Api
  module V1
    class SiteController < ApiController
      # GET /api/v1/version
      # Returns the current Heroku release number so you can hit a URL and see
      # what's deployed. HEROKU_RELEASE_VERSION is set per-dyno by Heroku's
      # Dyno Metadata feature (e.g. "v42"); it's fixed for the life of the
      # dyno and changes only on the next release. Returns 0 outside
      # production and 1 when we can't parse a real release in production
      # (missing or malformed env var) — sentinel values, not real releases.
      def version
        render json: { version: heroku_release_number }
      end

      private

      def heroku_release_number
        return 0 unless Rails.env.production?

        parsed = ENV['HEROKU_RELEASE_VERSION'].to_s.delete_prefix('v').to_i
        parsed.positive? ? parsed : 1
      end
    end
  end
end
