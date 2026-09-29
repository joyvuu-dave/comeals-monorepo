# frozen_string_literal: true

require 'rails_helper'

# The settlement contract, tested as a black box.
#
# These examples drive settlement only through settle! (spec/support/
# settle.rb) and read only stored rows and public readers. They stub no
# method and name no private method, so they must run unchanged before
# and after the pipeline moves out of Reconciliation's after_create
# callback. If a change to settlement makes one of these fail, the
# change is wrong; if a change needs one of these edited, the change is
# not the refactor it claims to be.
RSpec.describe 'Settlement contract' do # rubocop:disable RSpec/DescribeClass -- a contract on behavior, on purpose not tied to the class that happens to implement it today
  let(:community) { create(:community) }
  let(:unit) { create(:unit, community: community) }

  def resident(multiplier: 2)
    create(:resident, community: community, unit: unit, multiplier: multiplier)
  end

  def meal_on(date)
    create(:meal, community: community, date: date)
  end

  def bill(meal, cook, amount, no_cost: false)
    create(:bill, meal: meal, resident: cook, community: community,
                  amount: BigDecimal(amount.to_s), no_cost: no_cost)
  end

  def attend(meal, eater)
    create(:meal_resident, meal: meal, resident: eater, community: community)
  end

  # Refuse every insert into a table for the rest of the test transaction.
  # DDL is transactional in Postgres, so the fixture rollback removes it.
  # This is how a mid-settlement failure is caused without stubbing any
  # Ruby method: the database itself says no.
  def refuse_inserts_into(table)
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE #{table} ADD CONSTRAINT spec_refuse_all_inserts CHECK (false) NOT VALID"
    )
  end

  def ledger_tables_are_empty
    expect(Reconciliation.count).to eq(0)
    expect(MealCharge.count).to eq(0)
    expect(ReconciliationBalance.count).to eq(0)
    expect(Meal.where.not(reconciliation_id: nil)).not_to exist
  end

  describe 'atomicity' do
    it 'writes nothing when the database refuses the charge lines' do
      cook = resident
      meal = meal_on(Date.yesterday)
      bill(meal, cook, 50)
      attend(meal, resident)
      refuse_inserts_into('meal_charges')

      # The refusal is the charge lines', so the reconciliation row and the
      # meal claims were already written when it came.
      expect { settle! }.to raise_error(
        ActiveRecord::StatementInvalid, /relation "meal_charges" violates check constraint "spec_refuse_all_inserts"/
      )

      ledger_tables_are_empty
    end

    it 'writes nothing, charge lines included, when the database refuses the balances' do
      cook = resident
      meal = meal_on(Date.yesterday)
      bill(meal, cook, 50)
      attend(meal, resident)
      refuse_inserts_into('reconciliation_balances')

      # The refusal is the balances', so the charge lines were already
      # written when it came.
      expect { settle! }.to raise_error(
        ActiveRecord::StatementInvalid,
        /relation "reconciliation_balances" violates check constraint "spec_refuse_all_inserts"/
      )

      ledger_tables_are_empty
    end
  end

  describe 'what gets claimed' do
    it 'claims exactly the meals that qualify, and no others, in one sweep' do
      cook = resident
      settled_before = meal_on(Date.yesterday - 10)
      bill(settled_before, cook, 10)
      attend(settled_before, cook)
      earlier = settle!(cutoff: Date.yesterday - 5)
      expect(earlier.meals).to contain_exactly(settled_before)

      cutoff = Date.yesterday - 1
      eater = resident
      eligible = meal_on(cutoff)
      bill(eligible, cook, 20)
      attend(eligible, eater)
      late_entry = meal_on(Date.yesterday - 8) # before the earlier cutoff, entered late
      bill(late_entry, cook, 15)
      attend(late_entry, eater)
      empty_slots = meal_on(Date.yesterday - 3) # nobody came, no money: settles with no effect
      bill(empty_slots, cook, 0)
      past_cutoff = meal_on(Date.yesterday)
      bill(past_cutoff, cook, 40)
      attend(past_cutoff, eater)
      today = meal_on(Time.zone.today)
      bill(today, cook, 30)
      attend(today, eater)
      no_bill = meal_on(Date.yesterday - 2)
      attend(no_bill, eater)
      receipt_nobody_ate = meal_on(Date.yesterday - 4) # money at stake, nobody to charge: held back
      bill(receipt_nobody_ate, cook, 25)

      reconciliation = settle!(cutoff: cutoff)

      expect(reconciliation.meals).to contain_exactly(eligible, late_entry, empty_slots)
      expect(Meal.where(id: [past_cutoff, today, no_bill, receipt_nobody_ate]).pluck(:reconciliation_id)).to all(be_nil)
      expect(settled_before.reload.reconciliation_id).to eq(earlier.id)
    end

    it 'leaves a meal dated after the cutoff for the next settlement' do
      cook = resident
      inside = meal_on(Date.yesterday - 3)
      bill(inside, cook, 20)
      attend(inside, cook)
      past_cutoff = meal_on(Date.yesterday - 1)
      bill(past_cutoff, cook, 20)
      attend(past_cutoff, cook)

      reconciliation = settle!(cutoff: Date.yesterday - 2)

      expect(reconciliation.meals).to contain_exactly(inside)
      expect(past_cutoff.reload.reconciliation_id).to be_nil
    end
  end

  describe 'preview' do
    it 'writes nothing and predicts exactly the balances a settlement then stores' do
      cook = resident
      eaters = Array.new(3) { resident }
      meal = meal_on(Date.yesterday - 1)
      bill(meal, cook, 50)
      eaters.each { |eater| attend(meal, eater) }
      capped = meal_on(Date.yesterday - 2)
      capped.update!(cap: BigDecimal('4'))
      bill(capped, cook, 70)
      eaters.each { |eater| attend(capped, eater) }

      predicted = nil
      expect { predicted = Settlement.preview(cutoff: Date.yesterday) }
        .not_to(change { [Reconciliation.count, MealCharge.count, ReconciliationBalance.count, Meal.where.not(reconciliation_id: nil).count] }) # rubocop:disable Layout/LineLength
      expect(predicted.meals).to contain_exactly(meal, capped)

      reconciliation = settle!

      stored = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
      expect(predicted.resident_balances.reject { |_, amount| amount.zero? }).to eq(stored)
    end

    it 'lists the skipped meals: in the period, with attendance, no bill, oldest first' do
      eater = resident
      cutoff = Date.yesterday - 1

      # An earlier period, settled before the meals below exist, so every
      # one of them is still open when the preview runs. Settling after
      # them would claim `billed`, and then the reconciled filter, not the
      # missing bill, would keep it off the list.
      first_period = meal_on(cutoff - 6)
      bill(first_period, resident, 10)
      attend(first_period, eater)
      reconciliation = settle!(cutoff: cutoff - 6)

      later = meal_on(cutoff)
      attend(later, eater)
      earlier = meal_on(cutoff - 5)
      attend(earlier, eater)

      billed = meal_on(cutoff - 2)
      bill(billed, resident, 20)
      attend(billed, eater)
      nobody_came = meal_on(cutoff - 3)
      after_cutoff = meal_on(cutoff + 1)
      attend(after_cutoff, eater)
      # Settled meals always have a bill, so this state needs a bypass to
      # build; the filter still has to hold if a repair ever removes one.
      settled = meal_on(cutoff - 4)
      attend(settled, eater)
      settled.update_column(:reconciliation_id, reconciliation.id)

      preview = Settlement.preview(cutoff: cutoff)
      expect(preview.skipped_meals).to eq([earlier, later])
      # `billed` is open and in the period, so only its bill keeps it off.
      expect(preview.meals).to include(billed)
      expect([billed, nobody_came, after_cutoff, settled]).to all(be_persisted)
    end

    it 'refuses a cutoff a settlement would refuse' do
      community
      expect { Settlement.preview(cutoff: Time.zone.today) }.to raise_error(Settlement::InvalidCutoff)
    end

    it 'leaves out a meal after the cutoff, even one whose day is over' do
      cook = resident
      inside = meal_on(Date.yesterday - 3)
      bill(inside, cook, 20)
      attend(inside, cook)
      past_cutoff = meal_on(Date.yesterday - 1)
      bill(past_cutoff, cook, 20)
      attend(past_cutoff, cook)

      expect(Settlement.preview(cutoff: Date.yesterday - 2).meals).to eq([inside])
    end

    # The later meal is entered first, so its row comes first in the table.
    it 'lists the meals it would settle oldest first' do
      cook = resident
      later = meal_on(Date.yesterday - 1)
      bill(later, cook, 20)
      attend(later, cook)
      earlier = meal_on(Date.yesterday - 2)
      bill(earlier, cook, 20)
      attend(earlier, cook)

      expect(Settlement.preview(cutoff: Date.yesterday).meals).to eq([earlier, later])
    end

    it 'lists the held meals: in the period, open, money on a receipt and nobody who ate, oldest first' do
      cook = resident
      eater = resident
      cutoff = Date.yesterday - 1

      # An earlier period, settled before the meals below exist.
      first_period = meal_on(cutoff - 6)
      bill(first_period, cook, 10)
      attend(first_period, eater)
      reconciliation = settle!(cutoff: cutoff - 6)

      later = meal_on(cutoff)
      bill(later, cook, 25)
      earlier = meal_on(cutoff - 5)
      bill(earlier, cook, 30)

      eaten = meal_on(cutoff - 2)
      bill(eaten, cook, 20)
      attend(eaten, eater)
      no_money = meal_on(cutoff - 3)
      bill(no_money, cook, 0)
      after_cutoff = meal_on(cutoff + 1)
      bill(after_cutoff, cook, 40)
      # Settled before 2026-09-10, when a receipt nobody ate was still
      # swept (MealCostSummary's spec has the same shape). A settlement
      # holds it back now, so the row is set the way those old ones are.
      settled = meal_on(cutoff - 4)
      bill(settled, cook, 15)
      settled.update_column(:reconciliation_id, reconciliation.id)

      preview = Settlement.preview(cutoff: cutoff)
      expect(preview.held_meals).to eq([earlier, later])
      expect(preview.meals).to contain_exactly(eaten, no_money)
    end

    # The preview refuses a cutoff that is not in the past before it asks
    # for either list, so there the filter changes nothing. Asked directly,
    # each list still follows settleable_by's rule that a day that is not
    # over is never in a period.
    it 'never lists a meal of today as skipped, whatever the cutoff' do
      today = community.today
      yesterday = meal_on(today - 1)
      attend(yesterday, resident)
      tonight = meal_on(today)
      attend(tonight, resident)

      expect(Settlement.skipped_by(today, today: today)).to eq([yesterday])
    end

    it 'never lists a meal of today as held, whatever the cutoff' do
      cook = resident
      today = community.today
      yesterday = meal_on(today - 1)
      bill(yesterday, cook, 25)
      tonight = meal_on(today)
      bill(tonight, cook, 25)

      expect(Settlement.held_by(today, today: today)).to eq([yesterday])
    end
  end

  describe 'what gets written' do
    def settle_three_mixed_meals
      cook = resident
      cook2 = resident
      eaters = Array.new(3) { resident }
      child = resident(multiplier: 1)

      plain = meal_on(Date.yesterday - 1)
      bill(plain, cook, 50)
      eaters.each { |eater| attend(plain, eater) }

      capped = meal_on(Date.yesterday - 2)
      capped.update!(cap: BigDecimal('4'))
      bill(capped, cook, 70)
      bill(capped, cook2, 0, no_cost: true)
      eaters.each { |eater| attend(capped, eater) }
      attend(capped, child)

      with_guest = meal_on(Date.yesterday - 3)
      bill(with_guest, cook2, 33.33)
      attend(with_guest, eaters.first)
      create(:guest, meal: with_guest, resident: eaters.first, multiplier: 2)

      settle!
    end

    it 'writes charge lines that sum to zero for every meal' do
      reconciliation = settle_three_mixed_meals

      per_meal = MealCharge.for_reconciliation(reconciliation).group(:meal_id).sum(:amount)
      expect(per_meal.keys).to match_array(reconciliation.meals.pluck(:id))
      per_meal.each_value { |sum| expect(sum).to eq(0) }
    end

    it 'stores exactly the rounded balances it computes, with zero balances left out' do
      reconciliation = settle_three_mixed_meals

      stored = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
      computed = reconciliation.settlement_balances.reject { |_, amount| amount.zero? }
      expect(stored).to eq(computed)
      expect(stored.values.sum).to eq(0)
      stored.each_value { |amount| expect(amount).to eq(amount.round(2)) }
    end

    # Creates meal_count meals, each with one bill, five eaters and a guest,
    # dated so they do not collide with any earlier batch, then settles them
    # and returns the number of queries the settlement ran.
    def settle_a_batch_and_count_queries(meal_count, cook:, eaters:, days_back:)
      meal_count.times do |i|
        meal = meal_on(Date.yesterday - days_back - i)
        bill(meal, cook, 40 + i)
        eaters.each { |eater| attend(meal, eater) }
        create(:guest, meal: meal, resident: eaters.first, multiplier: 2)
      end
      count_queries { settle! }
    end

    it 'runs the same number of queries for 10 meals as for 30' do
      # Settlement preloads bills, attendance, and guests once, so the query
      # count depends on how many residents end up with a balance (six here,
      # both times), never on how many meals or attendance rows there are.
      # A count that grows with the meals means a preload was lost.
      cook = resident
      eaters = Array.new(5) { resident }

      with_ten = settle_a_batch_and_count_queries(10, cook: cook, eaters: eaters, days_back: 0)
      with_thirty = settle_a_batch_and_count_queries(30, cook: cook, eaters: eaters, days_back: 10)

      expect(with_thirty).to eq(with_ten)
      expect(with_ten).to be <= 40 # measured 32 on 2026-08-23
    end
  end
end
