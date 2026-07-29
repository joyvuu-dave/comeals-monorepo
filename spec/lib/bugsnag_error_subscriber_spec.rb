# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BugsnagErrorSubscriber do
  # A stand-in for Bugsnag::Report. The real class needs a configuration
  # object to build, and none of what this subscriber does to it depends on
  # that — it sets a severity and adds one tab.
  let(:report) { instance_double(Bugsnag::Report, :severity= => nil, add_tab: nil) }
  let(:error) { RuntimeError.new('boom') }

  def report_error(handled: true, severity: :error, context: {}, **)
    allow(Bugsnag).to receive(:notify).and_yield(report)
    described_class.new.report(error, handled: handled, severity: severity, context: context, **)
  end

  it 'sends the error to Bugsnag' do
    report_error

    expect(Bugsnag).to have_received(:notify).with(error)
  end

  describe 'severity' do
    it 'passes through the three severities Rails uses' do
      %i[error warning info].each do |severity|
        report_error(severity: severity)
        expect(report).to have_received(:severity=).with(severity.to_s)
      end
    end

    # Reporting must never be the thing that raises. An unknown severity
    # becomes an error rather than blowing up inside the error reporter,
    # which would turn a handled problem into an unhandled one.
    it 'falls back to error for a severity Bugsnag does not know' do
      report_error(severity: :critical)

      expect(report).to have_received(:severity=).with('error')
    end
  end

  describe 'metadata' do
    it 'records whether the application handled the error' do
      report_error(handled: false)

      expect(report).to have_received(:add_tab).with(:rails_error, hash_including(handled: false))
    end

    # solid_cache reports with source: "solid_cache". Keeping the source
    # means a cache failure is distinguishable from an application one
    # without reading the backtrace.
    it 'records the source' do
      report_error(source: 'solid_cache')

      expect(report).to have_received(:add_tab).with(:rails_error, hash_including(source: 'solid_cache'))
    end

    it 'merges the reporter context' do
      report_error(context: { attempt: 3 })

      expect(report).to have_received(:add_tab).with(:rails_error, hash_including(attempt: 3))
    end

    it 'survives a nil context' do
      expect { report_error(context: nil) }.not_to raise_error
    end
  end

  # BUGSNAG_API_KEY is set on Heroku and nowhere else, so the initializer
  # configures nothing and subscribes nothing during a spec run. Pinned
  # because the cost of getting it wrong is a test suite that reports its
  # own deliberate failures to production error tracking.
  describe 'wiring in the test environment' do
    it 'is not subscribed to Rails.error' do
      subscribers = Rails.error.instance_variable_get(:@subscribers) || []

      expect(subscribers.map(&:class)).not_to include(described_class)
    end

    it 'leaves Bugsnag without an API key' do
      expect(Bugsnag.configuration.api_key).to be_nil
    end
  end
end
