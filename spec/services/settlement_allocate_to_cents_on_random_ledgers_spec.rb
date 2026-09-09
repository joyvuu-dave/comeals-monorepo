# frozen_string_literal: true

require 'rails_helper'

# The money hunt's property spec (.claude/skills/bug-hunt/SKILL.md): 100
# random ledgers (spec/support/random_ledger.rb) through MealLedger and
# described_class.allocate_to_cents, in memory, no database. What must hold for every one of them:
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
  def residents = RandomLedger::RESIDENTS
  def cent = BigDecimal('0.01')

  seeds = ENV['MONEY_PROPERTY_SEED'] ? [Integer(ENV.fetch('MONEY_PROPERTY_SEED'))] : (1..100).to_a

  seeds.each do |seed|
    it "holds for ledger #{seed}" do
      ledger = MealLedger.new(RandomLedger.meals(seed))

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
