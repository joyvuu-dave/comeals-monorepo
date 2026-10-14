# frozen_string_literal: true

require 'rails_helper'

# ADR 0011 rule 4: the admin form shows a preview, and its Create button
# sends the preview's fingerprint. The settlement then refuses to commit
# anything the preview did not show (Settlement.fingerprint), because a
# cook may change a cost, or someone may sign up, between the two.
RSpec.describe Settlement do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  # The latest cutoff a settlement may have, 14 days back (ADR 0011 rule 2).
  let(:latest) { Reconciliation.latest_cutoff(community.today) }
  let(:cook) { create(:resident, community: community, unit: unit) }
  let(:eater) { create(:resident, community: community, unit: unit) }

  def dinner(date, cost:, eaters: [eater])
    meal = create(:meal, community: community, date: date)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal(cost.to_s))
    eaters.each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
    meal
  end

  def fingerprint(cutoff = latest)
    described_class.preview(cutoff: cutoff).fingerprint
  end

  def expect_nothing_settled
    expect(Reconciliation.count).to eq(0)
    expect(MealCharge.count).to eq(0)
    expect(ReconciliationBalance.count).to eq(0)
    expect(Meal.where.not(reconciliation_id: nil)).not_to exist
  end

  describe 'settling with the fingerprint of a preview' do
    it 'settles what the preview showed when nothing changed' do
      meal = dinner(latest, cost: 30)

      settlement = described_class.settle!(cutoff: latest, fingerprint: fingerprint)

      expect(settlement.reconciliation.meals).to contain_exactly(meal)
      expect(ReconciliationBalance.pluck(:resident_id, :amount))
        .to contain_exactly([cook.id, BigDecimal('30')], [eater.id, BigDecimal('-30')])
    end

    it 'refuses, and writes nothing, when a cost changed after the preview' do
      meal = dinner(latest, cost: 30)
      code = fingerprint
      meal.bills.sole.update!(amount: BigDecimal('31'))

      expect { described_class.settle!(cutoff: latest, fingerprint: code) }
        .to raise_error(described_class::Changed, 'The dinners or amounts changed after the preview was made, ' \
                                                  'so nothing was settled.')
      expect_nothing_settled
    end

    it 'refuses when someone signed up after the preview' do
      meal = dinner(latest, cost: 30)
      code = fingerprint
      create(:meal_resident, meal: meal, resident: create(:resident, community: community, unit: unit),
                             community: community)

      expect { described_class.settle!(cutoff: latest, fingerprint: code) }.to raise_error(described_class::Changed)
      expect_nothing_settled
    end

    # The amounts of the dinners it showed are the same; one more dinner
    # would be settled.
    it 'refuses when a dinner that waited for a cost can settle after the preview' do
      dinner(latest - 1, cost: 30)
      waiting = dinner(latest, cost: 0)
      code = fingerprint
      waiting.bills.sole.update!(no_cost: true)

      expect { described_class.settle!(cutoff: latest, fingerprint: code) }.to raise_error(described_class::Changed)
      expect_nothing_settled
    end

    it 'refuses when a dinner it showed waits for a cost after the preview' do
      dinner(latest - 1, cost: 30)
      later = dinner(latest, cost: 20)
      code = fingerprint
      later.bills.sole.update!(amount: BigDecimal('0'))

      expect { described_class.settle!(cutoff: latest, fingerprint: code) }.to raise_error(described_class::Changed)
      expect_nothing_settled
    end

    it 'refuses the fingerprint of a preview for another cutoff, even with the same dinners' do
      dinner(latest - 1, cost: 30)

      expect { described_class.settle!(cutoff: latest, fingerprint: fingerprint(latest - 1)) }
        .to raise_error(described_class::Changed)
      expect_nothing_settled
    end

    # A dinner nobody ate settles with no money, and the settlement writes
    # no lines for it, while the preview's ledger has a $0 line for its
    # cook. The fingerprint is made from the balances, which agree.
    it 'settles a dinner nobody ate, which the preview shows with a line the settlement does not write' do
      eaten = dinner(latest - 1, cost: 30)
      uneaten = dinner(latest, cost: 0, eaters: [])

      settlement = described_class.settle!(cutoff: latest, fingerprint: fingerprint)

      expect(settlement.reconciliation.meals).to contain_exactly(eaten, uneaten)
    end
  end

  # The task and the API settle what is there when they run.
  describe 'settling with no fingerprint' do
    it 'settles what is there now, whatever changed since a preview' do
      meal = dinner(latest, cost: 30)
      fingerprint
      meal.bills.sole.update!(amount: BigDecimal('31'))

      described_class.settle!(cutoff: latest)

      expect(ReconciliationBalance.find_by(resident: cook).amount).to eq(BigDecimal('31'))
    end
  end

  describe 'the fingerprint' do
    let(:balances) { { 5 => BigDecimal('1.5'), 3 => BigDecimal('-1.5') } }
    let(:base) do
      described_class.fingerprint(cutoff: latest, meal_ids: [1, 2], correction_ids: [3], balances: balances)
    end

    it 'leaves out $0 balances, which a settlement does not store, and does not depend on order' do
      same = described_class.fingerprint(cutoff: latest, meal_ids: [2, 1], correction_ids: [3],
                                         balances: { 9 => BigDecimal('0'), 3 => BigDecimal('-1.50'),
                                                     5 => BigDecimal('1.50') })

      expect(same).to eq(base)
    end

    it 'differs for another cutoff, another dinner, another correction, another amount, or another person' do
      others = [
        described_class.fingerprint(cutoff: latest - 1, meal_ids: [1, 2], correction_ids: [3], balances: balances),
        described_class.fingerprint(cutoff: latest, meal_ids: [1], correction_ids: [3], balances: balances),
        described_class.fingerprint(cutoff: latest, meal_ids: [1, 2], correction_ids: [], balances: balances),
        described_class.fingerprint(cutoff: latest, meal_ids: [1, 2], correction_ids: [3],
                                    balances: { 5 => BigDecimal('1.51'), 3 => BigDecimal('-1.51') }),
        described_class.fingerprint(cutoff: latest, meal_ids: [1, 2], correction_ids: [3],
                                    balances: { 6 => BigDecimal('1.5'), 3 => BigDecimal('-1.5') })
      ]

      expect(others.uniq.size).to eq(5)
      expect(others).not_to include(base)
    end
  end
end
