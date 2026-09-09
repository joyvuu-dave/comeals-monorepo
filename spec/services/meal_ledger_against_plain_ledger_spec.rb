# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/oracle/plain_ledger')

# The independent oracle. PlainLedger (spec/support/oracle/plain_ledger.rb)
# was written from CLAUDE.md and MODELS.md alone, by an agent that was told
# not to read the app, so it cannot share a misreading with MealLedger and
# Settlement. This spec feeds both the same ledgers and compares every
# number. A disagreement is one of three things: a bug here, a bug in the
# oracle, or a rule the documents state badly. Whichever it is, it is
# worth a look, which is the point.
#
# The end-to-end half, through the database, the rake task and a real
# settlement, is spec/tasks/stored_ledger_against_plain_ledger_spec.rb.
RSpec.describe MealLedger do
  describe 'against the plain ledger written from the rules' do
    # BigDecimal division carries about twenty digits, and the two sides
    # may divide in a different order, so the last digits can differ. A
    # real disagreement is many orders larger than this.
    def noise = Reconciliation::ZERO_SUM_EPSILON

    def expect_close(actual, expected, label)
      keys = actual.keys | expected.keys
      keys.each do |key|
        a = actual.fetch(key, BigDecimal('0'))
        e = expected.fetch(key, BigDecimal('0'))
        expect((a - e).abs).to be <= noise, "#{label} #{key.inspect}: app #{a.to_s('F')}, oracle #{e.to_s('F')}"
      end
    end

    def expect_agreement(meals, label)
      plain = meals.map { |meal| RandomLedger.plain(meal) }
      ledger = described_class.new(meals)

      by_meal = ledger.lines.group_by { |line| [line.meal_id, line.resident_id] }
                      .transform_values { |lines| lines.sum(BigDecimal('0'), &:amount) }
      expect_close(by_meal, PlainLedger.net_by_meal(plain), "#{label}, meal and resident")

      raw = ledger.balances(RandomLedger::RESIDENTS)
      expect_close(raw, PlainLedger.balances(plain, RandomLedger::RESIDENTS), "#{label}, balance of resident")

      rounded = Settlement.allocate_to_cents(raw, reconciliation_id: label)
      expect(rounded).to eq(PlainLedger.round_to_cents(raw)), "#{label}: rounding to cents disagrees"
    end

    seeds = ENV['MONEY_PROPERTY_SEED'] ? [Integer(ENV.fetch('MONEY_PROPERTY_SEED'))] : (1..200).to_a

    seeds.each do |seed|
      it "agrees on ledger #{seed}" do
        expect_agreement(RandomLedger.meals(seed), "seed #{seed}")
      end

      it "agrees on ledger #{seed} with small receipts" do
        expect_agreement(RandomLedger.meals(seed, cents_max: 500), "seed #{seed} small")
      end
    end

    # The edges CLAUDE.md names, one ledger each, so a disagreement says
    # which rule it is about.
    def meal(index, cap: nil, bills: [], eaters: [], guests: [])
      meal = Meal.new(id: index, date: Date.new(2026, 4, 1) + index, cap: cap)
      bills.each do |id, amount, no_cost|
        meal.bills.build(resident_id: id, amount: BigDecimal(amount), no_cost: no_cost || false)
      end
      eaters.each { |id, multiplier| meal.meal_residents.build(resident_id: id, multiplier: multiplier) }
      guests.each { |host, multiplier| meal.guests.build(resident_id: host, multiplier: multiplier) }
      meal
    end

    {
      'a bill and no attendees' => [{ bills: [[1, '50']] }],
      'a bill and only free children' => [{ bills: [[1, '50']], eaters: [[2, 0], [3, 0]] }],
      'a no-cost bill and eaters' => [{ bills: [[1, '0', true]], eaters: [[2, 2], [3, 1]] }],
      'a zero bill not flagged no-cost' => [{ bills: [[1, '0']], eaters: [[2, 2]] }],
      'the cook eats' => [{ bills: [[1, '30']], eaters: [[1, 2], [2, 2]] }],
      'a guest whose host did not eat' => [{ bills: [[1, '30']], eaters: [[2, 2]], guests: [[3, 2]] }],
      'two cooks under a cap' => [{ cap: '4', bills: [[1, '70'], [2, '30']], eaters: [[3, 2], [4, 2], [5, 1]] }],
      'a cap that does not bind' => [{ cap: '100', bills: [[1, '30']], eaters: [[2, 2], [3, 2]] }],
      'a cap that binds exactly' => [{ cap: '5', bills: [[1, '20']], eaters: [[2, 2], [3, 2]] }],
      'a cook with a no-cost bill next to a paid one' =>
        [{ bills: [[1, '40'], [2, '0', true]], eaters: [[3, 2], [4, 2]] }],
      'a sub-dollar three-way split' => [{ bills: [[1, '1']], eaters: [[2, 2], [3, 2], [4, 2]] }]
    }.each do |name, meals|
      it "agrees on #{name}" do
        expect_agreement(meals.each_with_index.map { |attrs, i| meal(i + 1, **attrs) }, name)
      end
    end
  end
end
