# typed: true
# frozen_string_literal: true

# One report from the browser check, queued by
# Api::V1::BrowserReportsController.
#
# A check that failed means a resident saw the "too old" or "cookies"
# message, and a check that broke means a mistake in the check. Either
# alerts the owner through Rails.error, which Bugsnag emails. The alert
# is sent from here, not from the request, so it carries no request data
# and so no IP address.
class BrowserReportJob < ApplicationJob
  extend T::Sig

  # rubocop:disable Metrics/ParameterLists -- one keyword per field of the report
  sig do
    params(result: String, tests: T::Array[String], error: T.nilable(String),
           browser: String, major: T.nilable(Integer), os: String, device: String,
           user_agent: String).void
  end
  def perform(result:, tests:, error:, browser:, major:, os:, device:, user_agent:)
    # rubocop:enable Metrics/ParameterLists
    description = "#{[browser, major].compact.join(' ')} on #{os} (#{device})"
    context = { browser: browser, major: major, os: os, device: device, tests: tests, user_agent: user_agent }

    case result
    when 'failed'
      alert(UnsupportedBrowserSeen.new("#{description} failed the browser check: #{tests.join(', ')}"),
            context.merge(grouping_hash: "UnsupportedBrowserSeen #{browser} #{tests.join(',')}"))
    when 'error'
      alert(BrowserCheckBroke.new("The browser check broke in #{description}: #{error}"),
            context.merge(grouping_hash: 'BrowserCheckBroke'))
    end
  end

  private

  # :error, so Bugsnag treats it as one and emails it. Rails.error.report
  # would make a handled error a :warning.
  sig { params(error: StandardError, context: T::Hash[Symbol, T.untyped]).void }
  def alert(error, context)
    Rails.error.report(error, handled: true, severity: :error, context: context)
  end
end
