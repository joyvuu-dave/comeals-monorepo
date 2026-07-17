# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Healthcheck do
  describe '.monitor' do
    it 'runs the block and pings success' do
      allow(described_class).to receive(:ping)

      result = described_class.monitor('some-job') { :done }

      expect(result).to eq(:done)
      expect(described_class).to have_received(:ping).with('some-job')
    end

    it 'pings fail and re-raises when the block raises' do
      allow(described_class).to receive(:ping)

      expect { described_class.monitor('some-job') { raise 'boom' } }
        .to raise_error('boom')

      expect(described_class).to have_received(:ping).with('some-job', state: 'fail')
    end
  end

  describe '.ping' do
    it 'does nothing when HEALTHCHECKS_PING_KEY is not set' do
      allow(Net::HTTP).to receive(:start)

      described_class.ping('some-job')

      expect(Net::HTTP).not_to have_received(:start)
    end

    context 'with a ping key set' do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('HEALTHCHECKS_PING_KEY', nil).and_return('test-key')
      end

      it 'sends the ping over HTTPS with timeouts' do
        allow(Net::HTTP).to receive(:start).and_return(Net::HTTPOK.new('1.1', '200', 'OK'))

        described_class.ping('some-job')

        expect(Net::HTTP).to have_received(:start).with(
          'hc-ping.com', 443,
          use_ssl: true,
          open_timeout: described_class::OPEN_TIMEOUT,
          read_timeout: described_class::READ_TIMEOUT
        )
      end

      it 'warns when the ping is rejected' do
        rejected = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
        allow(Net::HTTP).to receive(:start).and_return(rejected)
        allow(Rails.logger).to receive(:warn)

        described_class.ping('some-job')

        expect(Rails.logger).to have_received(:warn).with(/some-job returned 404/)
      end

      it 'swallows network errors so a ping cannot break the job' do
        allow(Net::HTTP).to receive(:start).and_raise(Errno::ETIMEDOUT)
        allow(Rails.logger).to receive(:warn)

        expect { described_class.ping('some-job') }.not_to raise_error

        expect(Rails.logger).to have_received(:warn).with(/some-job/)
      end
    end
  end

  describe '.ping_uri' do
    it 'builds the success URL with auto-create' do
      uri = described_class.ping_uri('test-key', 'some-job', nil)

      expect(uri.to_s).to eq('https://hc-ping.com/test-key/some-job?create=1')
    end

    it 'builds the fail URL with auto-create' do
      uri = described_class.ping_uri('test-key', 'some-job', 'fail')

      expect(uri.to_s).to eq('https://hc-ping.com/test-key/some-job/fail?create=1')
    end
  end
end
