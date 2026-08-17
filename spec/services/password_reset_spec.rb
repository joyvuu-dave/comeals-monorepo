# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PasswordReset do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, email: 'sarah@example.com') }

  describe '.request' do
    it 'returns :sent, stamps a token, and delivers the email' do
      result = nil
      expect { result = described_class.request(resident) }
        .to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(result).to eq(:sent)
      expect(resident.reload.reset_password_token).to be_present
      expect(resident.reset_password_sent_at).to be_present
    end

    it 'replaces an older token, so only the newest link works' do
      described_class.request(resident)
      first_token = resident.reload.reset_password_token

      described_class.request(resident)

      expect(resident.reload.reset_password_token).not_to eq(first_token)
    end

    context 'when the email cannot be delivered' do
      before do
        mail_double = instance_double(ActionMailer::MessageDelivery)
        allow(ResidentMailer).to receive(:password_reset_email).and_return(mail_double)
        allow(mail_double).to receive(:deliver_now).and_raise(Net::ReadTimeout)
      end

      it 'returns :mail_failed but keeps the token, so a retry can still send it' do
        expect(described_class.request(resident)).to eq(:mail_failed)
        expect(resident.reload.reset_password_token).to be_present
      end

      it 'logs the failure' do
        allow(Rails.logger).to receive(:error)

        described_class.request(resident)

        expect(Rails.logger).to have_received(:error)
          .with(/password_reset_email failed.*Net::ReadTimeout/)
      end

      it 'reports the failure through Rails.error, so Bugsnag alerts in production' do
        allow(Rails.error).to receive(:report)

        described_class.request(resident)

        expect(Rails.error).to have_received(:report)
          .with(instance_of(Net::ReadTimeout),
                hash_including(handled: true, context: { mailer: 'password_reset_email' }))
      end
    end

    context 'when the resident does not save' do
      it 'returns :save_failed and sends nothing' do
        allow(resident).to receive(:save).and_return(false)

        expect { expect(described_class.request(resident)).to eq(:save_failed) }
          .not_to(change { ActionMailer::Base.deliveries.count })
      end
    end
  end
end
