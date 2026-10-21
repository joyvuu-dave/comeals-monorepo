# typed: true
# frozen_string_literal: true

# One report from the browser check, queued by
# Api::V1::BrowserReportsController. It counts the page load in
# browser_counts, and a failed or broken check also alerts the owner.
#
# A check that failed means a resident saw the "too old" or "cookies"
# message, and a check that broke means a mistake in the check. Either
# alerts the owner through Rails.error, which Bugsnag emails. The alert
# is sent from here, not from the request, so it carries no request data
# and so no IP address.
#
# The count is written here, not in the request, so it can never slow or
# fail anything a person waits for. Two page loads of the same kind of
# browser at the same moment write the same row, and at SERIALIZABLE the
# second is refused, so the write is retried at once (RetryOnConflict),
# and a write that still fails is tried again a few seconds later and
# then reported, never raised. The alert goes on the first try only, so a
# retry does not send it again.
class BrowserReportJob < ApplicationJob
  extend T::Sig

  ATTEMPTS = 3
  WAIT = 5.seconds

  # A batch job: nobody waits on it, so it can afford more tries than a
  # request (the same numbers as RecurringJob).
  CONFLICT_ATTEMPTS = 5
  CONFLICT_BASE_DELAY = 0.25

  retry_on StandardError, wait: WAIT, attempts: ATTEMPTS do |job, error|
    Rails.error.report(error, handled: true, context: { browser_report: job.arguments.first&.slice(:date, :result) })
  end

  # rubocop:disable Metrics/ParameterLists -- one keyword per field of the report
  sig do
    params(date: Date, result: String, tests: T::Array[String], error: T.nilable(String),
           browser: String, major: T.nilable(Integer), os: String, device: String,
           user_agent: String).void
  end
  def perform(date:, result:, tests:, error:, browser:, major:, os:, device:, user_agent:)
    # rubocop:enable Metrics/ParameterLists
    if executions == 1
      alert(result, tests, error,
            { browser: browser, major: major, os: os, device: device, tests: tests, user_agent: user_agent })
    end

    RetryOnConflict.call(attempts: CONFLICT_ATTEMPTS, base_delay: CONFLICT_BASE_DELAY) do
      BrowserCount.add_one!(date:, browser:, major:, os:, device:, result:)
    end
  end

  private

  sig do
    params(result: String, tests: T::Array[String], error: T.nilable(String),
           context: T::Hash[Symbol, T.untyped]).void
  end
  def alert(result, tests, error, context)
    description = "#{[context[:browser], context[:major]].compact.join(' ')} on #{context[:os]} (#{context[:device]})"
    case result
    when 'failed'
      report(UnsupportedBrowserSeen.new("#{description} failed the browser check: #{tests.join(', ')}"),
             context.merge(grouping_hash: "UnsupportedBrowserSeen #{context[:browser]} #{tests.join(',')}"))
    when 'error'
      report(BrowserCheckBroke.new("The browser check broke in #{description}: #{error}"),
             context.merge(grouping_hash: 'BrowserCheckBroke'))
    end
  end

  # :error, so Bugsnag treats it as one and emails it. Rails.error.report
  # would make a handled error a :warning.
  sig { params(error: StandardError, context: T::Hash[Symbol, T.untyped]).void }
  def report(error, context)
    Rails.error.report(error, handled: true, severity: :error, context: context)
  end
end
