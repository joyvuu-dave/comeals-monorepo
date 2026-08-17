# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailDeliveryFailure do
  describe '.report' do
    let(:error) { Net::ReadTimeout.new }

    it 'logs the mailer, the recipient, and the error' do
      allow(Rails.logger).to receive(:error)

      described_class.report(error, mailer: 'password_reset_email', recipient: 'sarah@example.com')

      expect(Rails.logger).to have_received(:error)
        .with('password_reset_email failed for sarah@example.com: Net::ReadTimeout - Net::ReadTimeout')
    end

    it 'logs without a recipient when there is none' do
      allow(Rails.logger).to receive(:error)

      described_class.report(error, mailer: 'common_house_collection_email')

      expect(Rails.logger).to have_received(:error)
        .with('common_house_collection_email failed: Net::ReadTimeout - Net::ReadTimeout')
    end

    it 'reports through Rails.error, with the mailer name but never the address' do
      allow(Rails.error).to receive(:report)

      described_class.report(error, mailer: 'new_rotation_email', recipient: 'sarah@example.com')

      expect(Rails.error).to have_received(:report).with(
        error, handled: true, severity: :error, source: 'mailer', context: { mailer: 'new_rotation_email' }
      )
    end
  end
end
