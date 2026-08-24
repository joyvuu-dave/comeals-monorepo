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
    create(:meal_resident, meal: meal, resident: eater, community: community, multiplier: eater.multiplier)
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

      expect { settle!(community) }.to raise_error(ActiveRecord::StatementInvalid)

      ledger_tables_are_empty
    end

    it 'writes nothing, charge lines included, when the database refuses the balances' do
      cook = resident
      meal = meal_on(Date.yesterday)
      bill(meal, cook, 50)
      attend(meal, resident)
      refuse_inserts_into('reconciliation_balances')

      expect { settle!(community) }.to raise_error(ActiveRecord::StatementInvalid)

      ledger_tables_are_empty
    end
  end

  describe 'what gets claimed' do
    it 'claims exactly the meals that qualify, and no others, in one sweep' do
      cook = resident
      settled_before = meal_on(Date.yesterday - 10)
      bill(settled_before, cook, 10)
      earlier = settle!(community, cutoff: Date.yesterday - 5)
      expect(earlier.meals).to contain_exactly(settled_before)

      cutoff = Date.yesterday - 1
      eligible = meal_on(cutoff)
      bill(eligible, cook, 20)
      late_entry = meal_on(Date.yesterday - 8) # before the earlier cutoff, entered late
      bill(late_entry, cook, 15)
      past_cutoff = meal_on(Date.yesterday)
      bill(past_cutoff, cook, 40)
      today = meal_on(Time.zone.today)
      bill(today, cook, 30)
      no_bill = meal_on(Date.yesterday - 2)
      attend(no_bill, resident)

      reconciliation = settle!(community, cutoff: cutoff)

      expect(reconciliation.meals).to contain_exactly(eligible, late_entry)
      expect(Meal.where(id: [past_cutoff, today, no_bill]).pluck(:reconciliation_id)).to all(be_nil)
      expect(settled_before.reload.reconciliation_id).to eq(earlier.id)
    end

    it 'leaves a meal dated after the cutoff for the next settlement' do
      cook = resident
      inside = meal_on(Date.yesterday - 3)
      bill(inside, cook, 20)
      past_cutoff = meal_on(Date.yesterday - 1)
      bill(past_cutoff, cook, 20)

      reconciliation = settle!(community, cutoff: Date.yesterday - 2)

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

      reconciliation = settle!(community)

      stored = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
      expect(predicted.resident_balances.reject { |_, amount| amount.zero? }).to eq(stored)
    end

    it 'refuses a cutoff a settlement would refuse' do
      community
      expect { Settlement.preview(cutoff: Time.zone.today) }.to raise_error(Settlement::InvalidCutoff)
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

      settle!(community)
    end

    it 'writes charge lines that sum to zero for every meal' do
      reconciliation = settle_three_mixed_meals

      per_meal = MealCharge.for_reconciliation(reconciliation).group(:meal_id).sum(:amount)
      expect(per_meal.keys).to match_array(reconciliation.meals.pluck(:id))
      per_meal.each_value { |sum| expect(sum.abs).to be <= Reconciliation::ZERO_SUM_EPSILON }
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
      count_queries { settle!(community) }
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
