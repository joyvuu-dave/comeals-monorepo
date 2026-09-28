# frozen_string_literal: true

require 'rails_helper'

# The balances themselves are checked from the rake task, against the
# plain ledger and by hand (spec/tasks/billing_recalculate_*_spec.rb,
# settlement_matches_running_balance_spec.rb and
# stored_ledger_against_plain_ledger_spec.rb). This file checks what those
# cannot see: which meals are read, and how the cache rows are written.
RSpec.describe BalanceRecalculation do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater') }

  # A meal with no bill, or with nobody who ate, adds nothing to any
  # balance: every line it would give is zero. So the balances are the
  # same with or without them, and only the meals the ledger is given can
  # show that they are left out. Leaving them out keeps the nightly read
  # to the meals that can move money, not every upcoming meal people have
  # signed up for.
  it 'reads only the open meals that have a bill and someone who ate' do
    counted = create(:meal, community: community)
    create(:bill, meal: counted, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: counted, resident: eater, community: community)
    no_bill = create(:meal, community: community)
    create(:meal_resident, meal: no_bill, resident: eater, community: community)
    nobody_ate = create(:meal, community: community)
    create(:bill, meal: nobody_ate, resident: cook, community: community, amount: BigDecimal('25'))
    allow(MealLedger).to receive(:new).and_call_original

    described_class.call(community: community)

    expect(MealLedger).to have_received(:new).with([counted]).once
    expect(ResidentBalance.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('30'), eater.id => BigDecimal('-30'))
  end

  it 'replaces a stale balance in place, keeping the row and when it was first written' do
    meal = create(:meal, community: community)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
    create(:meal_resident, meal: meal, resident: eater, community: community)
    first_written = Time.zone.local(2026, 1, 5, 12, 0)
    stale = ResidentBalance.create!(resident: eater, amount: BigDecimal('5'),
                                    created_at: first_written, updated_at: first_written)

    expect(described_class.call(community: community)).to eq(2)

    stale.reload
    expect(stale.amount).to eq(BigDecimal('-30'))
    expect(stale.created_at).to eq(first_written)
    expect(stale.updated_at).to be > first_written
    expect(ResidentBalance.where(resident: eater).count).to eq(1)
  end

  it 'writes nothing, and says so, for a community with no residents' do
    expect(described_class.call(community: community)).to eq(0)
    expect(ResidentBalance.count).to eq(0)
  end
end
