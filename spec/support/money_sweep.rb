# frozen_string_literal: true

# The inputs the money sweep specs try, and how many. The sweep specs try
# every input up to a size, not random ones (issue #269, step 1):
#
#   spec/services/largest_remainder_split_on_every_small_input_spec.rb
#   spec/services/settlement_allocate_to_cents_on_every_small_input_spec.rb
#
# The specs that compare the Ruby with the proofs try the same inputs
# (spec/support/proven.rb).
#
# bin/check runs the small size, which takes well under a second. One
# setting changes it:
#
#   MONEY_SWEEP=full  runs the full size, which took 51 seconds on a laptop
#
# Any other value stops the run with an error. Running the small size
# instead would look like a full run that found nothing.
module MoneySweep
  NAME = 'MONEY_SWEEP'
  SIZES = %w[small full].freeze

  def self.size(env: ENV)
    value = env.fetch(NAME, 'small')
    return value.to_sym if SIZES.include?(value)

    raise ArgumentError, "#{NAME} must be one of #{SIZES.join(', ')}; got #{value.inspect}"
  end

  # Every list of `length` numbers, each taken from `values`, for every
  # length in `lengths`. Built one at a time, so the full size does not
  # hold millions of lists in memory.
  def self.each_list(lengths, values, &)
    return enum_for(:each_list, lengths, values) unless block_given?

    lengths.each do |length|
      values.to_a.repeated_permutation(length, &)
    end
  end

  # Units of 10^-8 dollars: more than 100,000 dollars.
  LARGE = 10**13

  # The split sweep. small: 340 lists of weights 0 to 3, about 7,500
  # splits. full: 19,530 lists of weights 0 to 4, about 900,000 splits.
  def self.split_lengths(size) = { small: 1..4, full: 1..6 }.fetch(size)
  def self.split_weights(size) = { small: 0..3, full: 0..4 }.fetch(size)

  # For one list of weights with sum W, the total t and the total t + W
  # drop the same fractions, so the same shares get the extra units. So
  # every total 0 to W - 1 covers every way the extra units can fall for
  # that list. The sweep runs 0 to 2W - 1, and the same totals again above
  # LARGE, so a mistake that shows only on large numbers is caught too.
  def self.split_totals(weights)
    small = (0...(2 * weights.sum)).to_a
    small + small.map { |total| LARGE + total }
  end

  # Every total and list of weights in the split sweep. Lists whose weights
  # are all zero are left out: the split refuses them.
  def self.each_split(size)
    return enum_for(:each_split, size) unless block_given?

    each_list(split_lengths(size), split_weights(size)) do |weights|
      next if weights.sum.zero?

      split_totals(weights).each { |total| yield total, weights }
    end
  end

  # Weights as large as what cooks spend, in units. The totals cannot
  # cover every remainder of weights this large, so this tries a fixed few.
  def self.each_large_split(size)
    return enum_for(:each_large_split, size) unless block_given?

    few = { small: [1, 7, 1000, 12_345_678_901], full: [1, 2, 3, 7, 1000, 99_999_999, 12_345_678_901] }.fetch(size)
    totals = (0..30).to_a + [999_999_999, LARGE, LARGE + 1]
    each_list(1..3, few) do |weights|
      totals.each { |total| yield total, weights }
    end
  end

  # One cent, in units.
  CENT = 1_000_000

  # The cent rounding sweep: every list of balances up to a size, each
  # balance taken from a set of amounts just above, at, and just below a
  # whole cent, on both sides of zero. The last balance in each list is
  # whatever makes the list sum to zero, since allocate_to_cents refuses
  # any other input. small: 820 lists of up to 4 balances. full: about
  # 810,000 lists of up to 6 balances, some of them large.
  #
  # Each list comes twice, as { id => units }: once with the ids in rising
  # order, and once with the hash built in the other order, so a tie goes
  # to the lowest id and not to whichever came first in the hash.
  def self.each_rounding(size)
    return enum_for(:each_rounding, size) unless block_given?

    near_a_cent = [0, 1, 500_000, 999_999, 1_000_001]
    positive = { small: near_a_cent, full: near_a_cent + [1_500_000, 2_999_999, 1_234_567_000_001] }.fetch(size)
    amounts = positive + positive.drop(1).map(&:-@)
    each_list({ small: 0..3, full: 0..5 }.fetch(size), amounts) do |free|
      balances = free + [-free.sum]
      ids = Array.new(balances.size) { |index| 10 * (index + 1) }
      yield ids.zip(balances).to_h
      yield ids.zip(balances).reverse.to_h
    end
  end

  # Checking millions of inputs with one `expect` each would be slow, and
  # one failure would be lost among the others. A sweep collects what it
  # finds here and the spec expects the list to be empty. It keeps the
  # first few failures, which is enough to see the pattern, and counts
  # the rest.
  class Failures
    KEEP = 20

    attr_reader :count

    def initialize
      @kept = []
      @count = 0
    end

    def add(message)
      @count += 1
      @kept << message if @kept.size < KEEP
    end

    def to_s
      return 'none' if @count.zero?

      more = @count > KEEP ? "\n... and #{@count - KEEP} more" : ''
      "#{@count} failures:\n#{@kept.join("\n")}#{more}"
    end
  end
end
