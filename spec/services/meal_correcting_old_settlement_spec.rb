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
# Bug hunt 2026-10-16 (money): MealCorrecting compared the dinner's rows
# with its stored lines whatever the settlement, so with no stored lines
# every person on the dinner read as a difference, and the correction was
# refused, with a message that said the nightly check reported it. Now
# such a dinner is checked the way the nightly check checks it: the
# whole settlement, recomputed.
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

  # In production every settlement after the old ones has line items. The
  # question is whether this dinner's own settlement has them, not
  # whether any settlement does.
  it 'corrects such a dinner when a later settlement has line items' do
    later = create(:meal, community: community, date: latest)
    create(:bill, meal: later, resident: cook, community: community, amount: BigDecimal('12'))
    create(:meal_resident, meal: later, resident: eater, community: community)
    expect(MealCharge.for_reconciliation(settle!(cutoff: latest))).to exist

    correction = described_class.save!(meal, by: admin, reason: 'Typed $30 for $20') do |edits|
      edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
    end

    expect(correction.lines.pluck(:resident_id, :amount).to_h)
      .to eq(cook.id => BigDecimal('-10'), eater.id => BigDecimal('10'))
  end

  # A change no correction explains, made with the repair bypass: the
  # nightly check's recompute check reports it, so the correction is
  # refused, as for a dinner of any other settlement.
  it 'refuses a dinner of such a settlement when the settlement already differs from its rows' do
    with_repair_bypass { Bill.where(meal_id: meal.id).update_all(amount: BigDecimal('40')) }

    expect do
      described_class.save!(meal, by: admin, reason: 'Typed $30 for $20') do |edits|
        edits.cost(cook, amount: BigDecimal('20'), no_cost: false)
      end
    end.to raise_error(described_class::EarlierDifference, /made before line items existed, and that settlement/)
    expect(MealCorrection.count).to eq(0)
  end
end
