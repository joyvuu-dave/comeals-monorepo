# frozen_string_literal: true

require 'rails_helper'

# The three steps after a settlement commits — clear caches, refresh the
# running balances, mail the cooks — must all happen even when one of the
# outside services is down. The ledger is already written by then, so a
# raised error here would leave a settlement that happened with stale
# balances and no cook emails, a rake task that exits 1, and an API that
# answers 500 for a settlement that is in the database.
RSpec.describe SettleAndNotify do
  include ActiveJob::TestHelper

  # The cook mail is a job (NotifyCooksJob). Run it inline so these examples
  # see the whole of what a settlement does.
  around { |example| perform_enqueued_jobs { example.run } }

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:resident) { create(:resident, community: community, unit: unit, multiplier: 2) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2) }

  before do
    allow(ReconciliationMailer).to receive_message_chain(:reconciliation_notify_email, :deliver_now) # rubocop:disable RSpec/MessageChain -- stubbing mailer delivery chain
  end

  def settleable_meal(date)
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: resident, community: community, multiplier: 2)
    meal
  end

  it 'settles, refreshes balances, and mails the cooks' do
    settleable_meal(Date.yesterday)

    reconciliation = described_class.call(cutoff: Date.yesterday, community: community)

    expect(reconciliation).to be_persisted
    expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
    expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
  end

  context 'when Pusher is down' do
    before { allow(Pusher).to receive(:trigger).and_raise(Pusher::HTTPError, 'Pusher is down') }

    it 'still refreshes balances and mails the cooks, and reports the outage' do
      settleable_meal(Date.yesterday)
      allow(Rails.error).to receive(:report).and_call_original

      reconciliation = described_class.call(cutoff: Date.yesterday, community: community)

      expect(reconciliation).to be_persisted
      expect(ResidentBalance.find_by(resident_id: resident.id).amount).to eq(BigDecimal('0'))
      expect(ReconciliationMailer).to have_received(:reconciliation_notify_email).with(cook, reconciliation).once
      expect(Rails.error).to have_received(:report).with(an_instance_of(Pusher::HTTPError),
                                                         hash_including(handled: true)).at_least(:once)
    end

    it 'still clears every affected month from the calendar cache' do
      store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(store)
      # Two meals in two months, so the first month's failed push cannot
      # stop the second month's cache clear.
      settleable_meal(Date.yesterday)
      settleable_meal(Date.yesterday - 2.months)
      keys = [Date.yesterday, Date.yesterday - 2.months].map do |d|
        community.calendar_cache_key(d.year, d.month)
      end
      keys.each { |key| store.write(key, 'stale') }

      described_class.call(cutoff: Date.yesterday, community: community)

      keys.each { |key| expect(store.read(key)).to be_nil }
    end
  end

  it 'lets an error from the settlement itself through, so nothing is half done' do
    allow(Settlement).to receive(:run!).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

    expect { described_class.call(cutoff: Date.yesterday, community: community) }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect(ReconciliationMailer).not_to have_received(:reconciliation_notify_email)
  end
end
