# frozen_string_literal: true

require 'rails_helper'

# The same seam as spec/requests/api/v1/live_update_cache_clear_refused_spec.rb,
# on the settlement path. Settlement#settle! commits the ledger and then
# runs forget_cached_meals, which clears the calendar cache through
# LiveUpdate. SettleAndNotify wraps the whole of Settlement.run! in
# RetryOnConflict. So a cache clear refused for a serialization conflict
# after the commit is retried as if the settlement had been rolled back:
# Settlement.run! runs again, finds every meal already claimed, and its
# Reconciliation row fails validation. The settlement is in the database,
# but SettleAndNotify raises, so the running balances are not refreshed
# and the cook mail is never enqueued (the nightly task fails; the API and
# the admin form show an error for a period that was settled).
#
# The refusal is simulated with a stub; see the request spec for why.
#
# Invariant hunt, 2026-09-21. Red when written: a finding.
RSpec.describe SettleAndNotify do
  include_context 'with no test transaction'

  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, multiplier: 2, name: 'Eater') }

  before do
    meal = create(:meal, community: community, date: Date.yesterday - 1)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
    create(:meal_resident, meal: meal, resident: cook, community: community)
    create(:meal_resident, meal: meal, resident: eater, community: community)

    calls = 0
    allow(Rails.cache).to receive(:delete).and_wrap_original do |original, *args|
      calls += 1
      if calls == 1
        raise ActiveRecord::SerializationFailure,
              'PG::TRSerializationFailure: ERROR:  could not serialize access due to read/write ' \
              'dependencies among transactions'
      end

      original.call(*args)
    end
  end

  it 'settles once, refreshes the balances and enqueues the cook mail when a cache clear after the commit is refused' do
    reconciliation = nil

    expect do
      reconciliation = described_class.call(cutoff: Date.yesterday, community: community,
                                            retries: described_class::REQUEST)
    end.to change(Reconciliation, :count).by(1)

    expect(reconciliation).to be_a(Reconciliation)
    expect(NotifyCooksJob).to have_been_enqueued.with(reconciliation)
  end
end
