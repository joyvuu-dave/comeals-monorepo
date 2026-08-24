# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PacedDelivery do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cooks) { Array.new(3) { create(:resident, community: community, unit: unit) } }

  def message_for(_cook)
    mail = instance_double(ActionMailer::MessageDelivery)
    allow(mail).to receive(:deliver_now)
    mail
  end

  describe 'when the delivery method is not smtp (test, dev, staging)' do
    it 'delivers each message with deliver_now, with no pause, and counts them' do
      messages = cooks.index_with { |cook| message_for(cook) }
      allow(described_class).to receive(:pause)

      result = described_class.deliver(cooks, mailer: 'reconciliation_notify_email') { |cook| messages[cook] }

      expect(result).to eq(described_class::Result.new(sent: 3, failed: 0, skipped: 0))
      messages.each_value { |mail| expect(mail).to have_received(:deliver_now).once }
      expect(described_class).not_to have_received(:pause)
    end

    it 'reports a failed message and goes on to the next person' do
      messages = cooks.index_with { |cook| message_for(cook) }
      allow(messages[cooks[1]]).to receive(:deliver_now).and_raise(Net::ReadTimeout)
      allow(MailDeliveryFailure).to receive(:report)

      result = described_class.deliver(cooks, mailer: 'reconciliation_notify_email') { |cook| messages[cook] }

      expect(result).to eq(described_class::Result.new(sent: 2, failed: 1, skipped: 0))
      expect(result).not_to be_complete
      expect(MailDeliveryFailure).to have_received(:report)
        .with(an_instance_of(Net::ReadTimeout), mailer: 'reconciliation_notify_email', recipient: cooks[1].email)
      expect(messages[cooks[2]]).to have_received(:deliver_now)
    end

    it 'stops at the per-run cap and counts the rest as skipped' do
      stub_const('PacedDelivery::CAP', 2)
      messages = cooks.index_with { |cook| message_for(cook) }
      allow(Rails.logger).to receive(:error)

      result = described_class.deliver(cooks, mailer: 'reconciliation_notify_email') { |cook| messages[cook] }

      expect(result).to eq(described_class::Result.new(sent: 2, failed: 0, skipped: 1))
      expect(messages[cooks[2]]).not_to have_received(:deliver_now)
      expect(Rails.logger).to have_received(:error).with(/cap of 2 reached, 1 not sent/)
    end
  end

  describe 'over smtp' do
    let(:session) { instance_double(Net::SMTP, send_message: nil) }
    let(:smtp) { instance_double(Net::SMTP, :enable_starttls_auto => nil, :open_timeout= => nil, :read_timeout= => nil) }

    before do
      allow(ActionMailer::Base).to receive_messages(
        delivery_method: :smtp,
        smtp_settings: { address: 'smtp.gmail.com', port: 587, domain: 'comeals.com', user_name: 'u', password: 'p',
                         authentication: 'plain', enable_starttls_auto: true, open_timeout: 30, read_timeout: 30 }
      )
      allow(Net::SMTP).to receive(:new).and_return(smtp)
      allow(smtp).to receive(:start).and_yield(session)
      allow(described_class).to receive(:pause)
    end

    it 'opens one session, sends every message over it, and pauses between messages' do
      messages = cooks.index_with do |cook|
        ActionMailer::MessageDelivery.new(ResidentMailer, :password_reset_email, cook.tap do |c|
          c.reset_password_token = 't'
        end)
      end

      result = described_class.deliver(cooks, mailer: 'x') { |cook| messages[cook] }

      expect(result).to eq(described_class::Result.new(sent: 3, failed: 0, skipped: 0))
      expect(Net::SMTP).to have_received(:new).once.with('smtp.gmail.com', 587)
      expect(smtp).to have_received(:start).once.with('comeals.com', 'u', 'p', :plain)
      expect(session).to have_received(:send_message).exactly(3).times
      expect(session).to have_received(:send_message).with(anything, 'admin@comeals.com', [cooks.first.email]).once
      expect(described_class).to have_received(:pause).exactly(2).times
    end

    it 'counts every message as failed when the session cannot be opened, and reports once' do
      allow(smtp).to receive(:start).and_raise(Net::SMTPAuthenticationError.new('535 bad credentials'))
      allow(MailDeliveryFailure).to receive(:report)

      result = described_class.deliver(cooks, mailer: 'x') { |cook| message_for(cook) }

      expect(result).to eq(described_class::Result.new(sent: 0, failed: 3, skipped: 0))
      expect(MailDeliveryFailure).to have_received(:report).once.with(an_instance_of(Net::SMTPAuthenticationError),
                                                                      mailer: 'x')
    end
  end
end
