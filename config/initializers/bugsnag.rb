# frozen_string_literal: true

require Rails.root.join('lib/bugsnag_error_subscriber')

# Error tracking, to the "comeals" project at app.bugsnag.com.
#
# Everything here hangs off one question: is BUGSNAG_API_KEY set? It is set
# on Heroku and nowhere else, so development and test configure nothing,
# subscribe nothing, and send nothing. That is stronger than relying on
# enabled_release_stages alone, because there is no code path to reach.
# enabled_release_stages is set anyway, so a key that somehow appears in a
# development shell still sends nothing.
#
# There is deliberately no ignore list for exception classes. This app had
# no error tracking at all until now, so we do not yet know what is noise.
# Watch it for a while, then filter what turns out to be noise — filtering
# first would hide the thing we installed this to see.
api_key = ENV.fetch('BUGSNAG_API_KEY', nil)

if api_key.present?
  Bugsnag.configure do |config|
    config.api_key = api_key
    config.release_stage = Rails.env
    config.enabled_release_stages = ['production']

    # Group errors by Heroku release, so the dashboard can say "this started
    # at v612". HEROKU_RELEASE_VERSION comes from Dyno Metadata and is fixed
    # for the life of the dyno — the same source Api::V1::SiteController#version
    # reads. Left nil outside production, where it means nothing.
    config.app_version = ENV.fetch('HEROKU_RELEASE_VERSION', nil) if Rails.env.production?

    # Never send anything Rails would keep out of its own logs. Bugsnag has
    # its own defaults; adding config.filter_parameters keeps the two lists
    # from drifting apart, so a parameter added there is filtered here too.
    config.meta_data_filters += Rails.application.config.filter_parameters.map(&:to_s)
  end

  # Handled errors reported through Rails.error. See the subscriber for why
  # this is separate from the Rack middleware and why it matters here.
  Rails.error.subscribe(BugsnagErrorSubscriber.new)
end
