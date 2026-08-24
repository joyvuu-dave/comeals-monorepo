# frozen_string_literal: true

require 'rails_helper'

# The cook mail after a settlement, as a job that can stop and start again
# without mailing anyone twice (#71).
RSpec.describe NotifyCooksJob do
  include ActiveJob::TestHelper

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:cooks) do
    %w[Ann Bob Cid].map { |name| create(:resident, community: community, unit: unit, multiplier: 2, name: name) }
  end
  let(:reconciliation) do
    cooks.each_with_index do |cook, i|
      meal = create(:meal, community: community, date: Date.yesterday - i)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: 2)
    end
    settle!(community)
  end

  before { allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) } # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain

  it 'mails every cook once and records each send' do
    described_class.perform_now(reconciliation)

    cooks.each do |cook|
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
    end
    expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to match_array(cooks.map(&:id))
  end

  it 'skips the cooks already mailed, so a second run sends nothing twice' do
    MailDelivery.record!(mailer: 'reconciliation_notify_email', about: reconciliation, resident: cooks[0])

    described_class.perform_now(reconciliation)
    described_class.perform_now(reconciliation)

    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email).with(cooks[0], reconciliation)
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cooks[1], reconciliation).once
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cooks[2], reconciliation).once
  end

  it 'does not record a send that failed, so the next run tries that cook again' do
    allow(ReconciliationMailer).to receive(:reconciliation_notify_email) do |cook, _|
      mail = instance_double(ActionMailer::MessageDelivery)
      allow(mail).to receive(:deliver_now) { raise Net::ReadTimeout if cook == cooks[1] }
      mail
    end
    allow(Rails.logger).to receive(:error)

    described_class.perform_now(reconciliation)

    expect(MailDelivery.where(about: reconciliation).pluck(:resident_id)).to contain_exactly(cooks[0].id, cooks[2].id)
  end

  it 'asks for another run when the per-run cap cut the list short' do
    stub_const('PacedDelivery::CAP', 2)
    allow(Rails.logger).to receive(:error)

    expect { described_class.perform_now(reconciliation) }.to have_enqueued_job(described_class).with(reconciliation)
    expect(MailDelivery.where(about: reconciliation).count).to eq(2)

    perform_enqueued_jobs
    expect(MailDelivery.where(about: reconciliation).count).to eq(3)
  end

  it 'has nothing to do for a reconciliation whose cooks were all mailed' do
    cooks.each do |cook|
      MailDelivery.record!(mailer: 'reconciliation_notify_email', about: reconciliation, resident: cook)
    end

    expect { described_class.perform_now(reconciliation) }.not_to have_enqueued_job
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
  end
end
