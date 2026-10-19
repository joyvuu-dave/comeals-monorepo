# typed: false
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
# The starting rule was: no ignore list until something proves itself
# noise, because filtering first would hide the thing we installed this
# to see. The discard list below is what has proved itself so far. Add to
# it only after seeing the error in production and confirming the app
# already handles it.
# The rules are methods, and the last line calls them once at boot, so a
# spec can call them as production would (spec/config/initializers/
# bugsnag_spec.rb). Code that runs only at boot runs in one environment only.
module BugsnagSetup
  def self.configure(bugsnag, errors:, api_key:, env:, release:)
    if api_key.present?
      bugsnag.configure { |config| report_to(config, api_key:, env:, release:) }

      # Handled errors reported through Rails.error. See the subscriber for why
      # this is separate from the Rack middleware and why the money code needs it.
      errors.subscribe(BugsnagErrorSubscriber.new)
    else
      # Session tracking is the one thing the gem turns on by itself: the Rails
      # railtie sets auto_capture_sessions, so every request starts a session and
      # a timer thread wakes every 10 seconds. With no api_key it can only log
      # "Not delivering sessions due to an invalid api_key" and give up. Turn it
      # off so development and test really do run nothing.
      bugsnag.configure(&:disable_sessions)
    end
  end

  def self.report_to(config, api_key:, env:, release:)
    config.api_key = api_key
    config.release_stage = env
    config.enabled_release_stages = ['production']

    # Group errors by Heroku release, so the dashboard can say "this started
    # at v612". HEROKU_RELEASE_VERSION comes from Dyno Metadata and is fixed
    # for the life of the dyno — the same source Api::V1::SiteController#version
    # reads. Left nil outside production, where it means nothing.
    config.app_version = release if env.production?

    # Requests the app already refuses with a 400 Bad Request. These are
    # the client's fault — scanners sending malformed paths, bad
    # encodings, or unparseable bodies — not ours. Rails maps each of
    # these classes to :bad_request (see ActionDispatch::ExceptionWrapper
    # .rescue_responses), so the client is answered correctly and there
    # is nothing for us to fix. First seen: GET /%C0 on 2026-08-04.
    config.discard_classes += [
      'Rack::QueryParser::InvalidParameterError',
      'Rack::QueryParser::ParameterTypeError',
      'ActionDispatch::Http::Parameters::ParseError',
      'ActionController::BadRequest'
    ]

    # Requests for a format a page does not render, which Rails already
    # refuses with a 406 Not Acceptable. Scanners probing for PHP admin
    # panels trigger this on the admin login page: /login.php parses as
    # format: php, and Devise's login page only renders HTML. First seen:
    # GET admin.comeals.com/login.php on 2026-08-09.
    config.discard_classes += ['ActionController::UnknownFormat']

    # Never send anything Rails would keep out of its own logs. Bugsnag has
    # its own defaults; adding config.filter_parameters keeps the two lists
    # from drifting apart, so a parameter added there is filtered here too.
    config.meta_data_filters += Rails.application.config.filter_parameters.map(&:to_s)
  end
end

BugsnagSetup.configure(
  Bugsnag,
  errors: Rails.error,
  api_key: ENV.fetch('BUGSNAG_API_KEY', nil),
  env: Rails.env,
  release: ENV.fetch('HEROKU_RELEASE_VERSION', nil)
)
