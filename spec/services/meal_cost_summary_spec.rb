# frozen_string_literal: true

require 'rails_helper'

# The display face of the money arithmetic. Open meals compute through
# MealLedger; settled meals read their stored meal_charges. These specs
# carry the display-path cases that used to live on Meal's deleted
# total_cost / effective_total_cost / unit_cost / subsidized? methods.
RSpec.describe MealCostSummary do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  def capped_setup(cap)
    capped_community = create(:community, cap: BigDecimal(cap))
    [capped_community, create(:unit, community: capped_community)]
  end

  describe 'an open meal (through MealLedger)' do
    it 'sums bill amounts, excluding no_cost bills' do
      meal = create(:meal, community: community)
      resident_a = create(:resident, community: community, unit: unit, multiplier: 2)
      resident_b = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident_a, community: community)
      create(:bill, meal: meal, resident: resident_a, community: community, amount: BigDecimal('30'))
      create(:bill, meal: meal, resident: resident_b, community: community, amount: BigDecimal('20'),
                    no_cost: true)
      meal.reload

      summary = described_class.for(meal)
      expect(summary.total_cost).to eq(BigDecimal('30'))
      expect(summary.total_cost).to be_a(BigDecimal)
    end

    it 'reports zeros for a meal with no bills' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      meal.reload

      summary = described_class.for(meal)
      expect(summary.total_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
    end

    it 'divides the effective cost by the multiplier for unit cost' do
      meal = create(:meal, community: community)
      resident_a = create(:resident, community: community, unit: unit, multiplier: 2)
      resident_b = create(:resident, community: community, unit: unit, multiplier: 1)
      create(:meal_resident, meal: meal, resident: resident_a, community: community)
      create(:meal_resident, meal: meal, resident: resident_b, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      # multiplier = 3, effective cost = 30, unit cost = 10
      summary = described_class.for(meal)
      expect(summary.unit_cost).to eq(BigDecimal('10'))
      expect(summary.unit_cost).to be_a(BigDecimal)
    end

    it 'reports zero unit cost when the multiplier is zero (cook absorbs the cost)' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      summary = described_class.for(meal)
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be false
    end

    it 'keeps the effective cost at the total when capped but under the cap' do
      capped_community, capped_unit = capped_setup('25')
      meal = create(:meal, community: capped_community)
      resident = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident, community: capped_community)
      create(:bill, meal: meal, resident: resident, community: capped_community, amount: BigDecimal('10'))
      meal.reload

      # cap allows 25 * 2 = 50; total 10 is under it
      summary = described_class.for(meal)
      expect(summary.effective_cost).to eq(BigDecimal('10'))
      expect(summary.subsidized).to be false
    end

    it 'caps the effective cost and reports subsidized when the cooks spent more' do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      resident_a = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      resident_b = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident_a, community: capped_community)
      create(:bill, meal: meal, resident: resident_a, community: capped_community, amount: BigDecimal('4'))
      create(:bill, meal: meal, resident: resident_b, community: capped_community, amount: BigDecimal('6'))
      meal.reload

      # cap allows 2.50 * 2 = 5.00; the cooks spent 10
      summary = described_class.for(meal)
      expect(summary.total_cost).to eq(BigDecimal('10'))
      expect(summary.effective_cost).to eq(BigDecimal('5'))
      expect(summary.unit_cost).to eq(BigDecimal('2.5'))
      expect(summary.subsidized).to be true
    end

    it 'is not subsidized when uncapped, whatever the cooks spent' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: resident, community: community)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('100'))
      meal.reload

      summary = described_class.for(meal)
      expect(summary.effective_cost).to eq(BigDecimal('100'))
      expect(summary.subsidized).to be false
    end
  end

  describe 'a settled meal (from stored charges)' do
    it 'reads the stored charges, not the live bills' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      settle!(community, cutoff: Date.yesterday)

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('16'))
      expect(summary.effective_cost).to eq(BigDecimal('16'))
      expect(summary.unit_cost).to eq(BigDecimal('8'))
      expect(summary.subsidized).to be false
    end

    it 'is immune to a later cap change — the numbers the settlement used, forever' do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('10'))
      settle!(capped_community, cutoff: Date.yesterday)

      settled = described_class.for(meal.reload)
      expect(settled.effective_cost).to eq(BigDecimal('5'))
      expect(settled.subsidized).to be true

      # The cap is raised later. The settled meal's numbers must not move —
      # recomputing them live was the bug this class exists to fix.
      capped_community.update!(cap: BigDecimal('100'))
      expect(described_class.for(meal.reload).effective_cost).to eq(BigDecimal('5'))
      expect(described_class.for(meal.reload).subsidized).to be true
    end

    it 'shows the receipts and zero charges for a meal nobody attended' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      settle!(community, cutoff: Date.yesterday)

      # Swept, but no lines on purpose: nobody was charged, the cook
      # absorbed the receipts.
      summary = described_class.for(meal.reload)
      expect(meal.meal_charges).to be_empty
      expect(summary.total_cost).to eq(BigDecimal('40'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
    end

    it 'returns nil for a settlement from before line items existed' do
      # The reconciliation first — the factory sweeps every eligible meal
      # on create, and this meal must end up reconciled WITHOUT charges.
      reconciliation = create(:reconciliation, community: community)

      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))

      # A pre-2026-08-02 settlement: reconciled, attendance, no charge rows.
      meal.update_columns(reconciliation_id: reconciliation.id)

      expect(described_class.for(meal.reload)).to be_nil
    end
  end
end
