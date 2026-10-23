# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PasswordReset do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, email: 'sarah@example.com') }

  describe '.request' do
    # The token in the link of the last email sent.
    def mailed_token
      ActionMailer::Base.deliveries.last.text_part.body.decoded[/reset-password\S*?([\w-]{43})/, 1]
    end

    it 'returns :sent, stores the digest of the mailed token, and delivers the email' do
      result = nil
      expect { result = described_class.request(resident) }
        .to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(result).to eq(:sent)
      expect(resident.reload.reset_password_token_digest).to eq(Digest::SHA256.hexdigest(mailed_token))
      expect(resident.reset_password_sent_at).to be_present
    end

    # 32 random bytes, which urlsafe base64 writes as 43 characters.
    it 'mails a token of 32 random bytes' do
      described_class.request(resident)

      expect(Base64.urlsafe_decode64(mailed_token).bytesize).to eq(32)
    end

    it 'replaces an older token, so only the newest link works' do
      described_class.request(resident)
      first_token = mailed_token

      described_class.request(resident)

      expect(mailed_token).not_to eq(first_token)
      expect(resident.reload.reset_password_token_digest).to eq(described_class.digest(mailed_token))
    end

    context 'when the email cannot be delivered' do
      before do
        mail_double = instance_double(ActionMailer::MessageDelivery)
        allow(ResidentMailer).to receive(:password_reset_email).and_return(mail_double)
        allow(mail_double).to receive(:deliver_now).and_raise(Net::ReadTimeout)
      end

      it 'returns :mail_failed but keeps the token, so a retry can still send it' do
        expect(described_class.request(resident)).to eq(:mail_failed)
        expect(resident.reload.reset_password_token_digest).to be_present
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

    # Inside `.request`, so mutant runs it for that method: a group
    # described by a sentence is not selected for any method.
    describe 'a failure report' do
      it 'names the mailer and the person the mail was for' do
        allow(ResidentMailer).to receive(:password_reset_email)
          .and_return(instance_double(ActionMailer::MessageDelivery).tap { |m|
                        allow(m).to receive(:deliver_now).and_raise(Net::SMTPServerBusy, '451 try later')
                      })
        allow(MailDeliveryFailure).to receive(:report)

        expect(described_class.request(resident)).to eq(:mail_failed)
        expect(MailDeliveryFailure).to have_received(:report)
          .with(an_instance_of(Net::SMTPServerBusy), mailer: 'password_reset_email', recipient: resident.email)
      end
    end
  end

  describe '.resident_for' do
    it 'finds the resident a token belongs to' do
      token = give_reset_token(resident)

      expect(described_class.resident_for(token)).to eq(resident)
    end

    it 'finds nobody for a token no resident has' do
      give_reset_token(resident)

      expect(described_class.resident_for(SecureRandom.urlsafe_base64(32))).to be_nil
    end

    # The digest is what the table holds. Sending it in place of the token
    # must not work, or the digest would be as good as the token.
    it 'finds nobody for the digest itself' do
      token = give_reset_token(resident)

      expect(described_class.resident_for(described_class.digest(token))).to be_nil
    end

    # A JSON body can send anything. A resident with no reset under way
    # has no digest, and nothing sent may match that.
    it 'finds nobody for a value that is not a token' do
      create(:resident, community: community, unit: unit, email: 'nobody-reset@example.com')
      give_reset_token(resident)

      [nil, '', 123, ['x'], { 'a' => 'b' }].each do |value|
        expect(described_class.resident_for(value)).to be_nil, "found someone for #{value.inspect}"
      end
    end
  end

  describe '.digest' do
    # The test value from FIPS 180-2, appendix B.1.
    it 'is the SHA-256 of the token, in lowercase hex' do
      expect(described_class.digest('abc')).to eq('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    end
  end
end
