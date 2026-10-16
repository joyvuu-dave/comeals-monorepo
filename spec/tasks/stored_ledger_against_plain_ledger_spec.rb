# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require Rails.root.join('spec/support/oracle/plain_ledger')

# The end-to-end half of the oracle comparison. The in-memory half
# (spec/services/meal_ledger_against_plain_ledger_spec.rb) hands MealLedger
# and the plain ledger the same meals and compares the arithmetic. This half
# writes random ledgers to the database, runs the real rake task and a real
# settlement, and compares what the tables hold: resident_balances after
# billing:recalculate, then reconciliation_balances and meal_charges after
# the settlement, then resident_balances again, when every settled meal must
# have left the running balance.
#
# The oracle is told which meals count: every meal this example created.
# That is on purpose. Asking a scope would check the scope against itself.
#
# Written on 2026-09-09 to replace the end-to-end checks that ran against
# Resident#calc_balance, an older oracle written next to the code.
RSpec.describe 'the stored ledger against the plain ledger', type: :task do
  before(:all) do
    RakeTasks.ensure_loaded
  end

  after do
    Rake::Task['billing:recalculate'].reenable
  end

  def recalculate!
    Rake::Task['billing:recalculate'].reenable
    Rake::Task['billing:recalculate'].invoke
  end

  # Writes the random ledger for a seed to the database. RandomLedger keys
  # residents 1..30; here each key becomes a real row. Attendance copies the
  # resident's multiplier on create, so the residents get random ones and
  # the oracle reads whatever the rows say.
  def persist(seed, cents_max:)
    community = create(:community)
    unit = create(:unit, community: community)
    rng = Random.new(seed)
    residents = RandomLedger::RESIDENTS.index_with do |key|
      create(:resident, community: community, unit: unit, name: "Resident #{key}",
                        multiplier: rng.rand(0..2))
    end
    meals = RandomLedger.meals(seed, cents_max: cents_max).map do |draft|
      meal = create(:meal, community: community, date: draft.date)
      meal.update!(cap: draft.cap)
      draft.bills.each { |bill| persist_bill(meal, residents.fetch(bill.resident_id), bill) }
      draft.meal_residents.each do |row|
        create(:meal_resident, meal: meal, resident: residents.fetch(row.resident_id), community: community)
      end
      draft.guests.each do |guest|
        create(:guest, meal: meal, resident: residents.fetch(guest.resident_id), multiplier: guest.multiplier)
      end
      cancel_if_drafted(meal, draft)
      meal
    end
    [residents.values.map(&:id), meals.map(&:id)]
  end

  # A dinner a cook spent money on cannot be cancelled in the database,
  # so only the cancelled drafts with no money on a cost are.
  def cancel_if_drafted(meal, draft)
    meal.cancel! if draft.cancelled_at && meal.bills.none? { |bill| !bill.no_cost && bill.amount.positive? }
  end

  # A no-cost bill with an amount is written the way the app wrote one
  # before April 2026 (no_cost_bill_with_an_amount says why).
  def persist_bill(meal, cook, bill)
    if bill.no_cost && bill.amount.positive?
      no_cost_bill_with_an_amount(meal: meal, resident: cook, amount: bill.amount)
    else
      create(:bill, meal: meal, resident: cook, community: meal.community, amount: bill.amount, no_cost: bill.no_cost)
    end
  end

  def expect_close(actual, expected, label)
    (actual.keys | expected.keys).each do |key|
      a = actual.fetch(key, BigDecimal('0'))
      e = expected.fetch(key, BigDecimal('0'))
      expect(a).to eq(e), "#{label} #{key.inspect}: stored #{a.to_s('F')}, oracle #{e.to_s('F')}"
    end
  end

  def expect_stored_ledger_to_match(seed, cents_max:)
    resident_ids, meal_ids = persist(seed, cents_max: cents_max)
    rows = Meal.where(id: meal_ids).preload(:bills, :meal_residents, :guests).to_a
    plain = rows.map { |meal| RandomLedger.plain(meal) }
    expected = PlainLedger.balances(plain, resident_ids)
    label = "seed #{seed}#{' small' if cents_max < 999_999}"
    # A seed whose ledger moves no money checks nothing: every balance is
    # zero on both sides, and when no meal has a bill the settlement is
    # refused with "No unreconciled meals" before anything is compared
    # (seed 28 is one). The seeds below are picked by hand, and the oracle
    # is not asked which meals settle (see the top of this file), so such
    # a seed fails here and says why, instead of passing with nothing
    # compared or stopping at the settlement's refusal.
    nonzero = expected.values.reject(&:zero?)
    expect(nonzero).not_to be_empty, "#{label} moves no money, so it checks nothing. Pick another seed."

    recalculate!
    expect_close(ResidentBalance.pluck(:resident_id, :amount).to_h, expected, "#{label}, running balance of")

    reconciliation = settle!
    settled = reconciliation.reconciliation_balances.pluck(:resident_id, :amount).to_h
    expect(settled).to eq(PlainLedger.round_to_cents(expected).reject { |_, amount| amount.zero? }),
                       "#{label}: settled balances disagree"

    charges = MealCharge.where(meal_id: meal_ids).group(:meal_id, :resident_id).sum(:amount)
    expect_close(charges, PlainLedger.net_by_meal(plain), "#{label}, stored charges for")

    recalculate!
    expect_close(ResidentBalance.pluck(:resident_id, :amount).to_h, {}, "#{label}, running balance after settling,")
  end

  (1..6).each do |seed|
    it "agrees on ledger #{seed}" do
      expect_stored_ledger_to_match(seed, cents_max: 999_999)
    end
  end

  (1..3).each do |seed|
    it "agrees on ledger #{seed} with small receipts" do
      expect_stored_ledger_to_match(seed, cents_max: 500)
    end
  end
end
