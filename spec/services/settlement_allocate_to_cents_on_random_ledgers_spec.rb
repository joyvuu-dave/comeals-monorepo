# frozen_string_literal: true

require 'rails_helper'

# The money hunt's property spec (.claude/skills/bug-hunt/SKILL.md): 100
# random ledgers through MealLedger and described_class.allocate_to_cents, in
# memory, no database. What must hold for every one of them:
#
#   1. the lines of each meal sum to zero, within ZERO_SUM_EPSILON: what the
#      cooks are credited is what the eaters are charged;
#   2. the rounded balances sum to exactly zero, so no penny is dropped;
#   3. every rounded balance is whole cents and within one cent of the
#      exact amount;
#   4. the same ledger rounds the same way every time.
#
# Each ledger is built from a seed, printed on failure so the case can be
# rerun alone (MONEY_PROPERTY_SEED=n).
RSpec.describe Settlement, '.allocate_to_cents, on random ledgers' do
  def residents = (1..30).to_a
  def cent = BigDecimal('0.01')

  def random_meal(rng, index)
    meal = Meal.new(id: index, date: Date.new(2026, 4, 1) + index)
    meal.cap = rng.rand < 0.4 ? BigDecimal(format('%.2f', rng.rand(1.0..30.0))) : nil

    resident_multipliers = [0, 1, 2]
    guest_multipliers = [1, 2]
    eaters = residents.sample(rng.rand(0..12), random: rng)
    eaters.each do |id|
      meal.meal_residents.build(resident_id: id, multiplier: resident_multipliers.sample(random: rng))
    end
    rng.rand(0..4).times do
      meal.guests.build(resident_id: residents.sample(random: rng), multiplier: guest_multipliers.sample(random: rng))
    end

    # Cooks may also eat (cook ids drawn from everyone, eaters included).
    residents.sample(rng.rand(0..3), random: rng).each do |id|
      no_cost = rng.rand < 0.15
      amount = no_cost ? BigDecimal('0') : BigDecimal(rng.rand(0..999_999)) / 100
      meal.bills.build(resident_id: id, amount: amount, no_cost: no_cost)
    end
    meal
  end

  def random_ledger(seed)
    rng = Random.new(seed)
    meals = Array.new(rng.rand(1..40)) { |i| random_meal(rng, i + 1) }
    MealLedger.new(meals)
  end

  seeds = ENV['MONEY_PROPERTY_SEED'] ? [Integer(ENV.fetch('MONEY_PROPERTY_SEED'))] : (1..100).to_a

  seeds.each do |seed|
    it "holds for ledger #{seed}" do
      ledger = random_ledger(seed)

      # 1. every meal's lines cancel out
      ledger.lines.group_by(&:meal_id).each do |meal_id, lines|
        sum = lines.sum(BigDecimal('0'), &:amount)
        expect(sum.abs).to be <= Reconciliation::ZERO_SUM_EPSILON,
                           "seed #{seed}, meal #{meal_id}: lines sum to #{sum.to_s('F')}"
      end

      raw = ledger.balances(residents)
      rounded = described_class.allocate_to_cents(raw, reconciliation_id: "seed #{seed}")

      # 2. no penny dropped
      expect(rounded.values.sum(BigDecimal('0'))).to eq(0), "seed #{seed}: rounded balances do not sum to zero"

      # 3. whole cents, within a cent of the truth
      rounded.each do |id, amount|
        expect(amount).to eq(amount.round(2)), "seed #{seed}, resident #{id}: #{amount.to_s('F')} is not whole cents"
        expect((amount - raw[id]).abs).to be < cent,
                                          "seed #{seed}, resident #{id}: #{amount.to_s('F')} is more than a cent " \
                                          "from #{raw[id].to_s('F')}"
      end

      # 4. deterministic
      expect(described_class.allocate_to_cents(raw, reconciliation_id: "seed #{seed} again")).to eq(rounded)
    end
  end
end
