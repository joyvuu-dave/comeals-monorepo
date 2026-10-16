# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliations
#
#  id                :bigint           not null, primary key
#  date              :date             not null
#  end_date          :date             not null
#  units_recorded_on :date             not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  community_id      :bigint           not null
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
require 'rails_helper'

RSpec.describe Reconciliation do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }
  # The latest cutoff a settlement may have, 14 days back (ADR 0011 rule
  # 2). The dates below count back from it.
  let(:latest) { described_class.latest_cutoff(community.today) }

  # A reconciliation must settle at least one meal, so specs that only need a
  # reconciliation row to exist call this first. It creates the minimum: a
  # cook, a meal on a day that is over, and a bill on that meal. Pass a date
  # when the reconciliation's end_date is older than the meal factory's
  # default (which counts back from today).
  def settleable_meal(date: nil)
    cook = create(:resident, community: community, unit: unit, multiplier: 2)
    attrs = { community: community }
    attrs[:date] = date if date
    meal = create(:meal, **attrs)
    create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
    # Someone to charge: a receipt nobody ate is held back since 2026-09-10.
    create(:meal_resident, meal: meal, resident: cook, community: community)
    meal
  end

  describe 'creating a row outside Settlement' do
    it 'is refused, even with meals to settle' do
      settleable_meal

      expect { described_class.create!(community: community, end_date: latest) }
        .to raise_error(described_class::NotSettled, /Settlement.run!/)
      expect(described_class.count).to eq(0)
    end
  end

  describe '#settlement_balances when allocation returns an unbalanced result' do
    # allocate_to_cents refuses to return this, so the second check can only
    # be reached by replacing it. It is here so that a future allocator
    # cannot write books that do not balance and raise no error.
    it 'raises and names the reconciliation' do
      settleable_meal
      reconciliation = settle!
      allow(Settlement).to receive(:allocate_to_cents).and_return({ 1 => BigDecimal('0.01') })

      expect { reconciliation.settlement_balances }
        .to raise_error(RuntimeError, /books do not balance for reconciliation #{reconciliation.id}/)
    end
  end

  describe '#settlement_balances when the ledger it is given does not balance' do
    # A meal's lines always sum to zero, so this too can only be reached by
    # replacing a part. The refusal comes from allocate_to_cents, which
    # knows the reconciliation only by the id this method passes it.
    it 'refuses to round it, and names the reconciliation' do
      settleable_meal
      reconciliation = settle!
      ledger = reconciliation.settlement_ledger
      allow(ledger).to receive(:balances).and_return({ 1 => BigDecimal('0.01') })

      expect { reconciliation.settlement_balances(ledger) }
        .to raise_error(RuntimeError, /do not sum to zero for reconciliation #{reconciliation.id}\. Sum: 0\.01\./)
    end
  end

  describe 'what a settlement claims' do
    it 'assigns unreconciled meals with bills to the new reconciliation' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal_with_bill = create(:meal, community: community)
      create(:bill, meal: meal_with_bill, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: meal_with_bill, resident: cook, community: community)

      meal_without_bill = create(:meal, community: community)

      reconciliation = settle!

      meal_with_bill.reload
      meal_without_bill.reload

      expect(meal_with_bill.reconciliation_id).to eq(reconciliation.id)
      expect(meal_without_bill.reconciliation_id).to be_nil
    end

    it 'does not reassign already-reconciled meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      settleable_meal(date: 3.years.ago.to_date)
      old_reconciliation = settle!(cutoff: 2.years.ago.to_date)

      old_meal = create(:meal, community: community)
      create(:bill, meal: old_meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: old_meal, resident: cook, community: community)
      # Assign to the old reconciliation after bill creation —
      # before_save :reject_if_reconciled blocks bill creation on reconciled meals.
      old_meal.update_column(:reconciliation_id, old_reconciliation.id)

      new_meal = create(:meal, community: community)
      create(:bill, meal: new_meal, resident: cook, community: community, amount: BigDecimal('60'))
      create(:meal_resident, meal: new_meal, resident: cook, community: community)

      new_reconciliation = settle!

      old_meal.reload
      new_meal.reload

      expect(old_meal.reconciliation_id).to eq(old_reconciliation.id)
      expect(new_meal.reconciliation_id).to eq(new_reconciliation.id)
    end
  end

  describe '#settlement_balances' do
    it 'computes per-resident balances rounded to cents' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.reload

      reconciliation = settle!

      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('50'))
      expect(balances[eater.id]).to eq(BigDecimal('-50'))
    end

    it 'rounds repeating decimals to cents and sums to zero' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater_1 = create(:resident, community: community, unit: unit, multiplier: 2)
      eater_2 = create(:resident, community: community, unit: unit, multiplier: 1)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater_1, community: community)
      create(:meal_resident, meal: meal, resident: eater_2, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('10'))
      meal.reload

      # multiplier = 2 + 1 = 3
      # unit_cost = 10 / 3 = 3.33333...
      # eater_1 debit = 3.33333... * 2 = 6.66666... → truncated to 6.66
      # eater_2 debit = 3.33333... * 1 = 3.33333... → truncated to 3.33
      # Residual = 10 - 6.66 - 3.33 = 0.01 → 1 penny to eater_1 (larger remainder)

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[eater_1.id]).to eq(BigDecimal('-6.67'))
      expect(balances[eater_2.id]).to eq(BigDecimal('-3.33'))
      expect(balances[cook.id]).to eq(BigDecimal('10'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'takes the leftover cent from the eater who got the leftover unit at the ledger grain' do
      # $1 over three adult eaters is a third each. At the ledger grain the
      # one unit of 10^-8 left over goes to the lowest id, so the first
      # eater's share is -0.33333334 and the other two are -0.33333333.
      # Rounded toward zero, all three are -0.33, which sum to -0.99
      # against the cook's +1.00, so one cent must move. It is taken from
      # the balance that lost the most in the rounding: the first eater.
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eaters = Array.new(3) { create(:resident, community: community, unit: unit, multiplier: 2) }
      expect(eaters.map(&:id)).to eq(eaters.map(&:id).sort)

      meal = create(:meal, community: community)
      eaters.each { |e| create(:meal_resident, meal: meal, resident: e, community: community) }
      # $1 / 6 total multiplier = 0.16666... per unit × 2 = 0.33333... per eater
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('1'))
      expect(eaters.map { |e| balances[e.id] })
        .to eq([BigDecimal('-0.34'), BigDecimal('-0.33'), BigDecimal('-0.33')])
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end
  end

  describe '#settlement_balances with capped meals' do
    it 'caps cook credit for a subsidized meal (single cook)' do
      capped_community = create(:community, cap: BigDecimal('5.00'))
      capped_unit = create(:unit, community: capped_community)

      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('20'))
      meal.reload

      # multiplier = 2, cap = 5.00, max_cost = 10
      # total_cost = 20 > max_cost → subsidized
      # cook credit = (20/20) * 10 = 10
      # eater debit = (10/2) * 2 = 10
      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('10'))
      expect(balances[eater.id]).to eq(BigDecimal('-10'))
    end

    it 'splits capped credit proportionally among multiple cooks' do
      capped_community = create(:community, cap: BigDecimal('5.00'))
      capped_unit = create(:unit, community: capped_community)

      cook_a = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      cook_b = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook_a, community: capped_community, amount: BigDecimal('15'))
      create(:bill, meal: meal, resident: cook_b, community: capped_community, amount: BigDecimal('5'))
      meal.reload

      # multiplier = 2, cap = 5.00, max_cost = 10
      # total_cost = 20 > max_cost → subsidized
      # cook_a credit = (15/20) * 10 = 7.50
      # cook_b credit = (5/20) * 10 = 2.50
      # total credits = 10, total debits = 10
      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook_a.id]).to eq(BigDecimal('7.5'))
      expect(balances[cook_b.id]).to eq(BigDecimal('2.5'))
      expect(balances[eater.id]).to eq(BigDecimal('-10'))
    end

    it 'does not cap credits when meal is under cap' do
      capped_community = create(:community, cap: BigDecimal('5.00'))
      capped_unit = create(:unit, community: capped_community)

      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('8'))
      meal.reload

      # multiplier = 2, cap = 5.00, max_cost = 10
      # total_cost = 8 < max_cost → not subsidized, no capping
      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('8'))
      expect(balances[eater.id]).to eq(BigDecimal('-8'))
    end

    it 'caps credits correctly when cook also attends the meal' do
      capped_community = create(:community, cap: BigDecimal('5.00'))
      capped_unit = create(:unit, community: capped_community)

      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: cook, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('30'))
      meal.reload

      # total_mult = 4, cap = 5.00, max_cost = 20
      # total_cost = 30 > max_cost → subsidized
      # cook credit = (30/30) * 20 = 20
      # unit_cost = 20 / 4 = 5.00
      # cook debit = 5 * 2 = 10, eater debit = 5 * 2 = 10
      # cook balance = 20 - 10 = 10
      # eater balance = 0 - 10 = -10
      # books: 10 - 10 = 0 ✓
      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('10'))
      expect(balances[eater.id]).to eq(BigDecimal('-10'))
    end

    it 'does not cap credits for uncapped communities' do
      # Default community has no cap
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('100'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('100'))
      expect(balances[eater.id]).to eq(BigDecimal('-100'))
    end
  end

  describe '#settlement_balances with fractional-cent credits' do
    # Every other settlement spec produces whole-cent credits, so truncation
    # leaves a non-negative residual and only the positive-residual branch of
    # allocate_to_cents runs. A subsidized capped meal split proportionally
    # between cooks produces fractional-cent CREDITS, driving the truncated
    # sum negative and exercising the negative-residual branch.
    it 'awards the residual penny to the most-positive remainder' do
      capped_community = create(:community, cap: BigDecimal('5.00'))
      capped_unit = create(:unit, community: capped_community)

      cook_a = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      cook_b = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook_a, community: capped_community, amount: BigDecimal('10'))
      create(:bill, meal: meal, resident: cook_b, community: capped_community, amount: BigDecimal('20'))
      meal.reload

      # total_mult = 2, cap = 5.00 → max_cost = 10.00; total_cost = 30 → subsidized
      # cook_a credit = (10/30) × 10 = 3.3333... → truncates to 3.33 (remainder ≈ 0.0033)
      # cook_b credit = (20/30) × 10 = 6.6666... → truncates to 6.66 (remainder ≈ 0.0067)
      # eater debit = 10.00 exactly (remainder 0)
      # Truncated sum = 3.33 + 6.66 − 10.00 = −0.01 → the penny must go to the
      # MOST-POSITIVE remainder: cook_b.
      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook_a.id]).to eq(BigDecimal('3.33'))
      expect(balances[cook_b.id]).to eq(BigDecimal('6.67'))
      expect(balances[eater.id]).to eq(BigDecimal('-10'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'breaks remainder ties by lowest resident_id when awarding pennies to credits' do
      capped_community = create(:community, cap: BigDecimal('6.67'))
      capped_unit = create(:unit, community: capped_community)

      cook_a = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      cook_b = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 1)

      # The tie-break assertion below assigns the penny to cook_a because it
      # has the lower id; guard that assumption explicitly.
      expect(cook_a.id).to be < cook_b.id

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      create(:bill, meal: meal, resident: cook_a, community: capped_community, amount: BigDecimal('10'))
      create(:bill, meal: meal, resident: cook_b, community: capped_community, amount: BigDecimal('10'))
      meal.reload

      # total_mult = 1, cap = 6.67 → max_cost = 6.67; total_cost = 20 → subsidized
      # each cook credit = (10/20) × 6.67 = 3.335 → truncates to 3.33 (remainder 0.005 each)
      # eater debit = 6.67 exactly (remainder 0)
      # Truncated sum = 3.33 + 3.33 − 6.67 = −0.01 → remainders tie at 0.005 →
      # the penny goes to the LOWEST resident_id: cook_a.
      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook_a.id]).to eq(BigDecimal('3.34'))
      expect(balances[cook_b.id]).to eq(BigDecimal('3.33'))
      expect(balances[eater.id]).to eq(BigDecimal('-6.67'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end
  end

  describe 'Settlement.allocate_to_cents input validation' do
    # These specs call the rounding step directly: the guards are
    # defense-in-depth against future upstream bugs, and no public path today
    # can produce unbalanced raw balances (per-meal credits and debits are
    # structurally symmetric). See issue #16.
    let(:reconciliation) do
      settleable_meal
      settle!
    end

    it 'raises when raw balances carry a sub-cent imbalance instead of rounding it away with no error' do
      unbalanced = { 1 => BigDecimal('0.004') }

      expect { Settlement.allocate_to_cents(unbalanced, reconciliation_id: reconciliation.id) }
        .to raise_error(/do not sum to zero/)
    end

    it 'raises when raw balances carry a material imbalance instead of crashing on nil' do
      unbalanced = { 1 => BigDecimal('0.10') }

      expect { Settlement.allocate_to_cents(unbalanced, reconciliation_id: reconciliation.id) }
        .to raise_error(/do not sum to zero/)
    end

    it 'raises for a negative imbalance the same as for a positive one' do
      # Mutant dropped the .abs in the guard and nothing failed: every
      # unbalanced input above sums to more than zero.
      unbalanced = { 1 => BigDecimal('-0.10') }

      expect { Settlement.allocate_to_cents(unbalanced, reconciliation_id: reconciliation.id) }
        .to raise_error(/do not sum to zero/)
    end

    it 'raises a named error when residual pennies exhaust the deduction candidates' do
      # The input guard above makes this path unreachable; switch it off to
      # prove the second defensive layer raises descriptively instead of
      # crashing with NoMethodError on a nil candidate.
      allow(Settlement).to receive(:assert_balanced_input!)
      unbalanced = { 1 => BigDecimal('0.055') }

      expect { Settlement.allocate_to_cents(unbalanced, reconciliation_id: reconciliation.id) }
        .to raise_error(/books do not balance/)
    end

    # The second guard refuses only when a penny would have no balance to
    # go to. One penny and one balance that lost something is enough, and
    # the penny goes there.
    it 'rounds, with the input guard off, when there are exactly as many candidates as pennies' do
      allow(Settlement).to receive(:assert_balanced_input!)
      unbalanced = { 1 => BigDecimal('0.01'), 2 => BigDecimal('-0.005') }

      expect(Settlement.allocate_to_cents(unbalanced, reconciliation_id: reconciliation.id))
        .to eq(1 => BigDecimal('0.01'), 2 => BigDecimal('-0.01'))
    end

    it 'raises a named error when residual pennies exhaust the award candidates' do
      allow(Settlement).to receive(:assert_balanced_input!)
      unbalanced = { 1 => BigDecimal('-0.055') }

      expect { Settlement.allocate_to_cents(unbalanced, reconciliation_id: reconciliation.id) }
        .to raise_error(/books do not balance/)
    end

    it 'refuses an imbalance of one unit of the ledger grain, and accepts exact zero' do
      # There is no epsilon. The ledger allocates whole units of 10^-8
      # dollars, so its balances sum to exactly zero, and one unit off is
      # an upstream bug (#85: the old epsilon let a large correct ledger
      # fail the daily check, and would have let a small wrong one pass).
      one_unit = BigDecimal('0.00000001')

      expect(Settlement.allocate_to_cents({ 1 => BigDecimal('0') }, reconciliation_id: reconciliation.id))
        .to eq(1 => 0)
      expect { Settlement.allocate_to_cents({ 1 => one_unit }, reconciliation_id: reconciliation.id) }
        .to raise_error(/do not sum to zero/)
    end

    it 'rounds balances at the ledger grain that sum to zero' do
      # Two people are owed about $3.33 each and one owes about $6.67, at
      # the ledger grain, and the three sum to exactly zero. Rounded toward
      # zero to cents they are 3.33, 3.33 and -6.66, which already sum to
      # zero, so no cent moves.
      third = BigDecimal('3.33333333')
      exact = { 1 => third + BigDecimal('0.00000001'), 2 => third, 3 => BigDecimal('-6.66666667') }

      balances = Settlement.allocate_to_cents(exact, reconciliation_id: reconciliation.id)

      expect(balances).to eq(1 => BigDecimal('3.33'), 2 => BigDecimal('3.33'), 3 => BigDecimal('-6.66'))
    end
  end

  describe 'the settlement sweep' do
    it 'sweeps all unreconciled meals on or before end_date' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      before_cutoff = create(:meal, community: community, date: Date.new(2025, 3, 1))
      create(:bill, meal: before_cutoff, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: before_cutoff, resident: cook, community: community)

      after_cutoff = create(:meal, community: community, date: Date.new(2025, 7, 1))
      create(:bill, meal: after_cutoff, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: after_cutoff, resident: cook, community: community)

      reconciliation = settle!(cutoff: Date.new(2025, 6, 30))

      expect(before_cutoff.reload.reconciliation_id).to eq(reconciliation.id)
      expect(after_cutoff.reload.reconciliation_id).to be_nil
    end

    it 'never sweeps a meal from a day that is not over, even when end_date allows it' do
      # Defense in depth: a reconciliation whose end_date slipped through as
      # today (e.g. rows predating the end_date validation) must still not
      # settle today's meal — its receipt and attendance are not final.
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      tonight = create(:meal, community: community, date: Time.zone.today)
      create(:bill, meal: tonight, resident: cook, community: community, amount: BigDecimal('0'))

      expect(Meal.settleable_by(Time.zone.today)).not_to include(tonight)
      expect(Meal.settleable_by(Date.tomorrow)).not_to include(tonight)
    end

    it 'includes late-entered meals from before the previous reconciliation' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      original_meal = create(:meal, community: community, date: Date.new(2025, 2, 10))
      create(:bill, meal: original_meal, resident: cook, community: community, amount: BigDecimal('40'))
      create(:meal_resident, meal: original_meal, resident: cook, community: community)

      # First reconciliation sweeps everything through Mar 31
      recon1 = settle!(cutoff: Date.new(2025, 3, 31))
      expect(original_meal.reload.reconciliation_id).to eq(recon1.id)

      # Late entry: someone forgot to enter this meal, creates it after recon1
      late_meal = create(:meal, community: community, date: Date.new(2025, 2, 15))
      create(:bill, meal: late_meal, resident: cook, community: community, amount: BigDecimal('25'))
      create(:meal_resident, meal: late_meal, resident: cook, community: community)

      # Second reconciliation sweeps everything unreconciled through Jun 30
      recon2 = settle!(cutoff: Date.new(2025, 6, 30))

      expect(late_meal.reload.reconciliation_id).to eq(recon2.id)
      expect(original_meal.reload.reconciliation_id).to eq(recon1.id)
    end
  end

  describe 'concurrent settlements' do
    it 'raises and rolls back instead of stealing meals a concurrent reconciliation claimed after the pluck' do
      # Rival settles a meal of its own, created before the contested ones, so
      # its sweep never touches them. (It needs one: a reconciliation that
      # would settle no meals is refused at create.)
      settleable_meal
      rival = settle!

      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      contested = create(:meal, community: community)
      create(:bill, meal: contested, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: contested, resident: cook, community: community)
      uncontested = create(:meal, community: community)
      create(:bill, meal: uncontested, resident: cook, community: community, amount: BigDecimal('30'))
      create(:meal_resident, meal: uncontested, resident: cook, community: community)

      loser = build(:reconciliation, community: community, end_date: latest)

      # Simulate the READ COMMITTED race (issue #8): after `loser` plucks its
      # eligible meal ids but before its UPDATE runs, a concurrent settlement
      # claims one of those meals and commits. Without re-asserting
      # reconciliation_id IS NULL, the UPDATE would overwrite the rival's
      # assignment with no error, and both ledgers would charge for the same
      # meal.
      settlement = Settlement.new(loser)
      allow(settlement).to receive(:eligible_meal_ids).and_wrap_original do |original|
        original.call.tap { contested.update_column(:reconciliation_id, rival.id) }
      end

      expect { settlement.settle! }.to raise_error(Settlement::Contested, /concurrent reconciliation/)

      # The losing settlement must vanish entirely: no reconciliation row and
      # no partial meal claims survive the rollback.
      expect(described_class.where.not(id: rival.id)).to be_empty
      expect(uncontested.reload.reconciliation_id).to be_nil
    end
  end

  describe 'what a settlement stores' do
    it 'persists settlement balances to reconciliation_balances table' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
      meal.reload

      reconciliation = settle!

      # Settlement runs assign_meals, then write_ledger!
      expect(reconciliation.reconciliation_balances.count).to be > 0

      cook_balance = reconciliation.reconciliation_balances.find_by(resident: cook)
      eater_balance = reconciliation.reconciliation_balances.find_by(resident: eater)

      expect(cook_balance.amount).to eq(BigDecimal('80'))
      expect(eater_balance.amount).to eq(BigDecimal('-80'))
    end

    it 'skips zero-balance residents' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)
      bystander = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      create(:meal_resident, meal: meal, resident: eater, community: community)
      meal.reload

      reconciliation = settle!

      # Cook and eater have balances, bystander has zero and is skipped
      expect(reconciliation.reconciliation_balances.find_by(resident: bystander)).to be_nil
      expect(reconciliation.reconciliation_balances.find_by(resident: cook)).to be_present
      expect(reconciliation.reconciliation_balances.find_by(resident: eater)).to be_present
    end
  end

  describe 'zero-attendee meals' do
    it 'holds back a meal with a receipt nobody ate, instead of settling it for nothing' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      settleable_meal(date: latest - 1)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      # No meal_residents or guests — nobody ate, and $50 is at stake

      reconciliation = settle!

      # Until 2026-09-10 this meal was swept with no lines, and the $50 was
      # gone for good. Now it waits for the attendance or the bill's removal.
      expect(meal.reload.reconciliation_id).to be_nil
      expect(reconciliation.reconciliation_balances.find_by(resident: cook)).to be_nil
    end

    it 'still settles a meal nobody ate when its cook slot holds no money, so it does not pile up' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))

      reconciliation = settle!

      expect(meal.reload.reconciliation).to eq(reconciliation)
      expect(reconciliation.reconciliation_balances).to be_empty
    end

    it 'excludes zero-attendee meals from the running balance' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      BalanceRecalculation.call(community: community)
      expect(ResidentBalance.find_by(resident: cook)&.amount.to_d).to eq(BigDecimal('0'))
    end
  end

  # Atomicity is pinned in spec/services/settlement_contract_spec.rb, where
  # the failure comes from the database rather than from a stubbed method.

  describe 'date default' do
    it 'defaults date to today when not provided' do
      settleable_meal
      recon = settle!
      expect(recon.date).to eq(Time.zone.today)
    end

    it 'preserves an explicitly set date' do
      settleable_meal
      explicit_date = Date.new(2025, 6, 15)
      recon = described_class.new(community: community, end_date: latest, date: explicit_date)
      Settlement.new(recon).settle!
      expect(recon.date).to eq(explicit_date)
    end
  end

  describe 'validations' do
    it 'requires end_date, and says only that' do
      recon = described_class.new(community: community)
      expect(recon).not_to be_valid
      expect(recon.errors[:end_date]).to include("can't be blank")
      # Not also "no meals on or before this date": that check stands
      # down when the date itself is wrong.
      expect(recon.errors[:base]).to be_empty
    end

    # ADR 0011 rule 2: a cook may still fix a cost on a newer dinner.
    describe 'the cutoff, which must be at least 14 days before today' do
      include ActiveSupport::Testing::TimeHelpers

      let(:refusal) { "must be on or before #{latest.iso8601}, 14 days before today" }

      it 'accepts a cutoff exactly 14 days back' do
        settleable_meal(date: latest)

        expect(build(:reconciliation, community: community, end_date: latest)).to be_valid
      end

      it 'refuses a cutoff 13 days back, and says which is the latest' do
        recon = build(:reconciliation, community: community, end_date: latest + 1)

        expect(recon).not_to be_valid
        expect(recon.errors[:end_date]).to eq([refusal])
      end

      it 'refuses yesterday, today and tomorrow' do
        [community.today - 1, community.today, community.today + 1].each do |cutoff|
          recon = build(:reconciliation, community: community, end_date: cutoff)

          expect(recon).not_to be_valid
          expect(recon.errors[:end_date]).to eq([refusal])
        end
      end

      # Late in the evening the community's day is behind UTC's, which is
      # the day Date.current would give with the app zone set to UTC.
      it "counts the 14 days from the community's today, in its time zone" do
        travel_to Time.utc(2026, 3, 11, 6, 30) do # 2026-03-10 23:30 in Los Angeles
          expect(described_class.latest_cutoff(community.today)).to eq(Date.new(2026, 2, 24))
        end
      end
    end

    it 'accepts the latest cutoff allowed' do
      settleable_meal
      recon = build(:reconciliation, community: community, end_date: described_class.latest_cutoff(community.today))
      expect(recon).to be_valid
    end

    # A reconciliation is a settlement event, and the table is append-only:
    # an empty one can never be removed, sits in every resident's history as a
    # settlement that settled nothing, and becomes the Reconciliation.last that
    # reconciliations:send_cooking_slot_email mails cooks about.
    it 'rejects a reconciliation that would settle no meals' do
      recon = build(:reconciliation, community: community, end_date: latest)

      expect(recon).not_to be_valid
      expect(recon.errors[:base])
        .to include('No unreconciled meals with bills on or before this date. ' \
                    'A reconciliation must settle at least one meal or carry a correction.')
    end

    it 'accepts a period holding exactly one settleable meal' do
      settleable_meal(date: Date.new(2025, 3, 1))

      recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

      expect(recon).to be_valid
    end

    it 'rejects a period whose only meal falls after the cutoff' do
      settleable_meal(date: Date.new(2025, 4, 1))

      recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

      expect(recon).not_to be_valid
      expect(recon.errors[:base].first).to include('must settle at least one meal')
    end

    it 'rejects a period whose only meal has no bill' do
      create(:meal, community: community, date: latest)

      recon = build(:reconciliation, community: community, end_date: latest)

      expect(recon).not_to be_valid
      expect(recon.errors[:base].first).to include('must settle at least one meal')
    end

    it 'rejects a period whose only meal is already reconciled' do
      meal = settleable_meal
      settle!
      expect(meal.reload.reconciliation_id).to be_present

      second = build(:reconciliation, community: community, end_date: latest)

      expect(second).not_to be_valid
      expect(second.errors[:base].first).to include('must settle at least one meal')
    end

    # A meal with money on a bill and nobody who pays signed up is held
    # back (Meal.settleable_by). When those are the only meals with bills,
    # "no meals with bills" is false: the reconciler can see the bills.
    # The answer names the held meals and says what has to change before
    # they can settle.
    describe 'when the only meals with bills are held back' do
      def held_meal(date, eater_multiplier: nil)
        cook = create(:resident, community: community, unit: unit, multiplier: 2)
        meal = create(:meal, community: community, date: date)
        create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('25'))
        if eater_multiplier
          eater = create(:resident, community: community, unit: unit, multiplier: eater_multiplier)
          create(:meal_resident, meal: meal, resident: eater, community: community)
        end
        meal
      end

      def held_answer(dates)
        'No meal on or before this date can be settled yet. Meals held back because a bill has money on it ' \
          "and nobody who pays is signed up: #{dates}. To settle one, sign up someone who pays or remove " \
          'the bill. A reconciliation must settle at least one meal or carry a correction.'
      end

      it 'names a meal nobody signed up for' do
        held_meal(Date.new(2025, 3, 4))

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq([held_answer('2025-03-04')])
      end

      it 'names meals only people who eat free signed up for, oldest first' do
        held_meal(Date.new(2025, 3, 9), eater_multiplier: 0)
        held_meal(Date.new(2025, 3, 2), eater_multiplier: 0)

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq([held_answer('2025-03-02 and 2025-03-09')])
      end

      # The example above passes without ORDER BY too: PostgreSQL returned
      # these dates in date order without being asked. So this reads the
      # statement.
      it 'asks for the held meals oldest first' do
        held_meal(Date.new(2025, 3, 4))
        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))
        statements = []
        callback = ->(*, payload) { statements << payload[:sql] }
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { recon.valid? }

        # One read for the held meals and one for the meals waiting for a
        # cost, each oldest first.
        expect(statements.grep(/\ASELECT "meals"\."date" FROM "meals"/))
          .to contain_exactly(/ ORDER BY "meals"\."date" ASC\z/, / ORDER BY "meals"\."date" ASC\z/)
      end

      # People ate and no cook entered a bill. A settlement skips that meal
      # (Settlement.skipped_by), but it is not held back: there is no
      # money on a bill to lose.
      it 'does not name a meal people ate that no cook billed' do
        held_meal(Date.new(2025, 3, 4))
        no_bill = create(:meal, community: community, date: Date.new(2025, 3, 5))
        create(:meal_resident, meal: no_bill, resident: create(:resident, community: community, unit: unit),
                               community: community)

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq([held_answer('2025-03-04')])
      end

      it 'does not name a held meal after the cutoff' do
        held_meal(Date.new(2025, 4, 1))

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq(['No unreconciled meals with bills on or before this date. ' \
                                           'A reconciliation must settle at least one meal or carry a correction.'])
      end

      # Three meals nobody attended were settled with money on a bill
      # before 2026-09-10. They are settled, so they are not held.
      it 'does not name a meal that a settlement already claimed' do
        old = held_meal(Date.new(2025, 3, 4))
        old.update_columns(reconciliation_id: create(:reconciliation, community: community).id)

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq(['No unreconciled meals with bills on or before this date. ' \
                                           'A reconciliation must settle at least one meal or carry a correction.'])
      end

      it 'says nothing about held meals when another meal can be settled' do
        held_meal(Date.new(2025, 3, 4))
        settleable_meal(date: Date.new(2025, 3, 5))

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).to be_valid
      end
    end

    # Meals where someone is charged and a cook's cost is blank wait (ADR
    # 0011 rule 3, Meal.waiting_for_a_cost). The answer names them too.
    describe 'when the only meals with bills wait for a cost' do
      def waiting_meal(date)
        meal = settleable_meal(date: date)
        create(:bill, meal: meal, resident: create(:resident, community: community, unit: unit),
                      community: community, amount: 0)
        meal
      end

      def waiting_words(dates)
        "Meals waiting for a cook's cost: #{dates}. To settle one, each of its cooks enters a cost or marks " \
          'No cost.'
      end

      it 'names them, oldest first, and says what has to change' do
        waiting_meal(Date.new(2025, 3, 9))
        waiting_meal(Date.new(2025, 3, 2))

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq(['No meal on or before this date can be settled yet. ' \
                                           "#{waiting_words('2025-03-02 and 2025-03-09')} " \
                                           'A reconciliation must settle at least one meal or carry a correction.'])
      end

      it 'names the held meals first, then the waiting ones' do
        cook = create(:resident, community: community, unit: unit)
        held = create(:meal, community: community, date: Date.new(2025, 3, 4))
        create(:bill, meal: held, resident: cook, community: community, amount: 25)
        waiting_meal(Date.new(2025, 3, 2))

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base].sole).to start_with('No meal on or before this date can be settled yet. ' \
                                                       'Meals held back because a bill has money on it')
        expect(recon.errors[:base].sole).to end_with("the bill. #{waiting_words('2025-03-02')} A reconciliation " \
                                                     'must settle at least one meal or carry a correction.')
      end

      it 'does not name a waiting meal after the cutoff, or one already settled' do
        waiting_meal(Date.new(2025, 4, 1))
        waiting_meal(Date.new(2025, 3, 4)).update_columns(
          reconciliation_id: create(:reconciliation, community: community).id
        )

        recon = build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))

        expect(recon).not_to be_valid
        expect(recon.errors[:base]).to eq(['No unreconciled meals with bills on or before this date. ' \
                                           'A reconciliation must settle at least one meal or carry a correction.'])
      end

      it 'says nothing about waiting meals when another meal can be settled' do
        waiting_meal(Date.new(2025, 3, 4))
        settleable_meal(date: Date.new(2025, 3, 5))

        expect(build(:reconciliation, community: community, end_date: Date.new(2025, 3, 31))).to be_valid
      end
    end

    # A cutoff that is too new is already wrong on its own. Reporting "no
    # meals" alongside it would be noise — with no valid cutoff there is no
    # period to judge emptiness against.
    it 'reports only the cutoff error when the cutoff is less than 14 days back' do
      recon = build(:reconciliation, community: community, end_date: Date.tomorrow)

      expect(recon).not_to be_valid
      expect(recon.errors[:end_date]).to eq(["must be on or before #{(community.today - 14).iso8601}, " \
                                             '14 days before today'])
      expect(recon.errors[:base]).to be_empty
    end

    # Both rules guard creation only. Existing rows — including empty ones
    # written before this validation, or by a deliberate rake task using
    # mark_settling! and save(validate: false), and ones with a cutoff
    # from before the 14-day rule — must still load and behave normally.
    it 'does not re-run on an existing empty reconciliation with a new cutoff' do
      legacy = build(:reconciliation, community: community, end_date: community.today - 1)
      legacy.mark_settling!
      legacy.save!(validate: false)
      legacy.reload

      expect(legacy.number_of_meals).to eq(0)
      expect(legacy).to be_valid
      expect(legacy.errors[:base]).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Hardening: boundary / edge-case tests for settlement_balances
  # ---------------------------------------------------------------------------

  describe 'settlement edge cases' do
    it 'handles a meal where all bills are no_cost (zero cost meal)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      no_cost_bill_with_an_amount(meal: meal, resident: cook, amount: '50')
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # All bills are no_cost → total_cost = 0 → credits and debits both 0
      expect(balances[cook.id]).to eq(BigDecimal('0'))
      expect(balances[eater.id]).to eq(BigDecimal('0'))
    end

    it 'handles a guest-only meal (no meal_residents, only guests)' do
      host = create(:resident, community: community, unit: unit, multiplier: 2)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:guest, meal: meal, resident: host, multiplier: 2)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # unit_cost = 30 / 2 = 15, guest debit = 15 * 2 = 30 charged to host
      expect(balances[cook.id]).to eq(BigDecimal('30'))
      expect(balances[host.id]).to eq(BigDecimal('-30'))
    end

    it 'handles a single attendee who is also the cook' do
      solo = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: solo, community: community)
      create(:bill, meal: meal, resident: solo, community: community, amount: BigDecimal('40'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # credit = 40, debit = (40/2) * 2 = 40 → net 0
      expect(balances[solo.id]).to eq(BigDecimal('0'))
    end

    it 'handles a child (multiplier 0) attending a meal' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      adult = create(:resident, community: community, unit: unit, multiplier: 2)
      baby = create(:resident, community: community, unit: unit, multiplier: 0)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: adult, community: community)
      create(:meal_resident, meal: meal, resident: baby, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('20'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # total_mult = 2 + 0 = 2, unit_cost = 20/2 = 10
      # adult debit = 10 * 2 = 20, baby debit = 10 * 0 = 0
      expect(balances[cook.id]).to eq(BigDecimal('20'))
      expect(balances[adult.id]).to eq(BigDecimal('-20'))
      expect(balances[baby.id]).to eq(BigDecimal('0'))
    end

    it 'handles a mix of no_cost and regular bills on the same meal' do
      paid_cook = create(:resident, community: community, unit: unit, multiplier: 2)
      free_cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: paid_cook, community: community, amount: BigDecimal('60'))
      create(:bill, meal: meal, resident: free_cook, community: community, amount: BigDecimal('0'), no_cost: true)
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # total_cost = 60 (only paid_cook's bill counts)
      # unit_cost = 60 / 2 = 30, eater debit = 30 * 2 = 60
      # paid_cook credit = 60, free_cook credit = 0
      expect(balances[paid_cook.id]).to eq(BigDecimal('60'))
      expect(balances[free_cook.id]).to eq(BigDecimal('0'))
      expect(balances[eater.id]).to eq(BigDecimal('-60'))
    end

    it 'allocates residual pennies deterministically (lowest ID absorbs first)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater1 = create(:resident, community: community, unit: unit, multiplier: 2)
      eater2 = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater1, community: community)
      create(:meal_resident, meal: meal, resident: eater2, community: community)
      # $0.05 / 4 total multiplier = $0.0125 per unit x 2 multiplier = $0.025
      # per eater, exactly, at the ledger grain. Rounded toward zero, each is
      # -0.02, and the cook +0.05, so one cent must move, and the two eaters
      # lost the same amount in the rounding.
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0.05'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # The tie goes to the lowest id. The three exact values also make the
      # books sum to exactly zero.
      lower_id_eater, higher_id_eater = [eater1, eater2].sort_by(&:id)
      expect(balances[cook.id]).to eq(BigDecimal('0.05'))
      expect(balances[lower_id_eater.id]).to eq(BigDecimal('-0.03'))
      expect(balances[higher_id_eater.id]).to eq(BigDecimal('-0.02'))
    end

    # The total multiplier is 0, so nobody can be charged a share and every
    # line is zero. Only a meal whose cook slots hold no money gets here: one
    # with money on a receipt is held back instead, so the cook is not
    # credited $0 for good (Meal.settleable_by, #94).
    it 'handles a child-only meal (all multiplier-0 attendees, zero total multiplier)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      baby1 = create(:resident, community: community, unit: unit, multiplier: 0)
      baby2 = create(:resident, community: community, unit: unit, multiplier: 0)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: baby1, community: community)
      create(:meal_resident, meal: meal, resident: baby2, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(meal.reload.reconciliation_id).to eq(reconciliation.id)
      expect(meal.meal_charges.map { |charge| [charge.kind, charge.resident_id, charge.amount] })
        .to contain_exactly(['credit', cook.id, BigDecimal('0')], ['debit', baby1.id, BigDecimal('0')],
                            ['debit', baby2.id, BigDecimal('0')])
      expect(balances[cook.id]).to eq(BigDecimal('0'))
      expect(balances[baby1.id]).to eq(BigDecimal('0'))
      expect(balances[baby2.id]).to eq(BigDecimal('0'))
    end

    it 'handles cap exactly equal to total cost (no capping applied)' do
      capped_community = create(:community, cap: BigDecimal('10.00'))
      capped_unit = create(:unit, community: capped_community)

      cook = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)
      eater = create(:resident, community: capped_community, unit: capped_unit, multiplier: 2)

      meal = create(:meal, community: capped_community)
      create(:meal_resident, meal: meal, resident: eater, community: capped_community)
      # multiplier = 2, cap = 10, max_cost = 20, total_cost = 20 exactly
      create(:bill, meal: meal, resident: cook, community: capped_community, amount: BigDecimal('20'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # total_cost == max_cost → not subsidized → full credit
      expect(balances[cook.id]).to eq(BigDecimal('20'))
      expect(balances[eater.id]).to eq(BigDecimal('-20'))
    end

    it 'handles an empty reconciliation period (no meals with bills)' do
      # Creating an empty reconciliation is refused now, so this builds the row
      # the way a legacy record or a deliberate rake task would. The zero-meal
      # path must still compute clean balances for any row that reaches it.
      bystander = create(:resident, community: community, unit: unit, multiplier: 2)

      reconciliation = build(:reconciliation, community: community, end_date: latest)
      reconciliation.mark_settling!
      reconciliation.save!(validate: false)
      balances = reconciliation.settlement_balances

      expect(balances[bystander.id]).to eq(BigDecimal('0'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'includes inactive residents who participated in meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      inactive_eater = create(:resident, community: community, unit: unit, multiplier: 2, active: false)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: inactive_eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('30'))
      expect(balances[inactive_eater.id]).to eq(BigDecimal('-30'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'accumulates across multiple meals in the same reconciliation period' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal1 = create(:meal, community: community)
      create(:meal_resident, meal: meal1, resident: eater, community: community)
      create(:bill, meal: meal1, resident: cook, community: community, amount: BigDecimal('50'))

      meal2 = create(:meal, community: community)
      create(:meal_resident, meal: meal2, resident: cook, community: community)
      create(:bill, meal: meal2, resident: eater, community: community, amount: BigDecimal('30'))

      [meal1, meal2].each(&:reload)

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      # Meal 1: cook credit 50, eater debit 50
      # Meal 2: eater credit 30, cook debit 30
      # Net cook: 50 - 30 = 20, net eater: 30 - 50 = -20
      expect(balances[cook.id]).to eq(BigDecimal('20'))
      expect(balances[eater.id]).to eq(BigDecimal('-20'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'distributes multiple residual pennies across different residents' do
      cook = create(:resident, community: community, unit: unit, multiplier: 1)
      eaters = Array.new(7) { create(:resident, community: community, unit: unit, multiplier: 1) }

      meal = create(:meal, community: community)
      eaters.each { |e| create(:meal_resident, meal: meal, resident: e, community: community) }
      # $1.00 / 7 = $0.142857... per eater. Truncated = $0.14 each, sum = $0.98.
      # Residual = $0.02 → 2 pennies to distribute.
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      meal.reload

      reconciliation = settle!
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('1'))
      # At the ledger grain the two units of 10^-8 left over go to the two
      # lowest ids, so those two lost the most in the rounding and pay the
      # two cents: -0.15 each, and the other five -0.14.
      expect(eaters.map(&:id)).to eq(eaters.map(&:id).sort)
      expect(eaters.take(2).map { |e| balances[e.id] }).to all(eq(BigDecimal('-0.15')))
      expect(eaters.drop(2).map { |e| balances[e.id] }).to all(eq(BigDecimal('-0.14')))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end
  end

  describe '#unit_balances' do
    it 'groups settlement balances by unit and sums to exactly zero' do
      unit_a = create(:unit, community: community, name: 'Unit A')
      unit_b = create(:unit, community: community, name: 'Unit B')
      cook = create(:resident, community: community, unit: unit_a, multiplier: 1)
      eater1 = create(:resident, community: community, unit: unit_b, multiplier: 1)
      eater2 = create(:resident, community: community, unit: unit_b, multiplier: 1)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater1, community: community)
      create(:meal_resident, meal: meal, resident: eater2, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      meal.reload

      reconciliation = settle!

      result = reconciliation.unit_balances

      expect(result[[unit_a.id, 'Unit A']]).to eq(BigDecimal('50'))
      expect(result[[unit_b.id, 'Unit B']]).to eq(BigDecimal('-50'))
      expect(result.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'includes units whose residents all have zero balance' do
      unit_a = create(:unit, community: community, name: 'Unit A')
      unit_b = create(:unit, community: community, name: 'Unit B')
      cook = create(:resident, community: community, unit: unit_a, multiplier: 1)
      eater = create(:resident, community: community, unit: unit_a, multiplier: 1)
      # unit_b resident does not participate in any meals
      create(:resident, community: community, unit: unit_b, multiplier: 1)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      reconciliation = settle!

      result = reconciliation.unit_balances

      expect(result.keys.map(&:last)).to include('Unit B')
      expect(result[[unit_b.id, 'Unit B']]).to eq(BigDecimal('0'))
      expect(result.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'lists units in name order, whatever order they were created in' do
      unit_b = create(:unit, community: community, name: 'Unit B')
      unit_a = create(:unit, community: community, name: 'Unit A')
      cook = create(:resident, community: community, unit: unit_b, multiplier: 1)
      eater = create(:resident, community: community, unit: unit_a, multiplier: 1)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      reconciliation = settle!

      expect(reconciliation.unit_balances.keys).to eq([[unit_a.id, 'Unit A'], [unit_b.id, 'Unit B']])
    end

    it 'returns all community units with zero balances for empty reconciliation' do
      # Built without validation for the same reason as the empty-period spec
      # above: an empty reconciliation can no longer be created, but the code
      # must still handle a row that has no meals.
      create(:unit, community: community, name: 'Unit A')
      create(:unit, community: community, name: 'Unit B')

      reconciliation = build(:reconciliation, community: community, end_date: latest)
      reconciliation.mark_settling!
      reconciliation.save!(validate: false)

      result = reconciliation.unit_balances

      expect(result.size).to eq(2)
      expect(result.values).to all(eq(BigDecimal('0')))
    end
  end

  # ADR 0011 rule 7. Elm's Dana is charged $15, and her line says she
  # did not live here when the units were saved.
  describe 'the people who had moved out' do
    let(:elm) { create(:unit, community: community, name: 'Elm') }
    let(:cook) { create(:resident, community: community, unit: elm) }
    let(:dana) { create(:resident, community: community, unit: elm) }
    let(:eli) { create(:resident, community: community, unit: create(:unit, community: community, name: 'Oak')) }
    let!(:reconciliation) do
      meal = create(:meal, community: community, date: latest)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      [dana, eli].each { |person| create(:meal_resident, meal: meal, resident: person, community: community) }
      dana.update!(active: false)
      settle!(cutoff: latest)
    end

    def by_name(balances)
      balances.transform_keys(&:last)
    end

    it 'are on a line of their own when the units were saved on the day of the settlement' do
      expect(reconciliation.records_who_moved_out?).to be(true)
      expect(by_name(reconciliation.unit_balances)).to eq('Elm' => BigDecimal('30'), 'Oak' => BigDecimal('-15'))
      expect(reconciliation.moved_out_balance).to eq(BigDecimal('-15'))
    end

    # The units were filled in later, so the line's lived_here is about
    # that later day, not the settlement's.
    it 'count in their unit, with no line of their own, when the units were saved later' do
      reconciliation.update_columns(units_recorded_on: reconciliation.date + 1)

      expect(reconciliation.units_recorded_later?).to be(true)
      expect(reconciliation.records_who_moved_out?).to be(false)
      expect(by_name(reconciliation.unit_balances)).to eq('Elm' => BigDecimal('15'), 'Oak' => BigDecimal('-15'))
      expect(reconciliation.moved_out_balance).to eq(BigDecimal('0')).and be_a(BigDecimal)
    end
  end

  describe '#destroy' do
    it 'is blocked — reconciliations are immutable settlement events' do
      settleable_meal
      reconciliation = settle!

      expect { reconciliation.destroy }.not_to change(described_class, :count)
      expect(reconciliation.errors[:base])
        .to include('Reconciliations are settlement events and cannot be destroyed.')
    end

    it 'preserves reconciliation_balances when destroy is attempted' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      reconciliation = settle!
      expect(reconciliation.reconciliation_balances.count).to eq(2)

      reconciliation.destroy
      expect(reconciliation.reconciliation_balances.reload.count).to eq(2)
    end
  end

  describe '#update' do
    it 'is blocked — settled reconciliations are immutable' do
      settleable_meal(date: Date.new(2025, 3, 1))
      reconciliation = settle!(cutoff: Date.new(2025, 3, 31))

      expect(reconciliation.update(end_date: Date.new(2025, 4, 30))).to be(false)
      expect(reconciliation.errors[:base])
        .to include('Reconciliations are settlement events and cannot be modified. ' \
                    'Corrections settle as new entries in the next reconciliation.')
      expect(reconciliation.reload.end_date).to eq(Date.new(2025, 3, 31))
    end

    it 'blocks update! with an exception and persists nothing' do
      settleable_meal(date: Date.new(2025, 3, 1))
      reconciliation = settle!(cutoff: Date.new(2025, 3, 31))

      expect { reconciliation.update!(date: Date.new(2025, 4, 1)) }
        .to raise_error(ActiveRecord::RecordNotSaved)
      expect(reconciliation.reload.date).to eq(Time.zone.today)
    end

    it 'does not record an update audit for the blocked write' do
      settleable_meal(date: Date.new(2025, 3, 1))
      reconciliation = settle!(cutoff: Date.new(2025, 3, 31))

      expect { reconciliation.update(end_date: Date.new(2025, 4, 30)) }
        .not_to change(reconciliation.audits, :count)
    end
  end

  describe 'auditing' do
    it 'records an audit on create' do
      settleable_meal(date: Date.new(2025, 3, 1))
      reconciliation = settle!(cutoff: Date.new(2025, 3, 31))

      audit = reconciliation.audits.last
      expect(audit.action).to eq('create')
      expect(audit.audited_changes).to have_key('end_date')
    end
  end
end
