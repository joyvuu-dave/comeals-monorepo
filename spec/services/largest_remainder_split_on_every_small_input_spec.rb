# frozen_string_literal: true

require 'rails_helper'

# Every small input, not random ones (issue #269, step 1). The random
# specs try inputs a seed happens to pick. This one tries every list of
# weights up to a size, and for each list every total that can give a
# different answer, and checks the rule on each:
#
#   1. the shares add up to the total;
#   2. each share is its exact share (total * weight / sum of weights)
#      rounded down, or that plus one unit;
#   3. a share whose exact share is a whole number gets no extra unit
#      (this includes every share with weight zero);
#   4. the extra units go to the shares that dropped the most when
#      rounded down, and on a tie to the earlier position.
#
# Rule 2 is "less than one unit from the exact share", said exactly.
#
# The inputs, and why the totals are enough, are in
# spec/support/money_sweep.rb.
#
# The checks are written from the rule in the class comment, not from
# the code: they never sort, and never compute a share the way the
# class does.
#
# MONEY_SWEEP=full runs the full size (spec/support/money_sweep.rb).
RSpec.describe LargestRemainderSplit do
  describe 'on every small input' do
    # What the rule says about one split, as a list of what is wrong.
    def problems(total, weights, shares)
      return ["#{shares.size} shares for #{weights.size} weights"] unless shares.size == weights.size
      return ["the shares add up to #{shares.sum}"] unless shares.sum == total

      whole = weights.sum
      # Each exact share is total * weight / whole. Kept as a whole number
      # of units rounded down, and what that dropped, as a numerator over
      # `whole`, so nothing here divides with a remainder lost.
      extra = shares.zip(weights).map { |share, weight| share - (total * weight).div(whole) }
      dropped = weights.map { |weight| (total * weight) % whole }

      found = share_problems(extra, dropped)
      found.empty? ? order_problems(extra, dropped, whole) : found
    end

    # Rules 2 and 3, one share at a time.
    def share_problems(extra, dropped)
      extra.each_with_index.flat_map do |units, index|
        if units != 0 && units != 1
          ["share #{index} is #{units} units from its exact share rounded down"]
        elsif units == 1 && dropped[index].zero?
          ["share #{index} is whole but got an extra unit"]
        else
          []
        end
      end
    end

    # Rule 4: no share that got an extra unit comes after one that did not.
    def order_problems(extra, dropped, whole)
      got, missed = extra.each_index.partition { |index| extra[index] == 1 }
      got.product(missed).filter_map do |winner, loser|
        next if dropped[winner] > dropped[loser]
        next if dropped[winner] == dropped[loser] && winner < loser

        "share #{winner} got an extra unit before share #{loser}: dropped " \
          "#{dropped[winner]}/#{whole} against #{dropped[loser]}/#{whole}"
      end
    end

    def check(failures, total, weights)
      shares = described_class.call(total, weights)
      problems(total, weights, shares).each do |problem|
        failures.add("call(#{total}, #{weights}) = #{shares}: #{problem}")
      end
    end

    it 'follows the rule for every list of small weights and every total' do
      failures = MoneySweep::Failures.new
      splits = 0

      MoneySweep.each_split(MoneySweep.size) do |total, weights|
        check(failures, total, weights)
        splits += 1
      end

      expect(failures.count).to eq(0), failures.to_s
      expect(splits).to be > 7_000
    end

    it 'follows the rule for short lists of large and small weights' do
      failures = MoneySweep::Failures.new

      MoneySweep.each_large_split(MoneySweep.size) { |total, weights| check(failures, total, weights) }

      expect(failures.count).to eq(0), failures.to_s
    end

    it 'refuses every list of weights that are all zero' do
      MoneySweep.split_lengths(MoneySweep.size).each do |length|
        expect { described_class.call(5, Array.new(length, 0)) }
          .to raise_error(ArgumentError, 'cannot split when every weight is zero')
      end
    end
  end
end
