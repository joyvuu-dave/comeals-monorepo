# frozen_string_literal: true

require 'rails_helper'

# Every small input, not random ones (issue #269, step 1). This tries
# every list of balances up to a size, each balance taken from a set of
# amounts just above, at, and just below a whole cent, on both sides of
# zero. The last balance in each list is whatever makes the list sum to
# zero, since allocate_to_cents refuses any other input. On each list it
# checks the rule (AGENTS.md, Money Handling Standards, rule 5):
#
#   1. every rounded balance is whole cents;
#   2. the rounded balances sum to exactly zero;
#   3. each rounded balance is less than one cent from the exact one;
#   4. each balance is cut toward zero to the cent, and then either left
#      there or moved one cent back toward its exact amount;
#   5. the cents all move the same way, and go to the balances that lost
#      the most in the cut, and on a tie to the lowest resident id.
#
# Each list runs twice: once with the ids in rising order, and once with
# the hash built in the other order, so a tie goes to the lowest id and
# not to whichever came first in the hash.
#
# The checks are written from the rule, not from the code: they work in
# whole units of 10^-8 dollars, and never sort.
#
# MONEY_SWEEP=full runs the full size (spec/support/money_sweep.rb).
RSpec.describe Settlement do
  describe 'allocate_to_cents on every small input' do
    # One cent, in units of 10^-8 dollars.
    def cent = 1_000_000

    def near_a_cent = [0, 1, 500_000, 999_999, 1_000_001]

    # small: 820 lists of up to 4 balances.
    # full: about 810,000 lists of up to 6 balances, some of them large.
    def free_lengths(size) = { small: 0..3, full: 0..5 }.fetch(size)

    def amounts(size)
      positive = { small: near_a_cent, full: near_a_cent + [1_500_000, 2_999_999, 1_234_567_000_001] }.fetch(size)
      positive + positive.drop(1).map(&:-@)
    end

    def dollars(units) = MealLedger::UNIT * units

    # Cut toward zero to a whole cent, and what the cut lost.
    def cut(units) = units.negative? ? -(-units).div(cent) * cent : units.div(cent) * cent
    def lost(units) = units - cut(units)

    # What the rule says about one rounding, as a list of what is wrong.
    # exact and rounded are { id => units }.
    def problems(exact, rounded)
      return ["ids #{rounded.keys.sort} for ids #{exact.keys.sort}"] unless rounded.keys.sort == exact.keys.sort
      return ["the rounded balances sum to #{rounded.values.sum}"] unless rounded.values.sum.zero?

      found = exact.flat_map { |id, amount| balance_problems(id, amount, rounded.fetch(id)) }
      found.empty? ? order_problems(exact, rounded) : found
    end

    # Rules 1, 3 and 4, one balance at a time.
    def balance_problems(id, amount, result)
      move = result - cut(amount)
      found = []
      found << "id #{id}: #{result} is not whole cents" unless (result % cent).zero?
      found << "id #{id}: #{result} is a cent or more from #{amount}" unless (result - amount).abs < cent
      unless move.zero? || (!lost(amount).zero? && move == cent * (lost(amount) <=> 0))
        found << "id #{id}: moved #{move} units from #{cut(amount)}, but the cut lost #{lost(amount)}"
      end
      found
    end

    # Rule 5. By now every move is one cent back toward the exact amount.
    def order_problems(exact, rounded)
      moved = exact.keys.reject { |id| rounded.fetch(id) == cut(exact.fetch(id)) }
      directions = moved.map { |id| rounded.fetch(id) <=> cut(exact.fetch(id)) }.uniq
      return [] if directions.empty?
      return ["cents moved both ways: #{moved}"] unless directions.size == 1

      # The balances that could have taken a cent: those whose cut lost
      # something on the side the cents moved.
      candidates = exact.keys.select { |id| (lost(exact.fetch(id)) <=> 0) == directions.first }
      winners, losers = candidates.partition { |id| moved.include?(id) }
      tie_problems(exact, winners, losers)
    end

    # No balance that took a cent lost less in the cut than one that did
    # not, and on a tie the lower id took it.
    def tie_problems(exact, winners, losers)
      size = ->(id) { lost(exact.fetch(id)).abs }
      winners.product(losers).filter_map do |winner, loser|
        next if size.call(winner) > size.call(loser)
        next if size.call(winner) == size.call(loser) && winner < loser

        "id #{winner} got a cent before id #{loser}: lost #{size.call(winner)} against #{size.call(loser)}"
      end
    end

    def check(failures, exact)
      raw = exact.transform_values { |amount| dollars(amount) }
      rounded = described_class.allocate_to_cents(raw, reconciliation_id: 'sweep')
                               .transform_values { |amount| MealLedger.units(amount) }
      problems(exact, rounded).each do |problem|
        failures.add("#{exact} rounded to #{rounded}: #{problem}")
      end
    end

    it 'follows the rule for every list of balances near a whole cent' do
      failures = MoneySweep::Failures.new
      lists = 0
      size = MoneySweep.size

      MoneySweep.each_list(free_lengths(size), amounts(size)) do |free|
        amounts = free + [-free.sum]
        ids = Array.new(amounts.size) { |index| 10 * (index + 1) }
        check(failures, ids.zip(amounts).to_h)
        check(failures, ids.zip(amounts).reverse.to_h)
        lists += 1
      end

      expect(failures.count).to eq(0), failures.to_s
      expect(lists).to be >= 820
    end
  end
end
