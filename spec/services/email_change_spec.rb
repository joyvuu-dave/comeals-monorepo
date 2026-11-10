# frozen_string_literal: true

require 'rails_helper'

# What EmailChange's two senders give back, and what they report when a
# mail does not go out. The request specs (profiles_controller_spec.rb)
# show what a person sees; these check the answer each method gives its
# caller, and the report that tells an admin a mail failed.
RSpec.describe EmailChange do
  let(:community) { create(:community) }
  let(:resident) { create(:resident, community: community, email: 'ann@example.com') }
  let(:token) { described_class.start(resident, 'ann.new@example.com') }

  before do
    ActionMailer::Base.deliveries.clear
    allow(MailDeliveryFailure).to receive(:report)
  end

  def fail_the(mailer_method)
    allow(ResidentMailer).to receive(mailer_method).and_wrap_original do |original, *args|
      original.call(*args).tap { |mail| allow(mail).to receive(:deliver_now).and_raise(Net::ReadTimeout) }
    end
  end

  context 'when sending the link and the notice' do
    it 'answers :sent when both go out' do
      expect(described_class.send_emails(resident, token, 'ann@example.com')).to eq(:sent)
      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([['ann.new@example.com'], ['ann@example.com']])
    end

    it 'answers :mail_failed, and sends no notice, when the link does not go out' do
      fail_the(:email_change_link_email)

      expect(described_class.send_emails(resident, token, 'ann@example.com')).to eq(:mail_failed)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'answers :sent, and reports the notice with its address, when only the notice does not go out' do
      fail_the(:email_change_notice_email)

      expect(described_class.send_emails(resident, token, 'ann@example.com')).to eq(:sent)
      expect(MailDeliveryFailure).to have_received(:report).once
      expect(MailDeliveryFailure).to have_received(:report)
        .with(an_instance_of(Net::ReadTimeout), mailer: 'email_change_notice_email', recipient: 'ann@example.com')
    end
  end

  context 'when sending the link alone' do
    it 'answers :sent when it goes out' do
      expect(described_class.send_link(resident, token)).to eq(:sent)
      expect(MailDeliveryFailure).not_to have_received(:report)
    end

    it 'answers :mail_failed, and reports the link with the new address, when it does not go out' do
      fail_the(:email_change_link_email)

      expect(described_class.send_link(resident, token)).to eq(:mail_failed)
      expect(MailDeliveryFailure).to have_received(:report)
        .with(an_instance_of(Net::ReadTimeout), mailer: 'email_change_link_email', recipient: 'ann.new@example.com')
    end
  end
end
