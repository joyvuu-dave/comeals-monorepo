# frozen_string_literal: true

require 'rails_helper'

# A dinner from a settlement made before line items existed (2026-08-02).
# Such a settlement has no meal_charges rows, on purpose
# (docs/money-path-observability.md, "Backfill, or not"); in production
# settlement 6 is one, and stays one after the October 2026 deploy. The
# nightly check skips its line item and dinner checks, and keeps the
# recompute check.
#
# ADR 0011 rule 10 says that once the old history is closed, every later
# mistake goes through rule 6: a correction in the next settlement. So a
# superuser must be able to correct a dinner of such a settlement.
#
# Bug hunt 2026-10-16 (money). MealCorrecting compares the dinner's rows
# with its stored lines (SettledDinnerDifference) whatever the settlement,
# so with no stored lines every person on the dinner reads as a
# difference, and the correction is refused with EarlierDifference. Its
# message says "The nightly ledger check reports it", and the nightly
# check reports nothing.
RSpec.describe MealCorrecting do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:admin) { create(:admin_user, community: community, superuser: true) }
  let(:cook) { create(:resident, community: community, unit: unit, name: 'Cook') }
  let(:eater) { create(:resident, community: community, unit: unit, name: 'Eater') }

  # A $30 dinner with one cook and one eater, settled, and then its line
  # items taken off with the repair bypass: the state of a settlement made
  # before line items existed.
  let!(:meal) do
    create(:meal, community: community, date: latest - 5).tap do |meal|
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
      reconciliation = settle!(cutoff: latest - 5)
      with_repair_bypass { MealCharge.for_reconciliation(reconciliation).delete_all }
      meal.reload
    end
  end

  it 'corrects a dinner from a settlement made before line items existed' do
    expect(LedgerVerification.call).to be_passed

    correction = described_class.save!(meal, by: admin, reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end

    expect(correction.lines.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
    second = settle!(cutoff: latest)
    expect(second.reconciliation_balances.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
    expect(LedgerVerification.call).to be_passed
  end
end
