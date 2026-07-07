# frozen_string_literal: true

require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'action_view/railtie'
require 'sprockets/railtie'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Comeals
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration can go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded after loading
    # the framework and any gems in your application.

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    config.app_generators.scaffold_controller = :scaffold_controller

    # Middleware for ActiveAdmin. Devise adds Warden::Manager through
    # config.app_middleware, which lands in the default stack — before
    # anything added here with plain `use`. Warden must run inside the
    # session middleware, or a sign_in written to the session before
    # Session::CookieStore runs is silently thrown away (issue #19). So
    # insert each one before Warden::Manager, in the same order a non-API
    # Rails app uses: Cookies, then Session, then Flash.
    config.middleware.insert_before Warden::Manager, Rack::MethodOverride
    config.middleware.insert_before Warden::Manager, ActionDispatch::Cookies
    config.middleware.insert_before Warden::Manager, ActionDispatch::Session::CookieStore
    config.middleware.insert_before Warden::Manager, ActionDispatch::Flash

    # Gzip response compression — must be early in the stack (outer middleware)
    # so it compresses the final response after all other middleware are done.
    config.middleware.insert_before Rack::Sendfile, Rack::Deflater

    # Dump the schema as SQL. The database is the last line of defense
    # (CLAUDE.md): reconciled-meal immutability lives in triggers, and
    # schema.rb cannot represent triggers, so a schema.rb-built database
    # would silently lack them (issue #26).
    config.active_record.schema_format = :sql

    # Set Time Zone
    config.time_zone = 'America/Los_Angeles'
  end
end
