# frozen_string_literal: true

require 'rails_helper'

# One report from the browser check (Api::V1::BrowserReportsController).
# A failed check, or a check that broke, alerts the owner through
# Rails.error, which Bugsnag emails. The alert is sent from the job, not
# from the request, so it carries no request data: Bugsnag's Rack
# middleware would add the IP address to anything reported during a
# request.
RSpec.describe BrowserReportJob do
  include ActiveJob::TestHelper

  let(:report) do
    { result: 'passed', tests: [], error: nil,
      browser: 'Safari', major: 15, os: 'iOS', device: 'phone',
      user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X)' }
  end

  before { allow(Rails.error).to receive(:report) }

  it 'sends no alert for a check that passed' do
    described_class.perform_now(**report)

    expect(Rails.error).not_to have_received(:report)
  end

  describe 'a check that failed' do
    before { described_class.perform_now(**report, result: 'failed', tests: %w[lookbehind color_mix]) }

    it 'alerts the owner, as an error so Bugsnag emails it' do
      expect(Rails.error).to have_received(:report)
        .with(an_instance_of(UnsupportedBrowserSeen), hash_including(handled: true, severity: :error)).once
    end

    it 'says which browser it was and which tests failed' do
      expect(Rails.error).to have_received(:report) do |error, context:, **|
        expect(error.message).to eq('Safari 15 on iOS (phone) failed the browser check: lookbehind, color_mix')
        expect(context).to include(browser: 'Safari', major: 15, os: 'iOS', device: 'phone',
                                   tests: %w[lookbehind color_mix],
                                   user_agent: report[:user_agent])
      end
    end

    # Bugsnag emails the first time it sees an error group. Grouped by
    # browser and failed tests, a new kind of old browser is a new email,
    # while the same kind seen again is not. The version is left out of
    # the group so a run of made-up versions cannot make a run of emails.
    it 'groups the alert by browser and failed tests, not by version' do
      expect(Rails.error).to have_received(:report) do |_error, context:, **|
        expect(context[:grouping_hash]).to eq('UnsupportedBrowserSeen Safari lookbehind,color_mix')
      end
    end
  end

  it 'says when the browser is not known' do
    described_class.perform_now(**report, result: 'failed', tests: %w[modules],
                                          browser: 'Unknown', major: nil, os: 'Unknown', device: 'unknown')

    expect(Rails.error).to have_received(:report) do |error, **|
      expect(error.message).to eq('Unknown on Unknown (unknown) failed the browser check: modules')
    end
  end

  it 'alerts the owner when the check itself broke, with its error' do
    described_class.perform_now(**report, result: 'error', error: 'TypeError: boom')

    expect(Rails.error).to have_received(:report) do |error, context:, severity:, **|
      expect(error).to be_an_instance_of(BrowserCheckBroke)
      expect(error.message).to eq('The browser check broke in Safari 15 on iOS (phone): TypeError: boom')
      expect(severity).to eq(:error)
      expect(context[:grouping_hash]).to eq('BrowserCheckBroke')
    end
  end
end
