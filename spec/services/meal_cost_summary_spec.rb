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

    # Nobody with a price ate, so nobody can be charged and the cook is
    # credited nothing. "Subsidized" means the cooks were credited less
    # than they spent, for any reason, so this meal is subsidized (#94).
    it 'reports zero unit cost when the multiplier is zero, and subsidized (the cook absorbs the cost)' do
      meal = create(:meal, community: community)
      resident = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: resident, community: community, amount: BigDecimal('50'))

      summary = described_class.for(meal)
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # MODELS.md: total_cost is what the cooks spent. With no multiplier to
    # share the cost, it is still what they spent, not $0 (#94).
    it 'reports what the cooks spent as the total cost when the multiplier is zero' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      expect(described_class.for(meal).total_cost).to eq(BigDecimal('50'))
    end

    it 'shows what the cook spent, and subsidized, on an open meal only a free eater ate' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('25'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # The cook spent nothing, so the cook was not credited less than they
    # spent.
    it 'is not subsidized when only a free eater ate and the cook slot holds no money' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('0'))
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
    # A settled meal nobody ate gets no charges; the summary then shows
    # what the cooks spent, from the bills, and a no-cost bill spends
    # nothing whatever amount was left on it. The cook was credited
    # nothing for the $10, so the meal is subsidized, the same as an open
    # meal nobody ate (#94).
    it 'sums only the bills with money on a settled meal that got no charges, and calls it subsidized' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      other = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
      create(:bill, meal: meal, resident: other, community: community, amount: BigDecimal('12'), no_cost: true)
      meal.update!(reconciliation: create(:reconciliation, community: community))

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('10'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # A settled meal's rows are frozen, so a fresh computation from them
    # gives the stored numbers too, unless a row changed. These examples
    # change one behind the guards, the way the repair bypass can, so a
    # summary computed from the rows shows different numbers and only
    # reading the stored charges shows the settled ones.
    def behind_the_guards
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL comeals.allow_settled_writes = 'on'")
        yield
      end
    end

    it 'reads the stored charges, not the live bills' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      settle!(cutoff: Date.yesterday)

      # From the bills this would be 99 spent, 99 charged, 49.50 a unit.
      behind_the_guards { Bill.where(meal_id: meal.id).update_all(amount: BigDecimal('99')) }

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('16'))
      expect(summary.effective_cost).to eq(BigDecimal('16'))
      expect(summary.unit_cost).to eq(BigDecimal('8'))
      expect(summary.subsidized).to be false
    end

    it "reads the stored subsidy, not the meal's cap" do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('10'))
      settle!(cutoff: Date.yesterday)

      # From the rows, a $100 cap allows $200, so the $10 spent would be
      # charged in full and the meal would not be subsidized.
      behind_the_guards { Meal.where(id: meal.id).update_all(cap: BigDecimal('100')) }

      summary = described_class.for(meal.reload)
      expect(summary.total_cost).to eq(BigDecimal('10'))
      expect(summary.effective_cost).to eq(BigDecimal('5'))
      expect(summary.unit_cost).to eq(BigDecimal('2.5'))
      expect(summary.subsidized).to be true
    end

    # The ledger reads the meal's own cap, which the meal copies from the
    # community when it is made. So a later change to the community cap
    # does not reach a meal that already exists.
    it 'shows the same numbers after the community cap changes, because the meal keeps its own cap' do
      capped_community, capped_unit = capped_setup('2.50')
      meal = create(:meal, community: capped_community)
      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('10'))
      settle!(cutoff: Date.yesterday)

      settled = described_class.for(meal.reload)
      expect(settled.effective_cost).to eq(BigDecimal('5'))
      expect(settled.subsidized).to be true

      capped_community.update!(cap: BigDecimal('100'))
      expect(meal.reload.cap).to eq(BigDecimal('2.5'))
      expect(described_class.for(meal).effective_cost).to eq(BigDecimal('5'))
      expect(described_class.for(meal).subsidized).to be true
    end

    # A meal with $25 on a receipt that only a free eater ate. A
    # settlement holds such a meal back now (Meal.settleable_by), but one
    # settled before 2026-10-09 got the lines a settlement wrote then: a
    # zero credit for the cook and a zero debit for the eater. This builds
    # that meal: claimed by a settlement, with those two lines.
    def free_eater_meal_settled_before_the_hold_back
      reconciliation = create(:reconciliation, community: community)
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
      open = described_class.for(meal.reload)

      meal.update_columns(reconciliation_id: reconciliation.id)
      as_settlement_of(reconciliation) do
        MealCharge.create!(meal: meal, resident: cook, kind: 'credit', amount: BigDecimal('0'),
                           unit_cost: BigDecimal('0'), bill_amount: BigDecimal('25'))
        MealCharge.create!(meal: meal, resident: baby, kind: 'debit', amount: BigDecimal('0'),
                           unit_cost: BigDecimal('0'), multiplier: 0)
      end
      [meal.reload, open]
    end

    # Nobody is charged, but the meal still has lines. The summary reads
    # them, so it shows zeros and what the cook spent, not nothing, and
    # calls the meal subsidized: the cook got back $0 of $25 (#94).
    it 'shows zeros, not nothing, for a settled meal only a free eater ate' do
      meal, = free_eater_meal_settled_before_the_hold_back

      expect(meal).to be_reconciled
      summary = described_class.for(meal)
      expect(summary).not_to be_nil
      expect(summary.total_cost).to eq(BigDecimal('25'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
      expect(summary.subsidized).to be true
    end

    # Settling changed no source row, so the screen must not change: the
    # open meal computed through MealLedger and the settled meal read from
    # its lines show the same numbers (#94).
    it 'shows the same numbers before and after settling a meal only a free eater ate' do
      meal, open = free_eater_meal_settled_before_the_hold_back

      expect(meal).to be_reconciled
      expect(described_class.for(meal).serialize).to eq(open.serialize)
    end

    # A no-cost bill writes no credit line, so the lines are the eaters'
    # zero debits alone, and the sums over the credits add up nothing.
    it 'shows zeros for a settled no-cost meal people ate, which has debit lines and no credit' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)
      settle!(cutoff: Date.yesterday)

      expect(meal.reload.meal_charges.map { |charge| [charge.kind, charge.resident_id, charge.amount] })
        .to eq([['debit', eater.id, BigDecimal('0')]])
      summary = described_class.for(meal)
      expect([summary.total_cost, summary.effective_cost, summary.unit_cost]).to all(be_a(BigDecimal))
      expect([summary.total_cost, summary.effective_cost, summary.unit_cost]).to all(be_zero)
      expect(summary.subsidized).to be false
    end

    it 'shows zeros for a settled meal nobody ate whose only bill is no-cost' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'), no_cost: true)
      settle!(cutoff: Date.yesterday)

      expect(meal.reload.reconciliation_id).not_to be_nil
      expect(meal.meal_charges).to be_empty
      summary = described_class.for(meal)
      expect(summary.total_cost).to be_a(BigDecimal)
      expect(summary.total_cost).to be_zero
      # The cook spent nothing, so nothing was held back from them.
      expect(summary.subsidized).to be false
    end

    it 'shows the receipts and zero charges for a meal nobody attended' do
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('40'))
      # Settled before 2026-09-10, when a receipt nobody ate was still swept
      # (138 such meals exist in production). A settlement holds it back
      # now, so the row is set the way those old ones are.
      reconciliation = create(:reconciliation, community: community)
      meal.update_columns(reconciliation_id: reconciliation.id)

      # Swept, but no lines: nobody was charged, the cook absorbed the
      # receipts.
      summary = described_class.for(meal.reload)
      expect(meal.meal_charges).to be_empty
      expect(summary.total_cost).to eq(BigDecimal('40'))
      expect(summary.effective_cost).to eq(BigDecimal('0'))
      expect(summary.unit_cost).to eq(BigDecimal('0'))
    end

    it 'returns nil for a settlement from before line items existed when only a guest ate' do
      reconciliation = create(:reconciliation, community: community)
      meal = create(:meal, community: community)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      create(:guest, meal: meal, resident: cook)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('16'))
      meal.update_columns(reconciliation_id: reconciliation.id)

      expect(described_class.for(meal.reload)).to be_nil
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
