# typed: true
# frozen_string_literal: true

# Sends everything reported through Rails.error to Bugsnag.
#
# Rails has two separate paths for an exception, and Bugsnag's Rack
# middleware only sees one of them:
#
#   raised and not rescued  -> the middleware catches it. Already covered.
#   Rails.error.report(...) -> goes to ActiveSupport::ErrorReporter, which
#                              sends it to whatever has subscribed. Without
#                              a subscriber it goes nowhere at all.
#
# The second path is the one that matters for the money code. It is how a
# failure that we caught and handled still gets counted — a retried
# transaction, a swallowed cache failure. Those are not crashes, so nothing
# else will ever tell us they happened, and "how often does this fire" is
# exactly the question we need answered when a retry goes in.
#
# It already has one live producer: solid_cache's failsafe calls
# ActiveSupport.error_reporter.report on every cache error it swallows
# (solid_cache/store/failsafe.rb). Until this subscriber existed, that call
# reported into nothing.
#
# The bugsnag gem (6.30.0) ships no such subscriber, so this is it. It is in
# lib/ rather than app/ because an initializer must not reference an
# autoloaded constant.
class BugsnagErrorSubscriber
  # ActiveSupport::ErrorReporter calls this. `source` is a string naming what
  # reported the error, e.g. "application" or "solid_cache".
  def report(error, handled:, severity:, context:, source: nil)
    Bugsnag.notify(error) do |report|
      # Rails uses :error, :warning and :info; Bugsnag uses the same three
      # words as strings. Anything unexpected becomes an error rather than
      # being dropped or raising inside the reporter.
      report.severity = %i[error warning info].include?(severity) ? severity.to_s : 'error'

      # Bugsnag decides handled vs unhandled itself: anything sent through
      # notify is handled, and report.unhandled is read-only. Everything
      # here came through Rails.error, so `handled` is real information
      # about how the application treated it, and it belongs in the report
      # rather than being thrown away.
      report.add_tab(:rails_error, { handled: handled, source: source }.merge(context || {}))
    end
  end
end
