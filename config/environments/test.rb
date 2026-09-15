# typed: false
# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Turn false under Spring and add config.action_view.cache_template_loading = true.
  config.enable_reloading = false

  # Eager loading loads your whole application. When running a single test locally,
  # this probably isn't necessary. It's a good idea to do in a continuous integration
  # system, or in some way before deploying your code.
  config.eager_load = ENV['CI'].present?

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=#{1.hour.to_i}"
  }

  # Show full error reports and disable caching.
  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  # No cache, except for the storm server (bin/storm), which caches the
  # way production does: solid_cache, in the test database, so the
  # calendar cache and the Rack::Attack counters are real rows under load.
  config.cache_store = ENV['INTEGRATION_SERVER_CACHE'] == 'solid' ? :solid_cache_store : :null_store

  # Raise exceptions instead of rendering exception templates.
  config.action_dispatch.show_exceptions = :none

  # prosopite watches each request for an N+1 query and raises when it
  # finds one (settings and the allow list: spec/support/prosopite.rb).
  # One scan per request, not per example, because a spec that sends
  # many requests runs the same per-request lookups once each, and that
  # is not a repeat. Outermost, so the error reaches the spec instead of
  # a rescue further in. Only when RSpec is loaded: the e2e and
  # integration servers also run in this environment, and a scan costs
  # a backtrace per query.
  if defined?(RSpec)
    require 'prosopite/middleware/rack'
    config.middleware.insert_before(0, Prosopite::Middleware::Rack)
  end

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  config.action_mailer.perform_caching = false

  # Queue jobs into an array instead of running them. Without this the
  # adapter is :async, which runs jobs on background threads — and a
  # background thread that touches the database fights the single
  # connection RSpec pins to the running example. See
  # spec/support/solid_cache.rb for the version of that fight that hung CI.
  config.active_job.queue_adapter = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raises error for missing translations
  # config.action_view.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # The public addresses of the SPA and the admin, for links in feeds and
  # mail (ApiController#root_url, ApplicationMailer#root_url).
  config.x.root_url = 'http://localhost:3036'
  config.x.admin_root_url = 'http://admin.lvh.me:3000'
end
