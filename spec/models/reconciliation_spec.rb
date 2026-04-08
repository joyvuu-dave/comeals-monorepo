# frozen_string_literal: true

# == Schema Information
#
# Table name: reconciliations
#
#  id           :bigint           not null, primary key
#  date         :date             not null
#  end_date     :date             not null
#  start_date   :date             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  community_id :bigint           not null
#
# Indexes
#
#  index_reconciliations_on_community_id  (community_id)
#
# Foreign Keys
#
#  fk_rails_...  (community_id => communities.id)
#
require 'rails_helper'

RSpec.describe Reconciliation do
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  describe '#assign_meals' do
    it 'assigns unreconciled meals with bills to the new reconciliation' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal_with_bill = create(:meal, community: community)
      create(:bill, meal: meal_with_bill, resident: cook, community: community, amount: BigDecimal('50'))

      meal_without_bill = create(:meal, community: community)

      reconciliation = described_class.create!(community: community, date: Time.zone.today,
                                               start_date: 2.years.ago.to_date,
                                               end_date: Time.zone.today)

      meal_with_bill.reload
      meal_without_bill.reload

      expect(meal_with_bill.reconciliation_id).to eq(reconciliation.id)
      expect(meal_without_bill.reconciliation_id).to be_nil
    end

    it 'does not reassign already-reconciled meals' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      old_reconciliation = described_class.create!(community: community, date: Time.zone.today - 30,
                                                   start_date: 3.years.ago.to_date, end_date: 2.years.ago.to_date)

      old_meal = create(:meal, community: community, reconciliation: old_reconciliation)
      create(:bill, meal: old_meal, resident: cook, community: community, amount: BigDecimal('40'))

      new_meal = create(:meal, community: community)
      create(:bill, meal: new_meal, resident: cook, community: community, amount: BigDecimal('60'))

      new_reconciliation = described_class.create!(community: community, date: Time.zone.today,
                                                   start_date: 2.years.ago.to_date, end_date: Time.zone.today)

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

      reconciliation = described_class.create!(community: community, date: Time.zone.today,
                                               start_date: 2.years.ago.to_date,
                                               end_date: Time.zone.today)

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

      reconciliation = described_class.create!(community: community, date: Time.zone.today,
                                               start_date: 2.years.ago.to_date,
                                               end_date: Time.zone.today)
      balances = reconciliation.settlement_balances

      expect(balances[eater_1.id]).to eq(BigDecimal('-6.67'))
      expect(balances[eater_2.id]).to eq(BigDecimal('-3.33'))
      expect(balances[cook.id]).to eq(BigDecimal('10'))
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'produces exact zero sum even when all shares have the same fractional part' do
      # Worst case for allocation: all participants have identical remainders,
      # forcing the algorithm to tie-break. This also confirms the zero-sum
      # guarantee holds when every entry needs rounding.
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eaters = Array.new(3) { create(:resident, community: community, unit: unit, multiplier: 2) }

      meal = create(:meal, community: community)
      eaters.each { |e| create(:meal_resident, meal: meal, resident: e, community: community) }
      # $1 / 6 total multiplier = 0.16666... per unit × 2 = 0.33333... per eater
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('1'))
      meal.reload

      reconciliation = described_class.create!(community: community, date: Time.zone.today,
                                               start_date: 2.years.ago.to_date,
                                               end_date: Time.zone.today)
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('1'))
      eater_amounts = eaters.map { |e| balances[e.id] }
      # Two eaters get -0.34, one gets -0.33, totaling -1.00
      expect(eater_amounts.count(BigDecimal('-0.34'))).to eq(1)
      expect(eater_amounts.count(BigDecimal('-0.33'))).to eq(2)
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
      reconciliation = described_class.create!(
        community: capped_community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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
      reconciliation = described_class.create!(
        community: capped_community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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
      reconciliation = described_class.create!(
        community: capped_community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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
      reconciliation = described_class.create!(
        community: capped_community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('100'))
      expect(balances[eater.id]).to eq(BigDecimal('-100'))
    end
  end

  describe '#assign_meals with date boundaries' do
    it 'only assigns meals within the date range' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      in_range = create(:meal, community: community, date: Date.new(2025, 3, 1))
      create(:bill, meal: in_range, resident: cook, community: community, amount: BigDecimal('50'))

      out_of_range = create(:meal, community: community, date: Date.new(2025, 7, 1))
      create(:bill, meal: out_of_range, resident: cook, community: community, amount: BigDecimal('30'))

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: Date.new(2025, 1, 1), end_date: Date.new(2025, 6, 30)
      )

      in_range.reload
      out_of_range.reload

      expect(in_range.reconciliation_id).to eq(reconciliation.id)
      expect(out_of_range.reconciliation_id).to be_nil
    end

    it 'includes all meals within the date range regardless of past or future' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      past_meal = create(:meal, community: community, date: Date.yesterday)
      create(:bill, meal: past_meal, resident: cook, community: community, amount: BigDecimal('40'))

      future_meal = create(:meal, community: community, date: Time.zone.today + 30)
      create(:bill, meal: future_meal, resident: cook, community: community, amount: BigDecimal('20'))

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: Date.yesterday, end_date: Time.zone.today + 30
      )

      past_meal.reload
      future_meal.reload

      expect(past_meal.reconciliation_id).to eq(reconciliation.id)
      expect(future_meal.reconciliation_id).to eq(reconciliation.id)
    end
  end

  describe '#persist_balances!' do
    it 'persists settlement balances to reconciliation_balances table' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('80'))
      meal.reload

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )

      # finalize callback runs assign_meals + persist_balances!
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

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )

      # Cook and eater have balances, bystander has zero and is skipped
      expect(reconciliation.reconciliation_balances.find_by(resident: bystander)).to be_nil
      expect(reconciliation.reconciliation_balances.find_by(resident: cook)).to be_present
      expect(reconciliation.reconciliation_balances.find_by(resident: eater)).to be_present
    end
  end

  describe 'zero-attendee meals' do
    it 'excludes meals with no attendees from settlement balances (cook absorbs cost)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))
      # No meal_residents or guests — nobody ate

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )

      # Cook is NOT reimbursed — zero-attendee meal has no financial impact
      expect(reconciliation.balance_for(cook)).to eq(BigDecimal('0'))
    end

    it 'still assigns zero-attendee meals to the reconciliation' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )

      # Meal is assigned so it doesn't pile up as unreconciled
      expect(meal.reload.reconciliation).to eq(reconciliation)
    end

    it 'excludes zero-attendee meals from live balance (calc_balance)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      expect(cook.calc_balance).to eq(BigDecimal('0'))
    end
  end

  describe '#balance_for' do
    it 'returns the persisted balance for a resident' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('60'))
      meal.reload

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )

      expect(reconciliation.balance_for(cook)).to eq(BigDecimal('60'))
      expect(reconciliation.balance_for(eater)).to eq(BigDecimal('-60'))
    end

    it 'returns 0 for residents not in the reconciliation' do
      uninvolved = create(:resident, community: community, unit: unit)

      reconciliation = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )

      expect(reconciliation.balance_for(uninvolved)).to eq(BigDecimal('0'))
    end
  end

  describe 'transaction safety' do
    it 'rolls back meal assignments if persist_balances! fails' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      meal = create(:meal, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'))

      allow_any_instance_of(described_class).to receive(:persist_balances!).and_raise(RuntimeError, 'simulated failure') # rubocop:disable RSpec/AnyInstance -- testing rollback behavior requires stubbing any instance

      expect do
        described_class.create!(
          community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
        )
      end.to raise_error(RuntimeError, 'simulated failure')

      meal.reload
      expect(meal.reconciliation_id).to be_nil
      expect(described_class.count).to eq(0)
    end
  end

  describe 'date default' do
    it 'defaults date to today when not provided' do
      recon = described_class.create!(
        community: community,
        start_date: Time.zone.today, end_date: Time.zone.today
      )
      expect(recon.date).to eq(Time.zone.today)
    end

    it 'preserves an explicitly set date' do
      explicit_date = Date.new(2025, 6, 15)
      recon = described_class.create!(
        community: community, date: explicit_date,
        start_date: Time.zone.today, end_date: Time.zone.today
      )
      expect(recon.date).to eq(explicit_date)
    end
  end

  describe 'validations' do
    it 'rejects start_date after end_date' do
      recon = described_class.new(
        community: community, date: Time.zone.today,
        start_date: Time.zone.today, end_date: Date.yesterday
      )
      expect(recon).not_to be_valid
      expect(recon.errors[:start_date]).to include('must be on or before end date')
    end

    it 'accepts start_date equal to end_date' do
      create(:resident, community: community, unit: unit, multiplier: 2)
      recon = described_class.create!(
        community: community, date: Time.zone.today,
        start_date: Time.zone.today, end_date: Time.zone.today
      )
      expect(recon).to be_persisted
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
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('50'), no_cost: true)
      meal.reload

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
      balances = reconciliation.settlement_balances

      # All bills are no_cost → total_cost = 0 → credits and debits both 0
      expect(balances[cook.id]).to eq(BigDecimal('0'))
      expect(balances[eater.id]).to eq(BigDecimal('0'))
    end

    it 'handles a guest-only meal (no meal_residents, only guests)' do
      host = create(:resident, community: community, unit: unit, multiplier: 2)
      cook = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:guest, meal: meal, resident: host, multiplier: 2, name: 'Guest')
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('30'))
      meal.reload

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
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

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
      balances = reconciliation.settlement_balances

      # total_cost = 60 (only paid_cook's bill counts)
      # unit_cost = 60 / 2 = 30, eater debit = 30 * 2 = 60
      # paid_cook credit = 60, free_cook credit = 0
      expect(balances[paid_cook.id]).to eq(BigDecimal('60'))
      expect(balances[free_cook.id]).to eq(BigDecimal('0'))
      expect(balances[eater.id]).to eq(BigDecimal('-60'))
    end

    it 'uses largest-remainder allocation so rounded balances sum to exactly zero' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater1 = create(:resident, community: community, unit: unit, multiplier: 2)
      eater2 = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater1, community: community)
      create(:meal_resident, meal: meal, resident: eater2, community: community)
      # $0.05 / 4 total multiplier = $0.0125 per unit × 2 multiplier = $0.025 per eater
      # Each eater's exact share is -$0.025 (half-cent boundary).
      # Largest-remainder allocates the extra penny to one eater, ensuring zero sum.
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0.05'))
      meal.reload

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('0.05'))
      # One eater absorbs the extra penny; the other does not.
      eater_balances = [balances[eater1.id], balances[eater2.id]].sort
      expect(eater_balances).to eq([BigDecimal('-0.03'), BigDecimal('-0.02')])
      # Books balance exactly — no residual.
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end

    it 'allocates residual pennies deterministically (lowest ID absorbs first)' do
      cook = create(:resident, community: community, unit: unit, multiplier: 2)
      eater1 = create(:resident, community: community, unit: unit, multiplier: 2)
      eater2 = create(:resident, community: community, unit: unit, multiplier: 2)

      meal = create(:meal, community: community)
      create(:meal_resident, meal: meal, resident: eater1, community: community)
      create(:meal_resident, meal: meal, resident: eater2, community: community)
      create(:bill, meal: meal, resident: cook, community: community, amount: BigDecimal('0.05'))
      meal.reload

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
      balances = reconciliation.settlement_balances

      # Both eaters have identical fractional remainders. Tie-break: lowest ID absorbs.
      lower_id_eater, higher_id_eater = [eater1, eater2].sort_by(&:id)
      expect(balances[lower_id_eater.id]).to eq(BigDecimal('-0.03'))
      expect(balances[higher_id_eater.id]).to eq(BigDecimal('-0.02'))
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

      reconciliation = described_class.create!(
        community: community, start_date: 2.years.ago.to_date, end_date: Time.zone.today
      )
      balances = reconciliation.settlement_balances

      expect(balances[cook.id]).to eq(BigDecimal('1'))
      eater_amounts = eaters.map { |e| balances[e.id] }
      # Exactly 2 eaters pay -0.15, the other 5 pay -0.14
      expect(eater_amounts.count(BigDecimal('-0.15'))).to eq(2)
      expect(eater_amounts.count(BigDecimal('-0.14'))).to eq(5)
      expect(balances.values.sum(BigDecimal('0'))).to eq(BigDecimal('0'))
    end
  end
end
